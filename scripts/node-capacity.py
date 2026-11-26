#!/usr/bin/env python3
"""Per-node capacity report for a Marshal cluster. Read-only.

Usage:
  scripts/node-capacity.py                       # runs kubectl against the current context
  scripts/node-capacity.py nodes.json pods.json  # from saved `kubectl get ... -o json`

For every node: pool, type, allocatable CPU / memory / ephemeral-storage, what
is REQUESTED by control-plane pods, space pods and everything else (system),
the resource that limits the node, and how many more spaces of each built-in
class fit. Then flags the two common sizing mistakes: control-plane
pods on a spaces node, and a node limited by disk rather than CPU.
"""
import json, re, subprocess, sys

CP_NS, SPACE_NS = "marshal", "marshal-spaces"
# Built-in compute classes seeded in every organization: cpu, memory GiB, disk GiB.
CLASSES = {"Medium": (0.5, 1, 10), "Large": (1, 2, 20), "XLarge": (2, 4, 40)}
UNITS = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40,
         "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "m": 1e-3, "": 1}


def q(v):
    """Kubernetes quantity -> float (cores or bytes)."""
    if v is None:
        return 0.0
    m = re.fullmatch(r"([0-9.]+)([A-Za-z]*)", str(v))
    return float(m.group(1)) * UNITS[m.group(2)] if m else 0.0


def load(argv):
    if len(argv) == 3:
        return json.load(open(argv[1])), json.load(open(argv[2]))
    run = lambda *a: json.loads(subprocess.check_output(["kubectl", *a, "-o", "json"]))
    return run("get", "nodes"), run("get", "pods", "-A")


def pod_req(pod):
    c = pod["spec"].get("containers", [])
    r = lambda k: sum(q(x.get("resources", {}).get("requests", {}).get(k)) for x in c)
    return r("cpu"), r("memory"), r("ephemeral-storage")


def main():
    nodes, pods = load(sys.argv)
    by_node = {}
    for p in pods["items"]:
        n = p["spec"].get("nodeName")
        if n and p["status"].get("phase") in ("Running", "Pending"):
            by_node.setdefault(n, []).append(p)
    GiB, flags = 2**30, []
    for nd in nodes["items"]:
        name, lab = nd["metadata"]["name"], nd["metadata"].get("labels", {})
        a = nd["status"]["allocatable"]
        cap = [q(a["cpu"]), q(a["memory"]), q(a.get("ephemeral-storage"))]
        use = {"control-plane": [0, 0, 0], "spaces": [0, 0, 0], "system": [0, 0, 0]}
        cp_pods = []
        for p in by_node.get(name, []):
            ns = p["metadata"]["namespace"]
            g = "spaces" if ns == SPACE_NS else "control-plane" if ns == CP_NS else "system"
            if g == "control-plane":
                cp_pods.append(p["metadata"]["name"])
            for i, v in enumerate(pod_req(p)):
                use[g][i] += v
        free = [cap[i] - sum(use[g][i] for g in use) for i in range(3)]
        used = [sum(use[g][i] for g in use) / cap[i] if cap[i] else 0 for i in range(3)]
        limit = ("cpu", "memory", "disk")[max(range(3), key=lambda i: used[i])]
        typ = lab.get("node.kubernetes.io/instance-type", "?")
        pool = lab.get("workload", lab.get("cloud.google.com/gke-nodepool", "?"))
        print(f"\n{name}  pool={pool}  type={typ}  zone={lab.get('topology.kubernetes.io/zone', '?')}")
        print(f"  allocatable  cpu {cap[0]:.2f}  mem {cap[1]/GiB:.1f}Gi  disk {cap[2]/GiB:.0f}Gi")
        for g in use:
            u = use[g]
            print(f"  {g:<13} cpu {u[0]:.2f}  mem {u[1]/GiB:.1f}Gi  disk {u[2]/GiB:.0f}Gi")
        print(f"  requested    cpu {used[0]:.0%}  mem {used[1]:.0%}  disk {used[2]:.0%}   limited by: {limit}")
        fits = []
        for cn, (c, m, d) in CLASSES.items():
            fits.append(f"{cn} {max(0, int(min(free[0] / c, free[1] / (m * GiB), free[2] / (d * GiB))))}")
        print("  fits more    " + ", ".join(fits))
        if cp_pods and pool != "control-plane":
            flags.append(f"{name}: {len(cp_pods)} control-plane pod(s) on a non-control-plane node "
                         f"({use['control-plane'][0]:.2f} vCPU requested). taint_control_plane_pool is off, or the "
                         "pods predate the taint.")
        if limit == "disk" and pool != "control-plane":
            flags.append(f"{name}: disk is the limiting resource. Raise the boot disk before the machine size.")
    print("\nFLAGS" if flags else "\nno flags")
    for f in flags:
        print("  - " + f)


if __name__ == "__main__":
    main()
