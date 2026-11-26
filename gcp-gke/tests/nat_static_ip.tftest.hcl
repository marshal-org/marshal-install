# nat_static_ip: off by default (auto-allocated NAT IPs); on reserves one
# regional external address and pins Cloud NAT to it.

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

run "default_is_auto_allocated" {
  command = plan

  assert {
    condition     = google_compute_router_nat.nat[0].nat_ip_allocate_option == "AUTO_ONLY" && length(google_compute_address.nat) == 0
    error_message = "default must keep AUTO_ONLY and reserve no address"
  }
}

run "static_pins_nat_to_reserved_ip" {
  command = plan

  variables {
    nat_static_ip = true
  }

  assert {
    condition     = google_compute_router_nat.nat[0].nat_ip_allocate_option == "MANUAL_ONLY" && length(google_compute_address.nat) == 1
    error_message = "nat_static_ip must reserve one address and switch NAT to MANUAL_ONLY"
  }
  assert {
    condition     = google_compute_address.nat[0].address_type == "EXTERNAL"
    error_message = "the NAT address must be EXTERNAL"
  }
}
