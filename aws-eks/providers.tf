# Cluster access — works for BOTH postures:
#   • deploy_cluster = false (default): look up an EXISTING EKS cluster (BYO).
#   • deploy_cluster = true: provision a cluster (see cluster.tf) and wire the
#     providers to it.
#
# EKS auth: an `exec` credential plugin, NOT data.aws_eks_cluster_auth.
#
# The data source produces a presigned STS token once, early in the apply, and
# EKS stops accepting it about fifteen minutes later. On the provision path the
# apply spends far longer than that before it reaches any Kubernetes resource:
# measured on a real run, NAT 2m6s, then the cluster 7m48s, then node groups
# and addons. By the time the first kubernetes_* resource ran, the token was
# dead and the apply failed with
#
#   Error: Unauthorized
#   Error: Kubernetes cluster unreachable: the server has asked for the client
#          to provide credentials
#
# while the cluster itself was healthy: a fresh token reached it immediately.
# The old comment here argued the data source was safe because it needs no
# network call. That is true and beside the point. Availability was never the
# problem; expiry was.
#
# `exec` runs `aws eks get-token` at the moment the provider is used, so the
# token is always minutes old. It needs the AWS CLI on PATH, which the
# prerequisites already require, and it inherits this process's AWS_PROFILE and
# credentials.

provider "aws" {
  region = var.region
}

# Reuse path: read the existing cluster (only when NOT provisioning).
data "aws_eks_cluster" "existing" {
  count = var.deploy_cluster ? 0 : 1
  name  = var.cluster_name
}

locals {
  # Pick the active cluster's connection details from whichever path is on.
  # try() is required because a conditional evaluates BOTH branches: the
  # inactive side's count-0 resource/data source is null, and null.attr would
  # error. try() returns the first branch that resolves. When provisioning,
  # the created cluster's endpoint/CA are "known after apply" (unknown at
  # plan) — expected; Terraform defers the k8s/helm resources to apply.
  #
  # Unlike GKE's bare-hostname `endpoint` attribute, EKS's `endpoint` already
  # includes the "https://" scheme — used directly as `host` below, not
  # prefixed again.
  cluster_endpoint = try(
    one(aws_eks_cluster.this[*]).endpoint,
    one(data.aws_eks_cluster.existing[*]).endpoint,
  )
  cluster_ca = try(
    one(aws_eks_cluster.this[*]).certificate_authority[0].data,
    one(data.aws_eks_cluster.existing[*]).certificate_authority[0].data,
  )

  # Which registry host the helm provider logs in to, taken from the chart ref
  # itself rather than a separate variable, so the two can never disagree:
  # point `chart` at a mirror and the login follows it. Falls back to the
  # product registry for a local-path chart, where it is never exercised.
  chart_registry_host = startswith(var.chart, "oci://") ? split("/", trimprefix(var.chart, "oci://"))[0] : "registry.marshal.codes"
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }

  # Log helm in to the private chart registry with the pull token so an OCI
  # chart ref pulls without a manual `helm registry login`.
  #
  # NOT harmless when the token is wrong or empty, which an earlier version of
  # this comment claimed: the provider resolves this block while it CONFIGURES
  # itself, which happens during `terraform plan`, before any resource is read.
  # A bad token fails the whole plan with an error that names this file and
  # never mentions the token, and an EMPTY token does not skip the login, it
  # fails it. Confirmed live. One consequence worth knowing: a local-path chart
  # or a credential-free cache still needs a working token to get through plan.
  #
  # STATIC block, not `dynamic "registry"` — deploy/CLAUDE.md documents a real
  # bug (found on gcp-gke's first live customer deploy) where a conditional
  # `dynamic` block inside a `provider {}` block fails at plan/apply time
  # ("Cannot use a for_each value... An iterable collection is required"),
  # regardless of collection type, and `terraform validate` never catches it —
  # only a real `plan`/`apply` does. Always emit this block unconditionally.
  registry {
    url      = "oci://${local.chart_registry_host}"
    username = var.deployment_id
    password = var.registry_pull_token
  }
}
