# Cluster access — works for BOTH postures:
#   • deploy_cluster = false (default): look up an EXISTING GKE cluster (BYO).
#   • deploy_cluster = true: provision a private cluster (see cluster.tf) and wire
#     the providers to it.
# Either way the kubernetes + helm providers authenticate with a short-lived GCP
# access token from your Application Default Credentials — no kubeconfig file.

provider "google" {
  project = var.project_id
  region  = var.location
}

data "google_client_config" "default" {}

# Reuse path: read the existing cluster (only when NOT provisioning).
data "google_container_cluster" "existing" {
  count    = var.deploy_cluster ? 0 : 1
  name     = var.cluster_name
  location = var.location
  project  = var.project_id
}

locals {
  # Pick the active cluster's connection details from whichever path is on. try()
  # is required because a conditional evaluates BOTH branches: the inactive side's
  # count-0 resource/data source is null, and null.attr would error. try() returns
  # the first branch that resolves. When provisioning, the created cluster's
  # endpoint/CA are "known after apply" (unknown at plan) — expected; Terraform
  # defers the k8s/helm resources to apply.
  cluster_endpoint = try(
    one(google_container_cluster.this[*]).endpoint,
    one(data.google_container_cluster.existing[*]).endpoint,
  )
  cluster_ca = try(
    one(google_container_cluster.this[*]).master_auth[0].cluster_ca_certificate,
    one(data.google_container_cluster.existing[*]).master_auth[0].cluster_ca_certificate,
  )
}

provider "kubernetes" {
  host                   = "https://${local.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(local.cluster_ca)
}

provider "helm" {
  kubernetes {
    host                   = "https://${local.cluster_endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(local.cluster_ca)
  }

  # Log helm in to the private chart registry with the pull token so an OCI chart
  # ref pulls without a manual `helm registry login`. Harmless when no token
  # (local-path chart / dev) — these creds are only exercised on an actual
  # oci://registry.marshal.codes chart pull, which a local chart path never does.
  #
  # Skipped when nothing is installed, exactly as single-node-k3s skips it on its
  # own provision path, and for the same reason: helm logs in when the provider is
  # CONFIGURED, not when a chart is pulled. A provision-only apply would
  # otherwise die at PLAN time on "unauthorized: invalid pull token" with no
  # chart in sight.
  #
  # The for_each shape matters. `bool ? [1] : []` is the form already proven on
  # the k3s flavor; CLAUDE.md records a real customer-deploy failure from a
  # different shape here, and validate cannot catch it because it never
  # evaluates for_each against concrete values.
  #
  # Known limitation, deliberately not fixed here: the url is pinned to the
  # production registry while the chart host is var.chart's. They agree for every
  # install today. An install_marshal = true run against a non-prod backbone
  # would hit the same login failure, and the fix is to derive this host from
  # var.chart — out of scope for this change.
  dynamic "registry" {
    for_each = var.install_marshal ? [1] : []
    content {
      url      = "oci://registry.marshal.codes"
      username = var.deployment_id
      password = var.registry_pull_token
    }
  }
}
