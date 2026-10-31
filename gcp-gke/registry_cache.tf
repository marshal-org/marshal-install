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

  depends_on = [google_project_service.required]
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

# Enabling an API does not reliably create its service agent: GKE and AR create
# theirs lazily, on first use. On a fresh project the grant below then fails
# with "Service account service-<n>@gcp-sa-artifactregistry... does not exist",
# and a second apply only works once something else has created it. This asks
# for it explicitly (the Terraform form of
# `gcloud beta services identity create --service=artifactregistry.googleapis.com`).
# Only in the beta provider. Idempotent: an agent that already exists is
# returned as it is, and destroying this resource deletes nothing.
resource "google_project_service_identity" "artifactregistry" {
  provider = google-beta
  count    = var.create_registry_cache ? 1 : 0
  project  = var.project_id
  service  = "artifactregistry.googleapis.com"

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "ar_service_agent" {
  count     = var.create_registry_cache ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.registry_pull_token[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  # Built from the project number rather than read from the identity resource
  # above: it is the same address, and an attribute that is unknown until apply
  # would make every existing install plan to replace this binding.
  member = "serviceAccount:service-${data.google_project.this[0].number}@gcp-sa-artifactregistry.iam.gserviceaccount.com"

  depends_on = [google_project_service_identity.artifactregistry]
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

  depends_on = [google_secret_manager_secret_iam_member.ar_service_agent, google_project_service.required]
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

# ── Docker Hub cache for the bundled datastores ──────────────────────────────
# The chart's bundled Postgres and Redis are Bitnami subcharts whose images
# come from Docker Hub (docker.io/bitnamilegacy/*), not from
# registry.marshal.codes, so the cache above never sees them. Every node that
# starts one pulls anonymously from Docker Hub and shares its per-IP rate limit
# with everything else behind the same Cloud NAT address.
#
# A second remote repository, this one in front of Docker Hub, fixes that the
# same way: the bundled images pull through your project, and the subcharts'
# image.registry is pointed at it (main.tf). Anonymous upstream: these are
# public images, so there is no credential to store.
#
# Only when the cache is on AND something is bundled. An install with external
# Postgres and external Redis gets nothing new.

variable "cache_bundled_datastore_images" {
  description = "When create_registry_cache = true and Postgres or Redis is bundled, also create an Artifact Registry remote repository in front of Docker Hub and pull the bundled Bitnami Postgres/Redis images through it instead of from docker.io. true (default). On an existing install, turning this on (it is the default) restarts the bundled Redis/Postgres pods once, because their image reference changes; the image itself is the same."
  type        = bool
  default     = true
  nullable    = false
}

variable "dockerhub_cache_repository_id" {
  description = "Name of the Artifact Registry repository that caches Docker Hub for the bundled datastores."
  type        = string
  default     = "marshal-dockerhub-cache"
}

locals {
  bundled_datastores = var.database_mode == "bundled" || var.redis_mode == "bundled"
  cache_dockerhub    = var.create_registry_cache && var.cache_bundled_datastore_images && local.bundled_datastores

  # image.registry for the Bitnami subcharts: "<registry>/<repository>:<tag>",
  # so the repository (bitnamilegacy/redis) keeps mapping to the same Docker
  # Hub path through the cache.
  dockerhub_cache_endpoint = local.cache_dockerhub ? "${local.region}-docker.pkg.dev/${var.project_id}/${var.dockerhub_cache_repository_id}" : null

  # Chart values that point each bundled subchart at the cache. Only the
  # engines that are bundled get a key: a postgresql block on an install with
  # external Postgres is harmless, but it is noise in every rendered diff.
  bundled_image_values = local.cache_dockerhub ? merge(
    var.database_mode == "bundled" ? { postgresql = { image = { registry = local.dockerhub_cache_endpoint } } } : {},
    var.redis_mode == "bundled" ? { redis = { image = { registry = local.dockerhub_cache_endpoint } } } : {},
  ) : {}
}

resource "google_artifact_registry_repository" "dockerhub_cache" {
  count         = local.cache_dockerhub ? 1 : 0
  project       = var.project_id
  location      = local.region
  repository_id = var.dockerhub_cache_repository_id
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description = "Pull-through cache of Docker Hub for the bundled Postgres/Redis images"
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_artifact_registry_repository_iam_member" "dockerhub_node_reader" {
  count      = local.cache_dockerhub ? 1 : 0
  project    = var.project_id
  location   = google_artifact_registry_repository.dockerhub_cache[0].location
  repository = google_artifact_registry_repository.dockerhub_cache[0].name
  role       = "roles/artifactregistry.reader"
  member     = var.node_service_account != "" ? "serviceAccount:${var.node_service_account}" : "serviceAccount:${data.google_project.this[0].number}-compute@developer.gserviceaccount.com"
}
