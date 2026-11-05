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

variable "force_destroy_buckets" {
  description = "true = `terraform destroy` empties the audit and spaces buckets (every object and every version) before deleting them. false (default) = destroy stops on a bucket that holds anything, which a used install always does: deleting a space in Marshal does not empty its snapshot prefix. Set it to true and APPLY before a destroy, because destroy reads it from state rather than tfvars, and delete the spaces in Marshal first so a running one cannot write to the bucket again. Leave false for anything you intend to keep: the audit bucket is compliance data."
  type        = bool
  default     = false
  nullable    = false
}

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

  depends_on = [google_project_service.required]
}

# The supervisor gets its OWN GSA, with access to the spaces bucket only. Session
# pods run agent code, so the identity they carry must not reach the audit
# bucket (the shared storage GSA above has objectAdmin on both).
#
# account_id is 6-30 chars. The "-sup-storage" suffix is 12, so the cluster name
# is cut to 18 chars (and a trailing "-" from the cut dropped).
resource "google_service_account" "supervisor_storage" {
  count        = var.create_spaces_persistence_bucket ? 1 : 0
  project      = var.project_id
  account_id   = "${trimsuffix(substr(var.cluster_name, 0, 18), "-")}-sup-storage"
  display_name = "Marshal (${var.cluster_name}) supervisor spaces persistence bucket access"

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket" "audit_persistence" {
  count                       = var.create_audit_persistence_bucket ? 1 : 0
  project                     = var.project_id
  name                        = local.audit_persistence_bucket_name
  location                    = local.storage_buckets_location
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy_buckets

  versioning {
    enabled = true
  }

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket" "spaces_persistence" {
  count                       = var.create_spaces_persistence_bucket ? 1 : 0
  project                     = var.project_id
  name                        = local.spaces_persistence_bucket_name
  location                    = local.storage_buckets_location
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy_buckets

  depends_on = [google_project_service.required]
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

resource "google_storage_bucket_iam_member" "spaces_persistence_supervisor_object_admin" {
  count  = var.create_spaces_persistence_bucket ? 1 : 0
  bucket = google_storage_bucket.spaces_persistence[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.supervisor_storage[0].email}"
}

# Bind the GSA to the api's KSA (namespace/name the chart creates: see
# modules/marshal-install's release_name -> "<release_name>-api"). Workload
# Identity, not a downloaded key — no credential to leak or rotate.
#
# depends_on the cluster, which is what BRINGS THE POOL INTO EXISTENCE:
# <project>.svc.id.goog does not exist until the project's first
# Workload-Identity cluster is created, and without this the binding races it on
# a fresh project and fails with "Error 400: Identity Pool does not exist" — an
# error that reads like a typo in the member string. The cluster is count 0 in
# reuse mode, where depends_on is a harmless no-op and the pool already exists.
# (Hit for real on a from-scratch build, 2026-10-15. The README's two-phase
# -target apply happens to dodge it, which is why it has stayed hidden.)
resource "google_service_account_iam_member" "storage_workload_identity" {
  count              = local.create_any_storage_bucket ? 1 : 0
  service_account_id = google_service_account.storage[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.release_name}-api]"

  depends_on = [google_container_cluster.this]
}

# Bind the SUPERVISOR's own GSA (supervisor_storage, not the shared storage
# GSA) to the supervisor's KSA. Session pods run in a SEPARATE
# namespace ("<release_name>-spaces", the chart's spacesNamespace default) under
# "<release_name>-supervisor", and it's the supervisor — NOT the api — that does
# the spaces-persistence snapshot/restore blob I/O at session runtime. Without
# this, the supervisor has no cloud identity and every GCS call 403s (the api's
# space-storage connection test still passes, since it runs in the api pod, which
# masks the failure). Gated on the spaces bucket: the supervisor never uses audit.
#
# This binding used to sit on the shared storage GSA. Same address, new
# service_account_id: an existing install's plan REPLACES this one binding
# (old member removed from the storage GSA, added to supervisor_storage). The
# api binding above is untouched.
#
# setIamPolicy on a service account: when an org policy or missing rights block
# it (403 on apply), an admin with rights applies the binding by hand, see the
# README's object-storage section.
#
# depends_on the cluster, which is what BRINGS THE POOL INTO EXISTENCE:
# <project>.svc.id.goog does not exist until the project's first
# Workload-Identity cluster is created, and without this the binding races it on
# a fresh project and fails with "Error 400: Identity Pool does not exist" — an
# error that reads like a typo in the member string. The cluster is count 0 in
# reuse mode, where depends_on is a harmless no-op and the pool already exists.
# (Hit for real on a from-scratch build, 2026-10-15. The README's two-phase
# -target apply happens to dodge it, which is why it has stayed hidden.)
resource "google_service_account_iam_member" "storage_workload_identity_supervisor" {
  count              = var.create_spaces_persistence_bucket ? 1 : 0
  service_account_id = google_service_account.supervisor_storage[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.release_name}-spaces/${var.release_name}-supervisor]"

  depends_on = [google_container_cluster.this]
}

output "audit_persistence_bucket" {
  description = "gs:// URL for the audit-persistence bucket, once you're ready to wire it via the per-org audit API config."
  value       = var.create_audit_persistence_bucket ? "gs://${google_storage_bucket.audit_persistence[0].name}" : null
}

output "supervisor_storage_service_account" {
  description = "Email of the supervisor's own GSA (spaces bucket only), annotated on the <release>-supervisor KSA. null when the spaces bucket is off."
  value       = var.create_spaces_persistence_bucket ? google_service_account.supervisor_storage[0].email : null
}

output "spaces_persistence_bucket" {
  description = "gs:// URL for the spaces-persistence bucket — wire via PUT /api/org/space-storage (provider=gcs), then enable it with PATCH /api/org/space-storage/enabled."
  value       = var.create_spaces_persistence_bucket ? "gs://${google_storage_bucket.spaces_persistence[0].name}" : null
}
