# Harbor pull-through cache — an OPT-IN FALLBACK, not a default. Use only when
# the native cloud pull-through cache doesn't work: on AWS, it never does —
# confirmed live against the real ECR API that CreatePullThroughCacheRule
# only accepts a hardcoded enum of known upstreams and validates the URL
# server-side against each type's real hostname, so it can never mirror
# registry.marshal.codes (see registry_auth_mode's description in
# variables.tf). Harbor's proxy-cache feature CAN, using its generic
# "docker-registry" adapter type — verified against Harbor's own supported-
# registry-types list, not assumed.
#
# Deployed as part of THIS cluster (not a separate service), pinned to the
# control-plane node group — it's platform infrastructure, not a session
# workload. Storage is S3 (var.harbor_storage_s3_regionendpoint lets a future
# non-AWS flavor point this at any S3-compatible store instead — kept
# cloud-agnostic in shape, nothing built into gcp-gke today).
#
# ALL gated on deploy_cluster=true — this needs the VPC/cluster/node groups
# this flavor provisions; it's not wired into the reuse path.

variable "create_harbor_cache" {
  description = "Provision Harbor in-cluster as a pull-through cache for registry.marshal.codes. false (default) — an opt-in fallback, not a replacement for direct-pull. Requires deploy_cluster=true (checked below)."
  type        = bool
  default     = false
}

variable "harbor_chart_version" {
  description = "Harbor Helm chart version. Pinned to a version whose appVersion (Harbor server version) is >= 2.15 — required by the goharbor/harbor Terraform provider used to configure the proxy-cache project below."
  type        = string
  default     = "1.19.1" # Harbor 2.15.1
}

variable "harbor_namespace" {
  description = "Namespace Harbor runs in."
  type        = string
  default     = "harbor-cache"
}

variable "harbor_static_cluster_ip" {
  description = <<-EOT
    A fixed ClusterIP for Harbor's core service, chosen (not read back after
    apply) so it can be used directly as the registry address AND baked into
    both node groups' containerd config in the SAME apply, with no ordering
    dependency. Nodes pull images via containerd running on the HOST network
    namespace, which cannot resolve *.svc.cluster.local names (only pods'
    injected resolv.conf can) — a ClusterIP sidesteps DNS entirely, since
    kube-proxy's iptables/IPVS rules DNAT it regardless of source, including
    from the host netns. Must fall inside var.service_ipv4_cidr; the default
    (near the top of the default 172.20.0.0/16 range) avoids the low addresses
    kube-system services (e.g. kube-dns) typically occupy.
  EOT
  type        = string
  default     = "172.20.255.254"
}

variable "harbor_storage_s3_regionendpoint" {
  description = "Override S3 endpoint for a non-AWS S3-compatible store (e.g. GCS's XML/S3-interop endpoint, or MinIO). \"\" (default) uses native AWS S3."
  type        = string
  default     = ""
}

locals {
  create_harbor = local.provision && var.create_harbor_cache

  # Pinning Harbor to the control-plane group: same nodeSelector/tolerations
  # shape main.tf already derives for the chart itself from
  # taint_control_plane_pool. The LABEL (workload=control-plane) always
  # exists on that group regardless of the taint toggle, so this works
  # whether or not the pool is actually tainted.
  harbor_node_selector = { workload = "control-plane" }
  harbor_tolerations = [
    { key = "workload", operator = "Equal", value = "control-plane", effect = "NoSchedule" }
  ]
}

# output precondition, not `check` — see main.tf's guardrails comment: a
# `check` assertion only ever warns, confirmed live, so it can't actually
# stop this combination from being applied.
output "_harbor_cache_requires_provisioning" {
  value = null
  precondition {
    condition     = !var.create_harbor_cache || var.deploy_cluster
    error_message = "create_harbor_cache=true requires deploy_cluster=true — Harbor is wired into the provisioning path only."
  }
}

