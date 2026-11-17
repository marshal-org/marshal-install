# http_mode: what plain HTTP does (chart ingress.http). The default sends the
# chart nothing new; redirect on the default internal Ingress fails the plan,
# because a GKE internal Ingress cannot redirect.

mock_provider "google" {
  source = "./tests/mocks"
}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "tls" {}

variables {
  project_id           = "test-project"
  installation_jwt     = "mock"
  deployment_id        = "mock"
  registry_pull_token  = "mock"
  chart_version        = "0.32.0"
  location             = "europe-west1"
  ingress_host         = "marshal.example.com"
  deploy_cluster       = true
  install_marshal      = false
  database_mode        = "bundled"
  redis_mode           = "bundled"
  dns_endpoint_enabled = true
}

run "default_sends_nothing" {
  command = plan

  assert {
    condition     = !contains(keys(yamldecode(output.argocd_derived_values).ingress), "http")
    error_message = "http_mode = serve (default) must not add ingress.http"
  }
}

run "off_on_internal_ingress" {
  command = plan

  variables {
    http_mode = "off"
  }

  assert {
    condition     = yamldecode(output.argocd_derived_values).ingress.http == "off"
    error_message = "http_mode = off must render ingress.http = off"
  }
}

run "redirect_on_internal_ingress_fails" {
  command = plan

  variables {
    http_mode = "redirect"
  }

  expect_failures = [output.argocd_derived_values]
}

run "redirect_in_gateway_mode" {
  command = plan

  variables {
    http_mode    = "redirect"
    ingress_mode = "gateway"
  }

  assert {
    condition     = yamldecode(output.argocd_derived_values).ingress.http == "redirect"
    error_message = "gateway mode must render ingress.http = redirect"
  }
}

run "unknown_value_fails" {
  command = plan

  variables {
    http_mode = "on"
  }

  expect_failures = [var.http_mode]
}
