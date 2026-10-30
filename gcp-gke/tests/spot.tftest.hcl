# spot on one spaces pool: only that pool is Spot; other pools and the
# control-plane pool are not.

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
run "spot_on_one_pool" {
  command = plan

  variables {
    spaces_pools = {
      spaces = { machine_type = "e2-standard-4", disk_size_gb = 100, spot = true }
      big    = { machine_type = "e2-standard-8", disk_size_gb = 200 }
    }
  }

  assert {
    condition     = google_container_node_pool.spaces["spaces"].node_config[0].spot == true
    error_message = "the pool marked spot must be Spot"
  }
  assert {
    condition     = google_container_node_pool.spaces["big"].node_config[0].spot == false
    error_message = "a pool not marked spot must not be Spot"
  }
  assert {
    condition     = google_container_node_pool.control_plane[0].node_config[0].spot != true
    error_message = "the control-plane pool must never be Spot"
  }
}
