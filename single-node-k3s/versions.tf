terraform {
  required_version = ">= 1.5"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27, < 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.14, < 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    # Used only when deploy_cluster = true (provisioning the GCE node).
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 7.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0, < 5.0"
    }
  }
}
