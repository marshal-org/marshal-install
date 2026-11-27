#!/usr/bin/env python3
"""Read-only health check for a Marshal install. PASS / WARN / FAIL per check.

  scripts/health-check.py [--namespace marshal] [--spaces-namespace marshal-spaces] [--no-certs]
  scripts/health-check.py --from DIR  # DIR holds nodes.json pods.json deployments.json
                              # pdbs.json jobs.json ingresses.json pvcs.json endpoints.json
Exit 1 if anything FAILs. Only `kubectl get` is run; nothing is changed.
"""
import argparse, base64, datetime as dt, json, os, re, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--namespace", default="marshal")
ap.add_argument("--spaces-namespace", default="marshal-spaces")
ap.add_argument("--no-certs", action="store_true")
ap.add_argument("--from", dest="src")
A = ap.parse_args()
NS, SNS = A.namespace, A.spaces_namespace
NOW = dt.datetime.now(dt.timezone.utc)
UNITS = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "k": 1e3, "M": 1e6, "G": 1e9, "m": 1e-3, "": 1}


def q(v):
    m = re.fullmatch(r"([0-9.]+)([A-Za-z]*)", str(v or "0"))
    return float(m.group(1)) * UNITS.get(m.group(2), 1) if m else 0.0


def get(kind, fname, *args):
    if A.src:
        p = os.path.join(A.src, fname)
        return json.load(open(p))["items"] if os.path.exists(p) else None
    try:
        out = subprocess.check_output(["kubectl", "get", kind, *args, "-o", "json"], stderr=subprocess.PIPE, timeout=60)
        return json.loads(out)["items"]
    except Exception as e:  # noqa
        print(f"SKIP  could not read {kind}: {str(getattr(e, 'stderr', e))[:120].strip()}")
        return None


def age_min(ts):
    return (NOW - dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))).total_seconds() / 60


res = {"PASS": 0, "WARN": 0, "FAIL": 0}


def out(level, name, detail=""):
    res[level] += 1
    print(f"{level:<5} {name}" + (f": {detail}" if detail else ""))


nodes = get("nodes", "nodes.json")
pods = get("pods", "pods.json", "-A")
deps = get("deployments", "deployments.json", "-n", NS)
pdbs = get("pdb", "pdbs.json", "-n", NS)
jobs = get("jobs", "jobs.json", "-n", NS)
ings = get("ingress", "ingresses.json", "-n", NS)
pvcs = get("pvc", "pvcs.json", "-A")
eps = get("endpoints", "endpoints.json", "-n", NS)

# 1. Nodes Ready, no pressure
if nodes is not None:
    bad = []
    for n in nodes:
        c = {x["type"]: x["status"] for x in n["status"].get("conditions", [])}
        if c.get("Ready") != "True":
            bad.append(f"{n['metadata']['name']} NotReady")
        for t in ("DiskPressure", "MemoryPressure", "PIDPressure"):
            if c.get(t) == "True":
                bad.append(f"{n['metadata']['name']} {t}")
        if n["spec"].get("unschedulable"):
            bad.append(f"{n['metadata']['name']} cordoned")
    out("FAIL" if any("NotReady" in b or "Pressure" in b for b in bad) else "WARN" if bad else "PASS",
        f"nodes ({len(nodes)})", "; ".join(bad))

# 2. Control-plane Deployments fully available
if deps is not None:
    bad = [f"{d['metadata']['name']} {d['status'].get('readyReplicas', 0)}/{d['spec'].get('replicas', 1)}"
           for d in deps if d["status"].get("readyReplicas", 0) < d["spec"].get("replicas", 1)]
    out("FAIL" if bad else "PASS", f"control-plane deployments ({len(deps)})", "not ready: " + ", ".join(bad) if bad else "")

