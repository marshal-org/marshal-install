# EKS cluster provisioning — ALL of this is gated on deploy_cluster=true
# (count = 0 otherwise, so the reuse path creates none of it). Mirrors
# gcp-gke/cluster.tf's structure: a VPC with private (node) + public (NAT)
# subnets per AZ, private nodes, egress via NAT, and two node groups (spaces +
# control-plane) matching GKE's pool split.
#
# Every resource is namespaced under var.cluster_name throughout, so this is
# safe to apply in an account that already holds unrelated EKS clusters.
#
# The network comes from one of two places: this file creates it
# (create_network = true, the default), or you bring a VPC and subnets you
# already run (create_network = false). Everything downstream reads
# local.vpc_id / local.private_subnet_ids / local.public_subnet_ids and never
# the resources or the variables directly, so the two postures differ in
# exactly one place.

locals {
  provision = var.deploy_cluster

  # ── The network, from whichever source ──────────────────────────────────────
  # one() rather than [0] so these stay valid when the resources do not exist:
  # a local is evaluated whenever anything references it, even when every
  # resource referencing it has count = 0.
  vpc_id             = var.create_network ? one(aws_vpc.this[*].id) : var.vpc_id
  public_subnet_ids  = var.create_network ? [for s in aws_subnet.public : s.id] : var.public_subnet_ids
  private_subnet_ids = var.create_network ? [for s in aws_subnet.private : s.id] : var.private_subnet_ids

  # id + AZ per private subnet, which is what node placement needs. On the
  # created path the AZ is the for_each key; on the reuse path it has to be read
  # back from AWS, because a subnet id does not carry its AZ.
  private_subnets = var.create_network ? [
    for az, s in aws_subnet.private : { id = s.id, az = az }
    ] : [
    for s in data.aws_subnet.reused_private : { id = s.id, az = s.availability_zone }
  ]

  # Which private subnets the node groups land in. Pinning to one AZ removes
  # cross-AZ transfer charges between nodes, ALB and RDS; the cluster itself
  # still spans every AZ it was given, because EKS requires at least two. See
  # node_availability_zone for the availability tradeoff.
  node_subnet_ids = var.node_availability_zone != "" ? [
    for s in local.private_subnets : s.id if s.az == var.node_availability_zone
  ] : local.private_subnet_ids

  # AZ name -> index, used to derive per-AZ subnet CIDRs and NAT placement.
  az_indices = { for idx, az in var.availability_zones : az => idx }

  # Which AZ(s) get a NAT gateway: all of them (HA egress) or just the first
  # (single_nat_gateway=true, the cheaper POC default).
  nat_azs = var.single_nat_gateway ? slice(keys(local.az_indices), 0, min(1, length(local.az_indices))) : keys(local.az_indices)
}

# ── Reading back a network you brought (create_network = false) ──────────────
# A subnet id carries neither its AZ nor its VPC, and plan-time validation of
# both is the whole point of the preconditions in main.tf.
#
# Egress is deliberately NOT checked here. The obvious way to do it, an
# aws_route_table data source per subnet, does not work: given only a subnet_id
# it errors with "no matching Route Table found" when the subnet has no
# EXPLICIT association, instead of resolving the VPC's main table the way the
# network actually does (verified live). Doing it properly means reading every
# route table in the VPC and reimplementing association resolution, which is
# more machinery than the check is worth. scripts/preflight-aws.sh already
# checks egress per subnet, read-only and before tfvars exist.
data "aws_subnet" "reused_private" {
  for_each = local.provision && !var.create_network ? toset(var.private_subnet_ids) : toset([])
  id       = each.key
}

data "aws_subnet" "reused_public" {
  for_each = local.provision && !var.create_network ? toset(var.public_subnet_ids) : toset([])
  id       = each.key
}

# ── VPC + subnets (create_network = true) ────────────────────────────────────
resource "aws_vpc" "this" {
  count                = local.provision && var.create_network ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  count  = local.provision && var.create_network ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  tags   = { Name = "${var.cluster_name}-igw" }
}

