---
name: add-node-pool
description: "Move your Marshal install's spaces to a different node size or disk without stopping them, by adding a NEW node pool (GKE) or node group (EKS) beside the old one, cordoning the old one, and removing it once empty. Prepares the terraform.tfvars change, the commands and the message to your team; you run terraform apply yourself. Use whenever you want to change machine type, instance type or boot disk, or say \"resize the nodes\". Never edit the existing pool in place: that replaces it and stops every space on it."
---

# Add a node pool (never replace one)

This skill prepares each change and tells you what to check; **you** edit
`terraform.tfvars` and run `terraform plan` and `terraform apply` yourself. It never applies
anything. The size and quota numbers come from the
[`size-node-pools`](../size-node-pools/SKILL.md) skill.

**Rule:** changing `machine_type`, `instance_types` or the boot disk on an existing pool
replaces it and kills every space on it. So you add a second pool, move the spaces over, then
remove the first.

## 1. Settle three things

- **The old pool's name.** Read it from your `terraform.tfvars` and the cluster
  (`kubectl get nodes -L workload,cloud.google.com/gke-nodepool,eks.amazonaws.com/nodegroup`).
  GKE: the `spaces_pools` key (default `spaces`). EKS: `<cluster_name>-spaces`.
- **The new size:** machine or instance type, disk GB, min and max nodes.
- **A window** of a few hours in which your team can stop and start their spaces.

## 2. Check quota covers old and new at once

Both pools run together. See the `size-node-pools` skill, section 4. This is the usual
blocker, and a quota increase can take days.

## 3. Add the new pool to terraform.tfvars, leave the old one alone

GKE:

```hcl
spaces_pools = {
  spaces    = { machine_type = "e2-standard-4", disk_size_gb = 100 }   # old, unchanged
  spaces-v2 = { machine_type = "e2-standard-8", disk_size_gb = 300 }   # new
}
```

Give the new pool `min_node_count >= 1`: a pool with min 0 takes no load while another pool
has room. Size it in every zone that holds space volumes, because a space's volume is zonal
and its pod can only run in that zone.

EKS:

```hcl
spaces_node_groups = {
  v2 = { instance_types = ["m5.2xlarge"], disk_size_gb = 200, min_size = 1, max_size = 5 }
}
```

Then run `terraform plan` yourself. It must show **only additions**. If it shows the old pool
or group changing or being destroyed, stop and fix the tfvars. When it is clean, run
`terraform apply`.

## 4. Wait for the new nodes, then cordon the old ones (do not drain)

```bash
kubectl get nodes -L workload          # the new nodes are Ready
# GKE
kubectl cordon -l cloud.google.com/gke-nodepool=<old-pool-name>
# EKS
kubectl cordon -l eks.amazonaws.com/nodegroup=<cluster_name>-spaces
```

Running spaces keep running. New and restarted spaces land on the new pool.

## 5. Send your team this

> We are moving Marshal to larger nodes. Between now and <time, timezone>, please stop and
> start any space you are working in when you reach a good stopping point. It comes back on
> the new nodes, with its files. After <time> the old nodes are removed, and a space still
> running on them is stopped for you.

## 6. Watch the old nodes empty

```bash
kubectl get pods -n marshal-spaces -o wide --no-headers | grep <old-node-prefix>
```

List the spaces that are still there, so their owners can stop and start them.

## 7. Remove the old pool only at zero space pods

Run the count from step 6 immediately before you apply. Then edit `terraform.tfvars`:

- GKE: delete the old key from `spaces_pools`.
- EKS: set `create_default_spaces_node_group = false` (or delete the old entry from
  `spaces_node_groups`). The new group can stay in `spaces_node_groups` as your shape from now
  on.

Run `terraform plan`: it must show only the old pool being destroyed. Anything still on it
when it goes is killed. Then `terraform apply`.

The autoscaler (GKE pool autoscaling, or the EKS Cluster Autoscaler) removes empty nodes by
itself once the old nodes are cordoned and emptied, but it does not remove the pool or group.
Still delete it. Before then, set the old pool's min size to 0 if you want its nodes gone
sooner.

## 8. Roll back

Any time before step 7: `kubectl uncordon` the old nodes. Spaces schedule there again.

Afterwards, run the `install-health-check` skill to confirm every node is Ready and nothing is
Pending.
