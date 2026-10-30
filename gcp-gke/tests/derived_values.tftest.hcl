# argocd_derived_values renders in both ingress modes. The output is evaluated
# on every plan, so a type error here breaks every install, not only ArgoCD.

mock_provider "google" {
  source = "./tests/mocks"
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "tls" {}

variables {
  project_id           = "test-project"
  installation_jwt     = "mock"
  deployment_id        = "mock"
  registry_pull_token  = "mock"
  chart_version        = "0.0.0"
  location             = "europe-west1"
  ingress_host         = "marshal.example.com"
  deploy_cluster       = true
  install_marshal      = false
  database_mode        = "bundled"
  redis_mode           = "bundled"
  dns_endpoint_enabled = true
}
run "ingress_mode_default" {
  command = plan

  assert {
    condition     = yamldecode(output.argocd_derived_values).ingress.className == "gce-internal"
    error_message = "default ingress class must be gce-internal"
  }
  assert {
    condition     = !contains(keys(yamldecode(output.argocd_derived_values).ingress), "gateway")
    error_message = "no gateway block outside gateway mode"
  }
}

run "ingress_mode_gateway" {
  command = plan

  variables {
    ingress_mode = "gateway"
  }

  assert {
    condition     = yamldecode(output.argocd_derived_values).ingress.mode == "gateway"
    error_message = "gateway mode must render ingress.mode = gateway"
  }
  assert {
    condition     = yamldecode(output.argocd_derived_values).ingress.gateway.className == "gke-l7-rilb"
    error_message = "gateway mode must render the GatewayClass"
  }
}