# Public subnets host only the NAT gateway(s) — nodes never get public IPs.
resource "aws_subnet" "public" {
  for_each                = local.provision && var.create_network ? local.az_indices : {}
  vpc_id                  = aws_vpc.this[0].id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value)
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.cluster_name}-public-${each.key}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # REQUIRED for the AWS Load Balancer Controller's subnet auto-discovery —
    # without this tag an internet-facing ALB has no subnets to choose from
    # and the Ingress never gets an address, silently, forever (the AWS-side
    # analog of GKE's missing addons_config.http_load_balancing incident —
    # same failure shape, different missing knob).
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  for_each          = local.provision && var.create_network ? local.az_indices : {}
  vpc_id            = aws_vpc.this[0].id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value + 100)

  tags = {
    Name                                        = "${var.cluster_name}-private-${each.key}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Same requirement as above, for an INTERNAL ALB's subnet discovery.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "public" {
  count  = local.provision && var.create_network ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
  tags = { Name = "${var.cluster_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public[0].id
}

# ── NAT gateway(s) — REQUIRED egress for private nodes ───────────────────────
# Without NAT, private nodes cannot reach registry.marshal.codes and the
# install fails on image pulls.
resource "aws_eip" "nat" {
  for_each = local.provision && var.create_network ? toset(local.nat_azs) : toset([])
  domain   = "vpc"
  tags     = { Name = "${var.cluster_name}-nat-eip-${each.key}" }
}

resource "aws_nat_gateway" "this" {
  for_each      = local.provision && var.create_network ? toset(local.nat_azs) : toset([])
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = { Name = "${var.cluster_name}-nat-${each.key}" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  for_each = local.provision && var.create_network ? local.az_indices : {}
  vpc_id   = aws_vpc.this[0].id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? local.nat_azs[0] : each.key].id
  }
  tags = { Name = "${var.cluster_name}-private-rt-${each.key}" }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# ── Cluster IAM role ──────────────────────────────────────────────────────────
resource "aws_iam_role" "cluster" {
  count = local.provision ? 1 : 0
  name  = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  count      = local.provision ? 1 : 0
  role       = aws_iam_role.cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── EKS cluster ───────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "this" {
  count    = local.provision ? 1 : 0
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster[0].arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(local.public_subnet_ids, local.private_subnet_ids)
    endpoint_private_access = var.cluster_endpoint_private_access
    endpoint_public_access  = var.cluster_endpoint_public_access
    public_access_cidrs     = [for c in var.cluster_endpoint_public_access_cidrs : c.cidr_block]
  }

  # Pinned explicitly (rather than left to AWS's own VPC-CIDR-dependent
  # default of 10.100.0.0/16 or 172.20.0.0/16) so a static ClusterIP — used by
  # the optional Harbor cache (harbor.tf) to give nodes a DNS-free registry
  # address — can be chosen with certainty it falls inside the real service
  # range, instead of guessing which default AWS picked.
  kubernetes_network_config {
    service_ipv4_cidr = var.service_ipv4_cidr
  }

  # Auto-grants the applying identity cluster-admin access at creation time —
  # the EKS-specific half of the same-apply bootstrap problem (the token
  # authenticates fine regardless, but without this nothing tells the API
  # server this identity may DO anything; every kubernetes_*/helm_release
  # call would otherwise 403). GKE has no equivalent step: any IAM principal
  # with container.clusters.get can act on a GKE cluster with no separate
  # authorization list.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = { Name = var.cluster_name }

  depends_on = [aws_iam_role_policy_attachment.cluster, aws_nat_gateway.this]
}

# A `check` block here would be non-blocking (confirmed live — see main.tf's
# guardrails comment for the full explanation), and this specific one is a
# real security control: without it, `cluster_endpoint_public_access=true`
# with an empty CIDR list would only warn, not stop, an API endpoint open to
# the internet. An output precondition is the mechanism confirmed live to
# actually halt `plan`.
output "_cluster_endpoint_public_access_cidrs_supplied" {
  value = null
  precondition {
    condition     = !var.deploy_cluster || !var.cluster_endpoint_public_access || length(var.cluster_endpoint_public_access_cidrs) > 0
    error_message = "cluster_endpoint_public_access=true requires cluster_endpoint_public_access_cidrs (at least your admin/CI CIDR) — otherwise you cannot reach the control plane."
  }
}

# ── Node IAM role (shared by both node groups) ───────────────────────────────
resource "aws_iam_role" "node" {
  count = local.provision ? 1 : 0
  name  = "${var.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  count      = local.provision ? 1 : 0
  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  count      = local.provision ? 1 : 0
  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  count      = local.provision ? 1 : 0
  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ── Node groups ───────────────────────────────────────────────────────────────
# TWO groups (see variables.tf for why they're never sized the same): "spaces"
# runs session/space workloads; "control_plane" is a separate, smaller group
# for the long-lived api/gateway/web/marketplace/redis pods. Both created
# unconditionally when provisioning; taint_control_plane_pool controls whether
# the split actually ISOLATES anything (main.tf derives the matching chart
# toleration from the same toggle).
resource "aws_eks_node_group" "spaces" {
  count           = local.provision ? 1 : 0
  cluster_name    = aws_eks_cluster.this[0].name
  node_group_name = "${var.cluster_name}-spaces"
  node_role_arn   = aws_iam_role.node[0].arn
  subnet_ids      = local.node_subnet_ids
  instance_types  = var.node_instance_types
  disk_size       = var.node_disk_size_gb
  labels          = { workload = "spaces" }

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = var.node_group_update_max_unavailable
  }

  # Only present when the optional Harbor cache (harbor.tf) is enabled — see
  # that file's aws_launch_template.harbor_containerd_config for what this
  # actually configures (a containerd registry-mirror pointing at Harbor's
  # static ClusterIP as plain HTTP) and why every node needs it, not just one
  # group.
  dynamic "launch_template" {
    for_each = var.create_harbor_cache ? [1] : []
    content {
      id      = aws_launch_template.harbor_containerd_config[0].id
      version = aws_launch_template.harbor_containerd_config[0].latest_version
    }
  }

  # Explicit: node groups have no attribute-level reference to the private
  # route table associations (only to the subnets themselves), so Terraform's
  # inferred dependency graph does NOT wait for the private subnets to
  # actually be associated with the NAT-routed route table before creating
  # nodes — confirmed live: a node group was scheduled and its instance
  # booted BEFORE aws_route_table_association.private ever ran, leaving the
  # node on the VPC's default (no-NAT-route) main route table with no egress
  # at all — nodeadm's own ec2:DescribeInstances bootstrap call retried
  # forever with no path to the EC2 API. Without this, that race can recur on
  # any fresh apply.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_route_table_association.private,
  ]
}

