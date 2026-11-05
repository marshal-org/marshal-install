# ── Project APIs this flavor needs ───────────────────────────────────────────
# A fresh project has almost none of these on. Without this file the first
# apply on a new project failed on Secret Manager (create_registry_cache is on
# by default and writes the pull token to a secret), and the README never said
# to enable it by hand. Each API is listed only when something the current
# settings create actually calls it, so an install never gets an API it does
# not use. The one exception is the Cloud SQL pair below, which the README's
# documented database steps call.
#
# Never disabled on destroy: something else in the project may use the same
# API, and turning off compute or container under a running workload is not a
# side effect a Marshal teardown should have. An API that is already on is
# left as it is.
#
# containerfilesystem.googleapis.com (image streaming) stays in cluster.tf,
# where it was first added; moving it would move its state address.

variable "enable_project_apis" {
  description = "Enable the Google APIs this install calls (Compute Engine, Kubernetes Engine, Artifact Registry, Secret Manager, IAM, IAM Credentials, Cloud Storage, Certificate Manager), and, with database_mode = \"external\" on a VPC this install creates, the two the Cloud SQL steps in the README need (Cloud SQL Admin, Service Networking), each only when a setting that needs it is on. true (default) makes a fresh project work in one apply. Set false when your organization enables APIs centrally and the identity running Terraform has no serviceusage.services.enable permission; then enable them yourself first (see the README)."
  type        = bool
  default     = true
  nullable    = false
}

locals {
  project_apis = var.enable_project_apis ? toset(compact([
    local.provision || local.needs_static_ip ? "compute.googleapis.com" : "",
    local.provision ? "container.googleapis.com" : "",
    var.create_registry_cache ? "artifactregistry.googleapis.com" : "",
    var.create_registry_cache ? "secretmanager.googleapis.com" : "",
    local.create_any_storage_bucket || local.create_node_sa ? "iam.googleapis.com" : "",
    # Workload Identity's GSA impersonation (the bucket GSA) goes through the
    # IAM Credentials API. Enabling container.googleapis.com turns it on as a
    # dependency (observed on a fresh project), but a reused cluster's project
    # may not have it, and listing it costs nothing.
    local.create_any_storage_bucket ? "iamcredentials.googleapis.com" : "",
    local.create_any_storage_bucket ? "storage.googleapis.com" : "",
    local.create_managed_cert ? "certificatemanager.googleapis.com" : "",
    # External Postgres is Cloud SQL with a private IP, which the README has you
    # create with gcloud. Terraform never calls these two, but a fresh project
    # has neither on, and `gcloud sql instances create` fails on SERVICE_DISABLED
    # without them. Enabling them here means an install_marshal = false first
    # apply (the README's order for a new cluster) leaves the project ready for
    # those commands.
    # Only on a VPC this root creates: there the README's order needs them before
    # Cloud SQL exists. A reused cluster or network already has its database, so
    # its upgrade adds no new API resources.
    local.provision && var.create_network && var.database_mode == "external" ? "sqladmin.googleapis.com" : "",
    local.provision && var.create_network && var.database_mode == "external" ? "servicenetworking.googleapis.com" : "",
  ])) : toset([])
}

resource "google_project_service" "required" {
  for_each = local.project_apis

  project                    = var.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}
