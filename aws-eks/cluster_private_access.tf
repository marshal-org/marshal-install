# ── Who may reach the Kubernetes API endpoint from inside the VPC ────────────
# A host inside the VPC still cannot reach a private-only API endpoint. The
# EKS-managed cluster security group is created with ONE inbound rule: all
# traffic from itself. The nodes carry that group, so they can reach the
# endpoint and nothing else can.
#
# Confirmed live, and it is an expensive failure to hit late: an administrative
# host in a private subnet of the cluster's own VPC, holding cluster-creator
# admin, failed on the FIRST Kubernetes resource with
#
#   Kubernetes cluster unreachable: dial tcp 10.90.148.52:443: i/o timeout
#
# after all 32 AWS resources had been created. Every customer reaching their
# VPC over a VPN, a zero-trust connector or a jump host would hit the same
# thing on their first apply, which is why this is open by default rather than
# documented as a prerequisite.
#
# Opening it to the VPC's own CIDR is not the same as making the API public.
# The endpoint has no public address at all, and reaching it still requires an
# AWS IAM identity with an EKS access entry plus Kubernetes RBAC. This decides
# which packets arrive, not who is allowed in. Narrow it with
# cluster_private_access_cidrs if your policy requires that, and remember to
# include whatever range your tunnel presents.
locals {
  vpc_cidr_effective = var.create_network ? var.vpc_cidr : try(one(data.aws_vpc.reused[*]).cidr_block, "")

  cluster_private_access_cidrs = length(var.cluster_private_access_cidrs) > 0 ? (
    var.cluster_private_access_cidrs
  ) : compact([local.vpc_cidr_effective])
}

resource "aws_security_group_rule" "cluster_private_access" {
  count             = local.provision && length(local.cluster_private_access_cidrs) > 0 ? 1 : 0
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id
  cidr_blocks       = local.cluster_private_access_cidrs
  description       = "Reach the Kubernetes API from inside the VPC: the install, and every later upgrade"
}