# ── Node-level containerd config ─────────────────────────────────────────────
# Registry references (var.registry, once effective_registry in main.tf
# points here) become IP-literal, e.g. "172.20.255.254/cache/marshal/api:tag"
# — but containerd assumes HTTPS for any registry host unless told otherwise,
# and a raw ClusterIP has no valid hostname for a certificate to match anyway.
# This NodeConfig snippet (EKS AL2023's nodeadm bootstrap mechanism) tells
# containerd to treat this exact IP as plain HTTP. nodeadm MERGES this with
# the cluster-join NodeConfig EKS generates automatically for a managed node
# group — this file supplies ONLY the containerd addition, not cluster/join
# info.
resource "aws_launch_template" "harbor_containerd_config" {
  count = local.create_harbor ? 1 : 0
  name  = "${var.cluster_name}-harbor-containerd-config"

  user_data = base64encode(<<-EOT
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      containerd:
        config: |
          [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${var.harbor_static_cluster_ip}"]
            endpoint = ["http://${var.harbor_static_cluster_ip}"]
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-node" }
  }
}

# ── S3 storage for Harbor's blob store ───────────────────────────────────────
resource "aws_s3_bucket" "harbor" {
  count  = local.create_harbor ? 1 : 0
  bucket = "${var.cluster_name}-harbor-cache-${data.aws_caller_identity.current[0].account_id}"

  # Cache data only — reconstructible from upstream on a cold start. No
  # versioning, no lifecycle/backup policy needed.
  force_destroy = true

  tags = { Name = "${var.cluster_name}-harbor-cache" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "harbor" {
  count  = local.create_harbor ? 1 : 0
  bucket = aws_s3_bucket.harbor[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_caller_identity" "current" {
  count = local.create_harbor ? 1 : 0
}

# ── IRSA for Harbor's registry component (credential-less S3 access) ────────
data "aws_iam_policy_document" "harbor_registry_assume_role" {
  count = local.create_harbor ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.harbor_namespace}:harbor-registry"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "harbor_registry" {
  count              = local.create_harbor ? 1 : 0
  name               = "${var.cluster_name}-harbor-registry-role"
  assume_role_policy = data.aws_iam_policy_document.harbor_registry_assume_role[0].json
}

data "aws_iam_policy_document" "harbor_registry_s3" {
  count = local.create_harbor ? 1 : 0
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.harbor[0].arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.harbor[0].arn}/*"]
  }
}

resource "aws_iam_role_policy" "harbor_registry_s3" {
  count  = local.create_harbor ? 1 : 0
  name   = "${var.cluster_name}-harbor-registry-s3"
  role   = aws_iam_role.harbor_registry[0].id
  policy = data.aws_iam_policy_document.harbor_registry_s3[0].json
}

resource "kubernetes_namespace" "harbor" {
  depends_on = [aws_security_group_rule.cluster_private_access]
  count      = local.create_harbor ? 1 : 0
  metadata {
    name = var.harbor_namespace
  }
}

resource "kubernetes_service_account" "harbor_registry" {
  depends_on = [aws_security_group_rule.cluster_private_access]
  count      = local.create_harbor ? 1 : 0
  metadata {
    name      = "harbor-registry"
    namespace = kubernetes_namespace.harbor[0].metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.harbor_registry[0].arn
    }
  }
}

resource "random_password" "harbor_admin" {
  count   = local.create_harbor ? 1 : 0
  length  = 24
  special = false
}

# ── Harbor itself ─────────────────────────────────────────────────────────────
resource "helm_release" "harbor" {
  count      = local.create_harbor ? 1 : 0
  name       = "harbor"
  repository = "https://helm.goharbor.io"
  chart      = "harbor"
  version    = var.harbor_chart_version
  namespace  = kubernetes_namespace.harbor[0].metadata[0].name

  values = [yamlencode({
    expose = {
      type = "clusterIP"
      tls  = { enabled = false } # internal-only, plain HTTP — see the containerd note above for why.
      clusterIP = {
        name            = "harbor"
        staticClusterIP = var.harbor_static_cluster_ip
      }
    }
    externalURL         = "http://${var.harbor_static_cluster_ip}"
    harborAdminPassword = random_password.harbor_admin[0].result

    persistence = {
      imageChartStorage = {
        type = "s3"
        s3 = merge(
          {
            region = var.region
            bucket = aws_s3_bucket.harbor[0].bucket
          },
          var.harbor_storage_s3_regionendpoint == "" ? {} : { regionendpoint = var.harbor_storage_s3_regionendpoint },
        )
      }
    }

    registry = {
      serviceAccountName = kubernetes_service_account.harbor_registry[0].metadata[0].name
    }

    # Lean footprint — pure cache, no vulnerability scanning.
    trivy = { enabled = false }

    # Pin every component to the control-plane group (see locals above).
    nginx      = { nodeSelector = local.harbor_node_selector, tolerations = local.harbor_tolerations }
    portal     = { nodeSelector = local.harbor_node_selector, tolerations = local.harbor_tolerations }
    core       = { nodeSelector = local.harbor_node_selector, tolerations = local.harbor_tolerations }
    jobservice = { nodeSelector = local.harbor_node_selector, tolerations = local.harbor_tolerations }
    registry   = { nodeSelector = local.harbor_node_selector, tolerations = local.harbor_tolerations }
    database   = { nodeSelector = local.harbor_node_selector, tolerations = local.harbor_tolerations }
    redis      = { nodeSelector = local.harbor_node_selector, tolerations = local.harbor_tolerations }
  })]

  depends_on = [
    kubernetes_service_account.harbor_registry,
    aws_iam_role_policy.harbor_registry_s3,
    aws_eks_node_group.control_plane,
    # Destroyed AFTER this resource, which is the point: it is the rule that
    # lets this host reach the API at all. Without the edge, terraform removed
    # it first and then could not delete what was left, failing the destroy
    # with `dial tcp <endpoint>:443: i/o timeout`.
    aws_security_group_rule.cluster_private_access,
  ]
}

# ── Configuring the proxy (not just installing it) ───────────────────────────
# The `harbor` provider talks to Harbor's REST API over plain HTTP at its
# ClusterIP. A ClusterIP is only routable from INSIDE the cluster (kube-proxy
# programs the DNAT rule on each NODE's own network namespace) — the bastion
# is a plain EC2 instance, not a cluster node, so it CANNOT reach the
# ClusterIP directly the way node-level containerd can. Unlike node pulls,
# this is a ONE-TIME configuration call, not an ongoing data path, so rather
# than stand up a second internal load balancer just for this, the documented
# apply workflow (README.md) is: from the bastion, background a
# `kubectl port-forward -n harbor-cache svc/harbor 8080:80` before running
# `terraform apply`. This provider block always points at that local forward
# — harmless (never invoked) when create_harbor_cache=false.
provider "harbor" {
  url      = "http://localhost:8080"
  username = "admin"
  password = try(random_password.harbor_admin[0].result, "")
}

resource "harbor_registry" "marshal" {
  count         = local.create_harbor ? 1 : 0
  name          = "marshal-codes"
  provider_name = "docker-registry"
  endpoint_url  = "https://registry.marshal.codes"
  access_id     = var.deployment_id
  access_secret = var.registry_pull_token

  depends_on = [helm_release.harbor]
}

resource "harbor_project" "cache" {
  count       = local.create_harbor ? 1 : 0
  name        = "cache"
  registry_id = harbor_registry.marshal[0].registry_id
  # Public (anonymous read) — safe because this is only reachable from inside
  # the private VPC/cluster network, and it's what lets registry_auth_mode
  # become "none" for the cache path below (no pull secret to manage).
  public                         = true
  vulnerability_scanning         = false # no scanner running (trivy disabled above)
  proxy_cache_local_on_not_found = true  # keep serving cached images through an upstream outage, same resilience property GCP AR's remote-repository mode already has
}

locals {
  harbor_registry_endpoint       = local.create_harbor ? "${var.harbor_static_cluster_ip}/${harbor_project.cache[0].name}/marshal" : null
  harbor_tools_registry_endpoint = local.create_harbor ? "${var.harbor_static_cluster_ip}/${harbor_project.cache[0].name}/marshal-tools" : null
}
