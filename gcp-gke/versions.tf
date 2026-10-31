terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 7.0" # control_plane_endpoints_config (cluster.tf) is 6.x-only
    }
    # One resource only: google_project_service_identity (registry_cache.tf),
    # which the GA provider does not have. Kept on the same major as google.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0, < 7.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27, < 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.14, < 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0, < 5.0"
    }
  }
}
