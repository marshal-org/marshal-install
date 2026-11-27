---
name: install-health-check
description: Fast, read-only health check of your Marshal install. Checks nodes, control-plane replicas, isolation of control-plane pods from spaces nodes, Pending pods and why, crash loops, PodDisruptionBudgets that would block a drain, the migration job, the ingress address, service endpoints, PVCs, spaces-node CPU, memory and disk requests, and TLS certificate expiry. Prints PASS, WARN or FAIL with the next step for each. Use right after an install or upgrade, after any node pool change, when you want to know whether the install is healthy, and as the first step of any investigation.
---

# Install health check

**Read-only.** It runs `kubectl get` and nothing else; the certificate check reads only the
public certificate of the ingress TLS secret. It needs `kubectl` access to your cluster, the
same access the install used.

Run it from your installer checkout (the tag you installed from):

```bash
python3 scripts/health-check.py
# options: --namespace marshal  --spaces-namespace marshal-spaces  --no-certs
```

From a machine with no cluster access, save the JSON somewhere that has it and point the
script at the folder:

```bash
mkdir health && cd health
kubectl get nodes -o json > nodes.json
kubectl get pods -A -o json > pods.json
kubectl get deployments -n marshal -o json > deployments.json
kubectl get pdb -n marshal -o json > pdbs.json
kubectl get jobs -n marshal -o json > jobs.json
kubectl get ingress -n marshal -o json > ingresses.json
kubectl get pvc -A -o json > pvcs.json
kubectl get endpoints -n marshal -o json > endpoints.json
cd .. && python3 scripts/health-check.py --from health
```

The exit code is 1 when anything FAILs. A WARN is something to look at, not necessarily
broken.

## Checks and what to do

| Check | FAIL / WARN means | Next |
|---|---|---|
| nodes | A node is NotReady or has Disk, Memory or PID pressure (FAIL); cordoned (WARN). | `kubectl describe node <name>`. A cordoned node during a node pool move is expected. |
| control-plane deployments | A Deployment has fewer ready replicas than desired. | `kubectl describe pod` on one of its pods; if Pending, see Pending below. |
| control-plane isolation | Control-plane pods run on nodes that are not `workload=control-plane`, or there is no such pool. | `taint_control_plane_pool` is off, or the pods predate the taint. See the `size-node-pools` skill, section 2. |
| pods Pending over 5 min | Shows the scheduler's reason. | `Insufficient cpu` or `ephemeral-storage`: the `size-node-pools` skill. Quota: `QUOTA_EXCEEDED` in the node pool's instance group errors (GKE) or the Auto Scaling activity (EKS). |
| no node autoscaler running | Pods are Pending on capacity and nothing will add nodes. | EKS: set `enable_cluster_autoscaler = true` in `terraform.tfvars` and apply, or raise the node group size. |
| crash loops / restarts | CrashLoopBackOff, ImagePullBackOff, or 3 or more restarts. | The `support-bundle` skill, then `<container>.previous.log` in the bundle. Image pull: the registry and pull token in your configuration. |
| PodDisruptionBudgets | 0 disruptions allowed, so a node change or drain will hang. Typical with one control-plane node. | Scale the control plane to 2 nodes before touching the pool, or plan a window. |
| migration job | The latest migrate job has not succeeded. | `kubectl logs job/<name> -n marshal`. Do not roll the api until it passes. |
| ingress address | The ingress has no address. On EKS a missing `kubernetes.io/role/internal-elb` subnet tag fails **silently**. | Check the subnet tags, then the load balancer controller logs. |
| service endpoints | A Service has no ready pod behind it. | Same as the deployment check. |
| PVCs Bound | A PVC a pod is waiting on is not Bound, or a PVC is Lost. A Pending PVC that no pod uses is normal (it binds when its space starts) and is reported as waiting for first use. | `kubectl describe pvc <name>`: the StorageClass, the zone, or the EBS CSI or PD driver. |
| node requests | A spaces node is above 85% requested on CPU, memory or disk. | The `size-node-pools` skill. Disk is the usual one. |
| TLS cert | Expires in under 21 days (WARN) or 7 (FAIL), or is unreadable. A certificate you installed by hand is **not** renewed automatically. | Renew it and replace the secret's contents. |

## Reporting

Show the output lines as printed, not a summary. Say what could not be checked (a `SKIP`
line, no cluster access, `--no-certs`). When everything passes, say what that proves and what
it does not: the install is scheduled, running and reachable, which is not the same as a real
agent run working. Launch a space and run something to prove that.

For anything that needs logs, use the `support-bundle` skill. When you contact Marshal
support, include this output.
