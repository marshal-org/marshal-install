# Defaults: an install that sets none of the image-pull or Spot settings gets
# no new blocks, no new API, and no Spot pool, so it plans what it planned
# before these settings existed.

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

run "defaults_add_nothing" {
  command = plan

  assert {
    condition     = length(google_project_service.containerfilesystem) == 0
    error_message = "the Container File System API must not be enabled by default"
  }
  assert {
    condition     = alltrue([for p in google_container_node_pool.spaces : length(p.node_config[0].gcfs_config) == 0])
    error_message = "spaces pools must not carry gcfs_config by default"
  }
  assert {
    condition     = length(google_container_node_pool.control_plane[0].node_config[0].gcfs_config) == 0
    error_message = "the control-plane pool must not carry gcfs_config by default"
  }
  assert {
    condition     = alltrue([for p in google_container_node_pool.spaces : length(p.node_config[0].kubelet_config) == 0])
    error_message = "spaces pools must not carry kubelet_config by default"
  }
  assert {
    condition     = length(google_container_node_pool.control_plane[0].node_config[0].kubelet_config) == 0
    error_message = "the control-plane pool must not carry kubelet_config by default"
  }
  assert {
    condition     = alltrue([for p in google_container_node_pool.spaces : p.node_config[0].spot == false])
    error_message = "no spaces pool may be Spot by default"
  }
}
