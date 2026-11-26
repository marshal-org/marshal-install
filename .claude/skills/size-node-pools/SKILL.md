---
name: size-node-pools
description: Size or re-size your Marshal install's node pools from evidence. Reads your cluster (read-only), shows per node what is requested by control-plane pods, spaces and system pods, finds the limiting resource (CPU, memory or disk), and recommends machine type, boot disk, min and max nodes and the cloud quotas to ask for, with the replace impact of each change. Use when you want to know how big the nodes should be, a node shows high CPU or disk requested with few sessions, spaces are Pending, you plan N concurrent sessions, or before changing node_instance_types, node_disk_size_gb or spaces_pools.
---

# Size the node pools

**Read-only.** This skill collects and recommends. It never runs `terraform apply`, resizes a
pool, or edits your `terraform.tfvars`. You make the change, after reading the plan, with the
`add-node-pool` skill.

Every number in the recommendation comes from your cluster or from the compute-class table
below. Anything that could not be read is said so, not estimated.

## 1. Collect

You need `kubectl` on the cluster, the same access the install used. Then, from your installer
checkout:

```bash
python3 scripts/node-capacity.py          # current kubectl context
# or from saved JSON, for a cluster you cannot reach from this machine:
#   kubectl get nodes -o json > nodes.json; kubectl get pods -A -o json > pods.json
#   python3 scripts/node-capacity.py nodes.json pods.json
```

It prints, per node: allocatable CPU, memory and ephemeral-storage, what is requested by
**control-plane** pods (namespace `marshal`), **spaces** (namespace `marshal-spaces`) and
**system** (everything else), the limiting resource, how many more Medium, Large and XLarge
spaces fit, and flags.

Also read, because the script cannot:

| What | Command |
|---|---|
| Pending pods and why | `kubectl get pods -A --field-selector status.phase=Pending`, then `kubectl describe pod <p>` (look for `Insufficient cpu`, `Insufficient ephemeral-storage`, `didn't match Pod's node affinity`, an untolerated taint) |
| Does anything scale the pool? | GKE: the pool's autoscaling in `gcloud container node-pools describe`. EKS: the installer adds the Cluster Autoscaler when `enable_cluster_autoscaler` is true (the default); check `kubectl get deploy -n kube-system cluster-autoscaler-aws-cluster-autoscaler` or `kubectl get deploy -A \| grep -iE 'autoscaler\|karpenter'`. Without one, `node_max_size` is only a ceiling and the group stays at its desired size. |
| Real peak | The **Servers** page in the console (it shows, for example, "Limited by cpu 70%, fits 2 more Medium") and the 7-day peak of concurrent spaces. With no history, use the number of concurrent sessions you plan for. |
| Real usage against requests | `kubectl top nodes`. Requests decide scheduling; usage decides whether the node is actually busy. A node at 70% requested and 5% used is a scheduling problem, not a capacity problem. |

## 2. Read the result

Work through these in order. Stop at the first that applies and fix it before sizing anything
else, because sizing around it buys the wrong machine.

1. **Control-plane pods on a spaces node** (a flag from the script). The cause is
   `taint_control_plane_pool = false`, or an install from before the taint became the
   default. The chart baseline is about 4.4 vCPU of requests (api 1, gateway 0.5, web 0.2,
   marketplace 0.5, two replicas each). Fix: set it `true` and let the next apply roll the
   pods. Pods already on a spaces node are not evicted by the taint, but the helm upgrade that
   adds the `nodeSelector` moves them. Run the script again afterwards.
2. **DaemonSets are not the problem.** node-tuner asks 20m, aws-node 25m, kube-proxy 100m, EBS
   CSI about 30m. If "system" requests are above about 0.5 vCPU on a node, list the pods and
   find the Deployments (coredns, the load balancer controller, metrics-server, a security
   agent). Do not guess.
3. **Disk is the limit.** The built-in classes request 20 GiB of disk per vCPU (below).
   Machines give 4 GiB of memory per vCPU and far less disk per vCPU than that, so disk fills
   first. Raise the boot disk before the machine size.
4. **CPU is the limit with healthy disk.** Raise the machine size (more vCPU per node) before
   the node count: system overhead is per node, so fewer, bigger nodes waste less.
5. **Memory is the limit.** Rare at 1:4. Check that sessions are not requesting far more
   memory than the classes say before changing the shape.

## 3. Size it

The compute classes every organization starts with:

| Class | vCPU | Memory | Disk |
|---|---|---|---|
| Medium (default) | 0.5 | 1 GiB | 10 GiB |
| Large | 1 | 2 GiB | 20 GiB |
| XLarge | 2 | 4 GiB | 40 GiB |