# 3. Isolation: control-plane pods only on control-plane nodes (when such a pool exists)
if nodes is not None and pods is not None:
    pool = {n["metadata"]["name"]: n["metadata"].get("labels", {}).get("workload", "") for n in nodes}
    if len(nodes) == 1:
        # Single-node k3s: one node runs everything by design.
        out("PASS", "control-plane isolation", "single node: control plane and spaces share it by design")
    elif "control-plane" not in pool.values():
        out("WARN", "control-plane isolation", "no node labelled workload=control-plane: control-plane pods share nodes with spaces")
    else:
        spill = [p["metadata"]["name"] + "@" + p["spec"]["nodeName"] for p in pods
                 if p["metadata"]["namespace"] == NS and p["spec"].get("nodeName") and pool.get(p["spec"]["nodeName"]) != "control-plane"
                 and not any(o.get("kind") == "DaemonSet" or o.get("kind") == "Job" for o in p["metadata"].get("ownerReferences", []))]
        out("WARN" if spill else "PASS", "control-plane isolation", f"{len(spill)} pod(s) on non control-plane nodes: " + ", ".join(spill[:4]) if spill else "")

# 4. Pending pods (not just created)
if pods is not None:
    pend = []
    for p in pods:
        if p["status"].get("phase") == "Pending" and age_min(p["metadata"]["creationTimestamp"]) > 5:
            msg = next((c.get("message", "") for c in p["status"].get("conditions", []) if c.get("type") == "PodScheduled" and c.get("status") == "False"), "")
            pend.append(f"{p['metadata']['namespace']}/{p['metadata']['name']} ({msg[:90]})")
    out("FAIL" if pend else "PASS", "pods Pending over 5 min", "; ".join(pend[:5]) + (f" (+{len(pend) - 5} more)" if len(pend) > 5 else ""))
    # Capacity shortfall with nothing to add nodes: the usual cause on EKS installs
    # that predate the Cluster Autoscaler (enable_cluster_autoscaler).
    if any("Insufficient" in x for x in pend):
        has_scaler = any(re.search(r"autoscaler|karpenter", p["metadata"]["name"]) and p["status"].get("phase") == "Running" for p in pods)
        managed = any("cloud.google.com/gke-nodepool" in n["metadata"].get("labels", {}) for n in (nodes or []))  # GKE autoscales in the pool, no pod
        if not has_scaler and not managed:
            out("WARN", "no node autoscaler running", "pods are Pending on capacity and no cluster-autoscaler/karpenter pod is Running; nothing will add nodes. EKS: set enable_cluster_autoscaler = true (aws-eks) or raise the node group size by hand")

# 5. Crash loops, image pull failures, restarts in the control-plane namespace
if pods is not None:
    bad = []
    for p in pods:
        if p["metadata"]["namespace"] != NS:
            continue
        for cs in p["status"].get("containerStatuses", []):
            w = cs.get("state", {}).get("waiting", {}).get("reason", "")
            if w in ("CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError") or cs.get("restartCount", 0) >= 3:
                bad.append(f"{p['metadata']['name']}/{cs['name']} {w or 'restarts=' + str(cs['restartCount'])}")
    out("FAIL" if bad else "PASS", "control-plane crash loops / restarts", "; ".join(bad[:5]))

# 6. PDBs that would block a drain
if pdbs is not None:
    z = [p["metadata"]["name"] for p in pdbs if p["status"].get("disruptionsAllowed", 1) == 0]
    out("WARN" if z else "PASS", "PodDisruptionBudgets allow a drain", ("0 disruptions allowed: " + ", ".join(z) + ". A node change would hang on these.") if z else "")

# 7. Migration job
if jobs is not None:
    m = [j for j in jobs if "migrate" in j["metadata"]["name"]]
    if not m:
        out("PASS", "migration job", "none present (already cleaned up)")
    else:
        j = sorted(m, key=lambda x: x["metadata"]["creationTimestamp"])[-1]
        ok = j["status"].get("succeeded", 0) >= 1
        out("PASS" if ok else "FAIL", "latest migration job " + j["metadata"]["name"], "" if ok else f"succeeded=0 failed={j['status'].get('failed', 0)}")

# 8. Ingress has an address
if ings is not None:
    no = [i["metadata"]["name"] for i in ings if not i["status"].get("loadBalancer", {}).get("ingress")]
    out("FAIL" if (no or not ings) else "PASS", f"ingress address ({len(ings)})", ("no address: " + ", ".join(no)) if no else "no ingress found" if not ings else "")