resource "aws_eks_node_group" "control_plane" {
  count           = local.provision ? 1 : 0
  cluster_name    = aws_eks_cluster.this[0].name
  node_group_name = "${var.cluster_name}-control-plane"
  node_role_arn   = aws_iam_role.node[0].arn
  subnet_ids      = local.node_subnet_ids
  instance_types  = var.control_plane_instance_types
  disk_size       = var.control_plane_disk_size_gb
  labels          = { workload = "control-plane" }

  scaling_config {
    desired_size = var.control_plane_desired_size
    min_size     = var.control_plane_min_size
    max_size     = var.control_plane_max_size
  }

  update_config {
    max_unavailable = var.node_group_update_max_unavailable
  }

  # DEFAULT FALSE — see taint_control_plane_pool's description. An empty
  # dynamic block means no taint at all: this group behaves like any other
  # untainted group until deliberately flipped on.
  dynamic "taint" {
    for_each = var.taint_control_plane_pool ? [1] : []
    content {
      key    = "workload"
      value  = "control-plane"
      effect = "NO_SCHEDULE" # EKS API spelling — distinct from the k8s-native "NoSchedule" the chart's own toleration value uses (main.tf).
    }
  }

  # Same containerd registry-mirror config as the spaces group above — see
  # harbor.tf. Both groups need it: either could run pods pulling Marshal's
  # own images.
  dynamic "launch_template" {
    for_each = var.create_harbor_cache ? [1] : []
    content {
      id      = aws_launch_template.harbor_containerd_config[0].id
      version = aws_launch_template.harbor_containerd_config[0].latest_version
    }
  }

  # Explicit: node groups have no attribute-level reference to the private
  # route table associations (only to the subnets themselves), so Terraform's
  # inferred dependency graph does NOT wait for the private subnets to
  # actually be associated with the NAT-routed route table before creating
  # nodes — confirmed live: a node group was scheduled and its instance
  # booted BEFORE aws_route_table_association.private ever ran, leaving the
  # node on the VPC's default (no-NAT-route) main route table with no egress
  # at all — nodeadm's own ec2:DescribeInstances bootstrap call retried
  # forever with no path to the EC2 API. Without this, that race can recur on
  # any fresh apply.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_route_table_association.private,
  ]
}
