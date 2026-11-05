# ── Node service account (create_node_service_account = true) ────────────────
# Nodes ran as the project's default Compute Engine SA, which usually holds
# roles/editor: a container escape on a node then reaches the whole project.
# This SA can write logs and metrics, read the node metadata GKE needs, and
# pull from the registry cache. Nothing else. Pods never see it: they get
# Workload Identity (GKE_METADATA on every pool).
#
# A pool's SA is immutable in GKE, so the per-pool overrides
# (spaces_pools[*].service_account, control_plane_service_account) let an
# existing install keep its pools on the Compute default ("default") and add
# new pools on this SA, instead of replacing every pool in one apply.

locals {
  create_node_sa = local.provision && var.node_service_account == "" && var.create_node_service_account

  # The module-wide node SA. null = the Compute default (GKE's own default).
  module_node_sa = var.node_service_account != "" ? var.node_service_account : (
    local.create_node_sa ? google_service_account.nodes[0].email : null
  )

  # Per-pool resolution: null = module-wide, "default" = Compute default
  # (null), anything else = that email.
  spaces_pool_sa = {
    for k, p in var.spaces_pools : k => (
      p.service_account == null ? local.module_node_sa : (p.service_account == "default" ? null : p.service_account)
    )
  }
  control_plane_sa = var.control_plane_service_account == null ? local.module_node_sa : (
    var.control_plane_service_account == "default" ? null : var.control_plane_service_account
  )

  # Whether any pool runs as the Compute default SA. Worked out from the
  # variables only (never from the SA email, which is unknown until apply), so
  # it can drive a count. Keeps the default SA's read grant on the registry
  # cache (registry_cache.tf) while a pool still needs it.
  module_uses_compute_default = var.node_service_account == "" && !var.create_node_service_account
  compute_default_sa_in_use = local.provision && anytrue(concat(
    [for p in values(var.spaces_pools) : p.service_account == "default" || (p.service_account == null && local.module_uses_compute_default)],
    [var.control_plane_service_account == "default" || (var.control_plane_service_account == null && local.module_uses_compute_default)],
  ))
}

resource "google_service_account" "nodes" {
  count        = local.create_node_sa ? 1 : 0
  project      = var.project_id
  account_id   = "${trimsuffix(substr(var.cluster_name, 0, 24), "-")}-nodes"
  display_name = "Marshal (${var.cluster_name}) GKE nodes"

  depends_on = [google_project_service.required]
}

# Logs, metrics, node metadata: the role Google made for exactly this.
resource "google_project_iam_member" "nodes_default_node_sa" {
  count   = local.create_node_sa ? 1 : 0
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.nodes[0].email}"
}

# Image streaming calls the Container File System API as the node SA.
resource "google_project_iam_member" "nodes_service_usage" {
  count   = local.create_node_sa && var.image_streaming_enabled ? 1 : 0
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageConsumer"
  member  = "serviceAccount:${google_service_account.nodes[0].email}"
}