# 9. Services have ready endpoints
if eps is not None:
    bad = [e["metadata"]["name"] for e in eps if re.search(r"(api|gateway|web|marketplace)$", e["metadata"]["name"])
           and not any(s.get("addresses") for s in e.get("subsets", []) or [])]
    out("FAIL" if bad else "PASS", "service endpoints (api/gateway/web/marketplace)", "no ready addresses: " + ", ".join(bad) if bad else "")

# 10. PVCs bound
# A PVC that is Pending with no pod using it is normal: the default storage
# classes on GKE, EKS and k3s bind on first use (WaitForFirstConsumer), and a
# stopped space keeps its home volume unbound until it starts again. Only a
# PVC a pod is waiting on, or a Lost one, is a failure.
if pvcs is not None:
    used = set()
    for p in pods or []:
        for v in p["spec"].get("volumes") or []:
            c = (v.get("persistentVolumeClaim") or {}).get("claimName")
            if c:
                used.add((p["metadata"]["namespace"], c))
    bad, idle = [], 0
    for p in pvcs:
        phase = p["status"].get("phase")
        key = (p["metadata"]["namespace"], p["metadata"]["name"])
        if phase == "Bound":
            continue
        # Only when the pod list was read: without it, no PVC can be shown unused.
        if phase == "Pending" and pods is not None and key not in used:
            idle += 1
            continue
        bad.append(f"{key[0]}/{key[1]} ({phase})")
    note = f"{idle} waiting for first use (stopped spaces)" if idle else ""
    if bad:
        out("FAIL", f"PVCs Bound ({len(pvcs)})", "not Bound: " + ", ".join(bad[:5]))
    else:
        out("PASS", f"PVCs Bound ({len(pvcs)})", note)

# 11. Spaces nodes: requested CPU / memory / disk
if nodes is not None and pods is not None:
    for n in nodes:
        if n["metadata"].get("labels", {}).get("workload") == "control-plane":
            continue
        a, nm = n["status"]["allocatable"], n["metadata"]["name"]
        used = [0.0, 0.0, 0.0]
        for p in pods:
            if p["spec"].get("nodeName") == nm and p["status"].get("phase") in ("Running", "Pending"):
                for c in p["spec"].get("containers", []):
                    r = c.get("resources", {}).get("requests", {})
                    for i, k in enumerate(("cpu", "memory", "ephemeral-storage")):
                        used[i] += q(r.get(k))
        pct = [used[i] / q(a.get(k)) if q(a.get(k)) else 0 for i, k in enumerate(("cpu", "memory", "ephemeral-storage"))]
        hot = [f"{lab} {v:.0%}" for lab, v in zip(("cpu", "mem", "disk"), pct) if v > 0.85]
        out("WARN" if hot else "PASS", f"node {nm} requests", ", ".join(hot) if hot else f"cpu {pct[0]:.0%} mem {pct[1]:.0%} disk {pct[2]:.0%}")

# 12. TLS certificate expiry (reads the public certificate of the ingress TLS secret only)
if ings and not A.no_certs and not A.src:
    for i in ings:
        for t in i["spec"].get("tls", []) or []:
            sec = t.get("secretName")
            if not sec:
                continue
            try:
                b64 = subprocess.check_output(["kubectl", "get", "secret", sec, "-n", NS, "-o", r"jsonpath={.data.tls\.crt}"], stderr=subprocess.PIPE, timeout=30).decode()
                end = subprocess.run(["openssl", "x509", "-noout", "-enddate"], input=base64.b64decode(b64), capture_output=True, timeout=10).stdout.decode().strip().split("=")[-1]
                days = (dt.datetime.strptime(end, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc) - NOW).days
                out("FAIL" if days < 7 else "WARN" if days < 21 else "PASS", f"TLS cert {sec}", f"expires in {days} days ({end})")
            except Exception as e:  # noqa
                out("WARN", f"TLS cert {sec}", f"could not read: {str(e)[:80]}")

print(f"\n{res['PASS']} pass, {res['WARN']} warn, {res['FAIL']} fail")
sys.exit(1 if res["FAIL"] else 0)
