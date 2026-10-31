# next_steps on the install path: what a first install needs to be told
# (DNS-endpoint credentials, the storage and load-balancer warnings, the
# no-DNS access pointer). Applied against mocks, because the module's
# next_steps reads the helm release, which a plan does not know yet.

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
  chart_version        = "0.0.0"
  location             = "europe-west1"
  ingress_host         = "marshal.example.com"
  deploy_cluster       = true
  install_marshal      = true
  database_mode        = "bundled"
  redis_mode           = "bundled"
  dns_endpoint_enabled = true
}

run "first_install_is_warned" {
  command = apply

  assert {
    condition     = strcontains(output.next_steps, "get-credentials marshal --location europe-west1 --project test-project --dns-endpoint")
    error_message = "next_steps must fetch credentials over the DNS endpoint when it is on"
  }
  assert {
    condition     = strcontains(output.next_steps, "5-8 minutes")
    error_message = "next_steps must warn that the load balancer is not ready yet"
  }
  assert {
    condition     = strcontains(output.next_steps, "Space storage is OFF")
    error_message = "next_steps must warn when the spaces bucket is off"
  }
  assert {
    condition     = strcontains(output.next_steps, "Reaching Marshal before")
    error_message = "next_steps must point at the no-DNS access path"
  }
}

run "spaces_bucket_on_no_warning" {
  command = apply

  variables {
    create_spaces_persistence_bucket = true
  }

  assert {
    condition     = !strcontains(output.next_steps, "Space storage is OFF")
    error_message = "no storage warning once the spaces bucket is on"
  }
}
