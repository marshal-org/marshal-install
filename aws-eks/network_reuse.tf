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
# A tag your subnets ALREADY carried is never adopted, so `terraform destroy`
# cannot remove it. Getting that right needs a record of what the installer
# added, and the obvious shortcut does not work:
#
#   Filtering the for_each against the subnets' LIVE tags is unstable, because
#   it cannot tell "already yours" from "mine, added last apply". Apply 1
#   creates the tag; apply 2 reads it back as pre-existing, drops the key from
#   the map and DESTROYS it. Measured 2026-10-19:
#
#     # aws_ec2_tag.reused_subnet["subnet-.../cluster"] will be destroyed
#     # (because key [...] is not in for_each map)
#
#   An upgrade is `chart_version` plus `terraform apply`, so that stripped the
#   cluster tag on a routine upgrade, with no event to say why.
#
# So the installer writes down what it owns, in a tag of its own on each subnet
# (marshal.codes/installer-owned-tags). Everything present and NOT named there
# was yours before we arrived, and is left alone. That record is read back from
# AWS at plan time, which keeps the for_each known at plan and the decision
# identical on every subsequent apply.
#
# Set tag_existing_subnets = false when your own Terraform or CloudFormation
# owns those subnets' tags, and add them yourself. Two things to know before
# you do: a stack that manages the whole tag set will fight this on every
# apply, and turning this off AFTER an apply removes the tags the installer
# added, which breaks the load balancer at the next reconcile. Tags that were
# already yours are untouched either way.

locals {
  tag_reused_subnets = local.provision && !var.create_network && var.tag_existing_subnets

  reused_subnet_ids = local.tag_reused_subnets ? distinct(concat(
    var.private_subnet_ids, var.public_subnet_ids
  )) : []

  # The marker tag. Its value is the sorted, comma-joined list of the tag keys
  # this installer manages on that subnet.
  owned_marker_key = "marshal.codes/installer-owned-tags"

  # What this cluster needs, per subnet.
  #   private: an INTERNAL load balancer's subnet discovery
  #   public:  an INTERNET-FACING load balancer's subnet discovery
  #   both:    which cluster may use the subnet. "shared" is correct for a
  #            subnet other clusters also use, the normal case when the VPC is
  #            yours rather than ours.
  wanted_subnet_tags = {
    for id in local.reused_subnet_ids : id => merge(
      contains(var.private_subnet_ids, id) ? { "kubernetes.io/role/internal-elb" = "1" } : {},
      contains(var.public_subnet_ids, id) ? { "kubernetes.io/role/elb" = "1" } : {},
      { "kubernetes.io/cluster/${var.cluster_name}" = "shared" },
    )
  }

  # What the installer claimed on the previous apply, read back off the subnet.
  # Empty on a first apply, which is what makes everything already there yours.
  owned_previously = {
    for id in local.reused_subnet_ids : id => compact(split(",",
    try(data.aws_subnet.reused[id].tags[local.owned_marker_key], "")))
  }

  # Present, and not claimed by the marker, therefore yours.
  subnet_tags_already_yours = {
    for id in local.reused_subnet_ids : id => [
      for k in keys(try(data.aws_subnet.reused[id].tags, {})) : k
      if !contains(local.owned_previously[id], k)
    ]
  }

  # Flattened to (subnet, tag) pairs, keyed "<subnet-id>/<tag-key>" so the key
  # stays stable when the subnet list changes.
  reused_subnet_tags = length(local.reused_subnet_ids) == 0 ? {} : merge([
    for id in local.reused_subnet_ids : {
      for k, v in local.wanted_subnet_tags[id] :
      "${id}/${k}" => { subnet_id = id, key = k, value = v }
      if !contains(local.subnet_tags_already_yours[id], k)
    }
  ]...)

  # The same decision, written where the next apply can read it.
  reused_subnet_marker = {
    for id in local.reused_subnet_ids : id => join(",", sort([
      for k, v in local.wanted_subnet_tags[id] : k
      if !contains(local.subnet_tags_already_yours[id], k)
    ]))
  }
}

# Read at plan time, so the for_each below is known at plan. Only on the reuse
# path, where the subnets exist before this apply runs.
data "aws_subnet" "reused" {
  for_each = toset(local.reused_subnet_ids)
  id       = each.key
}

resource "aws_ec2_tag" "reused_subnet" {
  for_each    = local.reused_subnet_tags
  resource_id = each.value.subnet_id
  key         = each.value.key
  value       = each.value.value
}

# Destroyed with the tags it describes, so a teardown leaves the subnet exactly
# as it was found.
resource "aws_ec2_tag" "reused_subnet_marker" {
  for_each    = { for id, v in local.reused_subnet_marker : id => v if v != "" }
  resource_id = each.key
  key         = local.owned_marker_key
  value       = each.value
}

output "subnet_tags_left_as_yours" {
  description = "Tags this cluster needs that your subnets already carried. Not managed here, so a destroy does not remove them."
  value = sort(flatten([
    for id in local.reused_subnet_ids : [
      for k, v in local.wanted_subnet_tags[id] : "${id} ${k}"
      if contains(local.subnet_tags_already_yours[id], k)
    ]
  ]))
}

# The CIDR of a VPC you brought. Needed because the installer opens the
# Kubernetes API endpoint to the VPC's own range by default (see
# cluster_private_access.tf); on the created path that value is var.vpc_cidr,
# but on this path only AWS knows it.
data "aws_vpc" "reused" {
  count = local.provision && !var.create_network ? 1 : 0
  id    = var.vpc_id
}
