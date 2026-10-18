# ── Object storage buckets (optional) ────────────────────────────────────────
# Two INDEPENDENT buckets the api can use, per apps/api/internal/audit/cloud.go
# (audit persistence — WAL-flushed compliance export) and .../spacestorage
# (spaces persistence — session pause/resume snapshots) — both consume storage
# via gocloud.dev/blob (gs://, s3://, azblob://) with ambient auth, so on GKE
# that's Workload Identity, mirroring how registry_auth_mode=workloadIdentity
# already works for image pulls.
#
# Off by default, toggled separately — you may want one feature without the
# other. Creating a bucket doesn't itself turn the feature on; an org admin
# still wires the actual bucket URL via the API afterward (audit: per-org
# config; spaces: PUT /api/org/space-storage — see the chart's NOTES.txt).
# This just provisions the storage + access so that Day-2 step has somewhere
# to point at.

variable "create_audit_persistence_bucket" {
  description = "Create the audit-persistence GCS bucket (compliance export) + bind it to the api's KSA via Workload Identity (roles/storage.objectAdmin). false (default) creates nothing — bring your own bucket/credentials instead."
  type        = bool
  default     = false
}

variable "create_spaces_persistence_bucket" {
  description = "Create the spaces-persistence GCS bucket (session pause/resume snapshots) + bind it to the api's KSA via Workload Identity (roles/storage.objectAdmin). false (default) creates nothing — bring your own bucket/credentials instead."
  type        = bool
  default     = false
}

variable "storage_buckets_location" {
  description = "GCS location for the buckets. \"\" (default) uses `location`'s region (see cluster.tf's region derivation) — a multi-region value like \"EU\"/\"US\" also works if you want that instead."
  type        = string
  default     = ""
}

locals {
  create_any_storage_bucket = var.create_audit_persistence_bucket || var.create_spaces_persistence_bucket
  storage_buckets_location  = var.storage_buckets_location != "" ? var.storage_buckets_location : local.region

  # GCS bucket names are globally unique across ALL of GCP — project_id +
  # cluster_name keeps collisions extremely unlikely without an operator
  # having to pick names themselves.
  audit_persistence_bucket_name  = "${var.project_id}-${var.cluster_name}-audit-persistence"
  spaces_persistence_bucket_name = "${var.project_id}-${var.cluster_name}-spaces-persistence"
}

# One shared GSA for both buckets — created if either is enabled. IAM grants
# below are still independent per-bucket.
resource "google_service_account" "storage" {
  count        = local.create_any_storage_bucket ? 1 : 0
  project      = var.project_id
  account_id   = "${var.cluster_name}-storage"
  display_name = "Marshal (${var.cluster_name}) — audit/spaces persistence bucket access"
}

resource "google_storage_bucket" "audit_persistence" {
  count                       = var.create_audit_persistence_bucket ? 1 : 0
  project                     = var.project_id
  name                        = local.audit_persistence_bucket_name
  location                    = local.storage_buckets_location
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }
}

resource "google_storage_bucket" "spaces_persistence" {
  count                       = var.create_spaces_persistence_bucket ? 1 : 0
  project                     = var.project_id
  name                        = local.spaces_persistence_bucket_name
  location                    = local.storage_buckets_location
  uniform_bucket_level_access = true
  force_destroy               = false
}

resource "google_storage_bucket_iam_member" "audit_persistence_object_admin" {
  count  = var.create_audit_persistence_bucket ? 1 : 0
  bucket = google_storage_bucket.audit_persistence[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.storage[0].email}"
}

resource "google_storage_bucket_iam_member" "spaces_persistence_object_admin" {
  count  = var.create_spaces_persistence_bucket ? 1 : 0
  bucket = google_storage_bucket.spaces_persistence[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.storage[0].email}"
}

# Bind the GSA to the api's KSA (namespace/name the chart creates: see
# modules/marshal-install's release_name -> "<release_name>-api"). Workload
# Identity, not a downloaded key — no credential to leak or rotate.
resource "google_service_account_iam_member" "storage_workload_identity" {
  count              = local.create_any_storage_bucket ? 1 : 0
  service_account_id = google_service_account.storage[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.release_name}-api]"
}

# Also bind the GSA to the SUPERVISOR's KSA. Session pods run in a SEPARATE
# namespace ("<release_name>-spaces", the chart's spacesNamespace default) under
# "<release_name>-supervisor", and it's the supervisor — NOT the api — that does
# the spaces-persistence snapshot/restore blob I/O at session runtime. Without
# this, the supervisor has no cloud identity and every GCS call 403s (the api's
# space-storage connection test still passes, since it runs in the api pod, which
# masks the failure). Gated on the spaces bucket: the supervisor never uses audit.
resource "google_service_account_iam_member" "storage_workload_identity_supervisor" {
  count              = var.create_spaces_persistence_bucket ? 1 : 0
  service_account_id = google_service_account.storage[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.release_name}-spaces/${var.release_name}-supervisor]"
}

output "audit_persistence_bucket" {
  description = "gs:// URL for the audit-persistence bucket, once you're ready to wire it via the per-org audit API config."
  value       = var.create_audit_persistence_bucket ? "gs://${google_storage_bucket.audit_persistence[0].name}" : null
}

output "spaces_persistence_bucket" {
  description = "gs:// URL for the spaces-persistence bucket — wire via PUT /api/org/space-storage (provider=gcs)."
  value       = var.create_spaces_persistence_bucket ? "gs://${google_storage_bucket.spaces_persistence[0].name}" : null
}
