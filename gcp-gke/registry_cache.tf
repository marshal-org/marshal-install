# ── Pull-through Artifact Registry cache (default; required for a customer
#    install) ────────────────────────────────────────────────────────────────
# Mirrors registry.marshal.codes so nodes pull through your own project instead
# of hitting Marshal's registry rate limits directly. On by default — set to
# false only for a disposable, single-session smoke test, never for a real
# customer install (see the customer-facing GCP install guide at
# https://docs.marshal.codes/installing/gke).
#
# When enabled, wires itself straight into the install: `registry` and
# `registry_auth_mode` are set automatically (see locals in main.tf) — you do
# NOT also need to set var.registry / var.registry_auth_mode by hand.

variable "create_registry_cache" {
  description = "Create an Artifact Registry remote repository mirroring registry.marshal.codes, and point the install at it automatically (registry + registry_auth_mode=workloadIdentity). true (default) — required for a real customer install; set false only for a disposable smoke test."
  type        = bool
  default     = true
}

variable "registry_cache_repository_id" {
  description = "Name of the created Artifact Registry repository."
  type        = string
  default     = "marshal-cache"
}

resource "google_secret_manager_secret" "registry_pull_token" {
  count     = var.create_registry_cache ? 1 : 0
  project   = var.project_id
  secret_id = "marshal-registry-pull-token"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "registry_pull_token" {
  count       = var.create_registry_cache ? 1 : 0
  secret      = google_secret_manager_secret.registry_pull_token[0].id
  secret_data = var.registry_pull_token
}

# The Artifact Registry service agent needs to read the secret to authenticate
# to the upstream on your behalf.
data "google_project" "this" {
  count      = var.create_registry_cache ? 1 : 0
  project_id = var.project_id
}

resource "google_secret_manager_secret_iam_member" "ar_service_agent" {
  count     = var.create_registry_cache ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.registry_pull_token[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:service-${data.google_project.this[0].number}@gcp-sa-artifactregistry.iam.gserviceaccount.com"
}

resource "google_artifact_registry_repository" "cache" {
  count         = var.create_registry_cache ? 1 : 0
  project       = var.project_id
  location      = local.region
  repository_id = var.registry_cache_repository_id
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description = "Pull-through cache mirroring registry.marshal.codes"
    common_repository {
      uri = "https://registry.marshal.codes"
    }
    upstream_credentials {
      username_password_credentials {
        username                = var.deployment_id
        password_secret_version = google_secret_manager_secret_version.registry_pull_token[0].name
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.ar_service_agent]
}

# Nodes pull through the cache via their own identity (Workload Identity /
# default compute SA) — no in-cluster pull secret needed.
resource "google_artifact_registry_repository_iam_member" "node_reader" {
  count      = var.create_registry_cache ? 1 : 0
  project    = var.project_id
  location   = google_artifact_registry_repository.cache[0].location
  repository = google_artifact_registry_repository.cache[0].name
  role       = "roles/artifactregistry.reader"
  member     = var.node_service_account != "" ? "serviceAccount:${var.node_service_account}" : "serviceAccount:${data.google_project.this[0].number}-compute@developer.gserviceaccount.com"
}

locals {
  registry_cache_endpoint = var.create_registry_cache ? "${local.region}-docker.pkg.dev/${var.project_id}/${var.registry_cache_repository_id}/marshal" : null
  # Explicit, not derived by the chart's regex fallback — we know exactly what
  # we created, so there's no ambiguity the way there could be for a customer's
  # own arbitrary BYO mirror (see var.tools_registry).
  registry_cache_tools_endpoint = var.create_registry_cache ? "${local.region}-docker.pkg.dev/${var.project_id}/${var.registry_cache_repository_id}/marshal-tools" : null
}
