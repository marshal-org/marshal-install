terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
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
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    harbor = {
      source  = "goharbor/harbor"
      version = ">= 3.12, < 4.0"
    }
  }
}
