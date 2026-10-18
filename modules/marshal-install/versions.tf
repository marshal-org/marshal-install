# Provider requirements for the shared install module.
#
# NOTE: this module deliberately declares NO provider "kubernetes" / provider
# "helm" blocks. The calling flavor (single-node-k3s, gcp-gke, …) configures
# those providers pointed at the target cluster and passes them down. That keeps
# all cluster-connection logic in one place per flavor and lets this module stay
# cloud-agnostic.

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
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0, < 5.0"
    }
  }
}