Check your organization's actual classes first (**Compute classes** in the console, or the
API), and the real per-space disk request on a running space.

**Allocatable is not the boot disk.** Measure it, do not assume it. Observed: GKE about 49% of
the boot disk (200 GB gave about 97 GiB, 300 GB gave about 146 GiB); EKS about 89% (100 GB gave
about 89 GB). Resize one node, read `status.allocatable.ephemeral-storage`, then scale the
number.

Steps:

1. Concurrent spaces **S** at peak, and the class mix. The per-space request (cpu, memory,
   disk) from the table or a running space.
2. Per node, the spaces that fit: `min(free_cpu / cpu, free_mem / mem, free_disk / disk)`,
   where `free_*` is allocatable minus the system requests the script shows.
3. Nodes at perfect packing: `S / spaces_per_node`. Real packing is worse: one install
   measured 18 nodes perfect, about 23 with live churn, about 26 at the peak. Multiply by
   **1.3** for steady state and **1.45** for the peak.
4. Pick the machine so the **limiting resource is not disk by more than about 2x**. If disk
   would need an unreasonable boot disk, use more nodes, not bigger ones.
5. Zones. GKE regional pools size per zone, so the totals are times the number of zones, and
   a zonal volume pins a space to a zone: size for the busiest zone, not the average.

**Keep the 1:4 vCPU:memory shape** (m5, e2-standard). The classes request 1:2, but agents
burst past requests. Do not move to compute-optimized machines to "fix" low memory use without
measuring bursts first.

## 4. Quotas, before anything changes

A quota that is too low does not fail cleanly. It leaves pods Pending, or a node replacement
stuck.

- **AWS**: on-demand standard vCPU, quota code `L-1216C47A`. Sum:
  `(spaces nodes max x vCPU) + (control-plane nodes max x vCPU) + bastion 2`, plus one
  replacement node while a node group updates. Defaults: 16 at create, 58 fully scaled, ask
  for 72.
- **GCP**: `CPUS_ALL_REGIONS` and the regional `CPUS`, **and** the regional `SSD_TOTAL_GB`,
  which counts `pd-balanced` too. Per-zone node counts times the number of zones times boot
  disk. Defaults at create: 48 vCPU and 1050 GB.
  `gcloud compute instance-groups managed list-errors <mig> --zone <z>` shows
  `QUOTA_EXCEEDED` when disk quota is the blocker.

## 5. Changing a pool: add a new one, never replace in place

A machine type or boot disk change **replaces the pool or node group**, and a replacement
kills every running space on it: the node is drained, the spaces on it stop, and anything not
persisted is lost. So for any change to `machine_type`, `instance_types`, `disk_size_gb` or
`node_disk_size_gb`:

> **Add the new pool next to the old one. Do not edit the old one.**

The [`add-node-pool`](../add-node-pool/SKILL.md) skill has the exact steps for both clouds:
quota for old plus new, the tfvars entry, cordoning the old nodes, the message to your team,
and removing the old pool once it is empty.

### The control-plane pool

The same applies, with one more trap. With a single control-plane node, a node change
deadlocks on the PodDisruptionBudgets (`minAvailable: 1`): the last replica of each component
cannot be evicted. Scale the control plane to 2 nodes first (needs quota), or plan a
maintenance window. Control-plane pods are stateless, so a short rolling restart is
acceptable; running spaces are not.

### Other changes

| Change | Effect on a running install |
|---|---|
| `taint_control_plane_pool` false to true | Adds the taint and the chart `nodeSelector` in one apply. Not a replacement. If the plan shows a pool being replaced, stop. |
| `*_max_*` counts, min counts | In place. |
| `node_sysctls`, image streaming | Replaces the pool's nodes (rolling). Use the add-a-pool route. |

Before any apply, read the plan and confirm what it destroys.

## 6. Report

A short report, in this order:

1. **Finding**: the limiting resource and the evidence (the script output lines, not a
   paraphrase).
2. **Recommendation**: machine type, boot disk, min and max nodes per pool, as the exact
   tfvars lines.
3. **Quota asks**: the numbers from section 4, with the arithmetic.
4. **Change plan**: the add-a-pool route for your cloud, with the old pool name, handed to the
   `add-node-pool` skill. Never edit a running pool in place.
5. **Not verified**: anything that could not be read (no kubectl access, no peak data, no
   autoscaler check).

Never paste your `terraform.tfvars` into a report or a ticket: it holds your licence token and
pull token.
