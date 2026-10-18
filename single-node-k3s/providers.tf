# The kubernetes + helm providers point at your k3s node via its kubeconfig. On
# the node the admin kubeconfig lives at /etc/rancher/k3s/k3s.yaml; copy it out
# (rewrite the server IP to the node's reachable address) and point kubeconfig_path
# at it. See README → "Get a kubeconfig". In the provision path (deploy_cluster=
# true) no k8s resources are created (install runs on a later apply), so these
# providers are unused that pass.

# Used only when deploy_cluster = true. Harmless (unconfigured) otherwise; project
# is empty on the reuse path where no google resource is created.
provider "google" {
  project = var.project_id != "" ? var.project_id : null
  zone    = var.zone != "" ? var.zone : null
}

provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig_path)
  config_context = var.kube_context != "" ? var.kube_context : null
}

provider "helm" {
  kubernetes {
    config_path    = pathexpand(var.kubeconfig_path)
    config_context = var.kube_context != "" ? var.kube_context : null
  }

  # Log helm in to the private chart registry with the SAME pull token, so an
  # `oci://registry.marshal.codes/...` chart pulls without a manual
  # `helm registry login`.
  #
  # Skipped on the provision path (deploy_cluster = true): helm logs in when the
  # provider is CONFIGURED, not when a chart is pulled, so a node-only apply with
  # placeholder credentials would otherwise fail on "invalid pull token".
  dynamic "registry" {
    for_each = var.deploy_cluster ? [] : [1]
    content {
      url      = "oci://registry.marshal.codes"
      username = var.deployment_id
      password = var.registry_pull_token
    }
  }
}
