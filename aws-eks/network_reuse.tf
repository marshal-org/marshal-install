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
# Set tag_existing_subnets = false when your own Terraform or CloudFormation
# owns those subnets' tags, and add them yourself. Two things to know before
# you do: a stack that manages the whole tag set will fight this on every
# apply, and turning this off AFTER an apply does not leave the tags behind,
# it removes them, which breaks the load balancer at the next reconcile.

locals {
  tag_reused_subnets = local.provision && !var.create_network && var.tag_existing_subnets

  # Flattened to (subnet, tag) pairs, keyed "<subnet-id>/<tag-key>" so the key
  # stays stable when the subnet list changes.
  reused_subnet_tags = !local.tag_reused_subnets ? {} : merge(
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
}

resource "aws_ec2_tag" "reused_subnet" {
  for_each    = local.reused_subnet_tags
  resource_id = each.value.subnet_id
  key         = each.value.key
  value       = each.value.value
}

# The CIDR of a VPC you brought. Needed because the installer opens the
# Kubernetes API endpoint to the VPC's own range by default (see
# cluster_private_access.tf); on the created path that value is var.vpc_cidr,
# but on this path only AWS knows it.
data "aws_vpc" "reused" {
  count = local.provision && !var.create_network ? 1 : 0
  id    = var.vpc_id
}
