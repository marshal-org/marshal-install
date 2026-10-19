# ── Tags on a network you brought (create_network = false) ───────────────────
# EKS and the AWS Load Balancer Controller both discover subnets by tag, and
# both fail quietly when the tag is missing: the controller picks no subnets,
# the Ingress never gets an address, and NO Kubernetes event is emitted to say
# why. That is expensive to diagnose live, so the installer adds the tags by
# default rather than documenting them and hoping.
#
# aws_ec2_tag manages ONE tag on an existing resource, so every other tag on
# your subnets is left exactly as it is. The subnets this flavor creates itself
# carry the same three tags (see cluster.tf), which is where the values come
# from.
#
# A tag your subnets ALREADY carry is left alone entirely: not adopted, not
# overwritten, and not removed at destroy. That matters because aws_ec2_tag
# takes ownership of whatever it manages, so adopting a tag you already had
# means `terraform destroy` DELETES it. Confirmed live on 2026-10-19: a
# teardown stripped kubernetes.io/role/internal-elb from two private subnets
# that carried it before the install ever ran, which would silently stop any
# other internal load balancer in that VPC from getting an address.
#
# Set tag_existing_subnets = false when your own Terraform or CloudFormation
# owns those subnets' tags, and add them yourself. Two things to know before
# you do: a stack that manages the whole tag set will fight this on every
# apply, and turning this off AFTER an apply removes the tags this installer
# added, which breaks the load balancer at the next reconcile. Tags you
# already had are unaffected either way.

locals {
  tag_reused_subnets = local.provision && !var.create_network && var.tag_existing_subnets

  # Flattened to (subnet, tag) pairs, keyed "<subnet-id>/<tag-key>" so the key
  # stays stable when the subnet list changes.
  reused_subnet_tags_wanted = !local.tag_reused_subnets ? {} : merge(
    # Private: an INTERNAL load balancer's subnet discovery.
    {
      for id in var.private_subnet_ids :
      "${id}/internal-elb" => { subnet_id = id, key = "kubernetes.io/role/internal-elb", value = "1" }
    },
    # Public: an INTERNET-FACING load balancer's subnet discovery.
    {
      for id in var.public_subnet_ids :
      "${id}/elb" => { subnet_id = id, key = "kubernetes.io/role/elb", value = "1" }
    },
    # Both: which cluster may use the subnet. "shared" is the correct value for
    # a subnet other clusters also use, which is the normal case when the VPC
    # is yours rather than ours.
    {
      for id in concat(var.private_subnet_ids, var.public_subnet_ids) :
      "${id}/cluster" => { subnet_id = id, key = "kubernetes.io/cluster/${var.cluster_name}", value = "shared" }
    },
  )

  # What is actually missing. A key already present on the subnet is dropped
  # here, whatever its value, so this installer never owns and never deletes a
  # tag that was not ours to begin with.
  reused_subnet_tags = {
    for k, v in local.reused_subnet_tags_wanted : k => v
    if !contains(keys(try(data.aws_subnet.reused[v.subnet_id].tags, {})), v.key)
  }

  reused_subnet_tags_already_yours = sort([
    for k, v in local.reused_subnet_tags_wanted : "${v.subnet_id} ${v.key}"
    if contains(keys(try(data.aws_subnet.reused[v.subnet_id].tags, {})), v.key)
  ])
}

# Read so the filter above can tell "missing" from "already there". Only on the
# reuse path, where the subnets exist before this apply runs.
data "aws_subnet" "reused" {
  for_each = local.tag_reused_subnets ? toset(concat(var.private_subnet_ids, var.public_subnet_ids)) : toset([])
  id       = each.key
}

resource "aws_ec2_tag" "reused_subnet" {
  for_each    = local.reused_subnet_tags
  resource_id = each.value.subnet_id
  key         = each.value.key
  value       = each.value.value
}

# Visible on purpose: these are the tags the installer found and deliberately
# did not touch, so a teardown leaves them in place.
output "subnet_tags_left_as_yours" {
  description = "Subnet tags the cluster needs that your subnets already had. Not managed here, so a destroy does not remove them."
  value       = local.reused_subnet_tags_already_yours
}

# The CIDR of a VPC you brought. Needed because the installer opens the
# Kubernetes API endpoint to the VPC's own range by default (see
# cluster_private_access.tf); on the created path that value is var.vpc_cidr,
# but on this path only AWS knows it.
data "aws_vpc" "reused" {
  count = local.provision && !var.create_network ? 1 : 0
  id    = var.vpc_id
}
