# image_streaming_enabled = true: every pool the flavor creates streams images,
# and the Container File System API is enabled and never disabled on destroy.

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
run "streaming_on_every_pool" {
  command = plan

  variables {
    image_streaming_enabled = true
    spaces_pools = {
      spaces = { machine_type = "e2-standard-4", disk_size_gb = 100 }
      big    = { machine_type = "e2-standard-8", disk_size_gb = 200 }
    }
  }

  assert {
    condition     = alltrue([for p in google_container_node_pool.spaces : p.node_config[0].gcfs_config[0].enabled])
    error_message = "every spaces pool must have image streaming enabled"
  }
  assert {
    condition     = length(google_container_node_pool.spaces) == 2
    error_message = "both spaces pools must be planned"
  }
  assert {
    condition     = google_container_node_pool.control_plane[0].node_config[0].gcfs_config[0].enabled
    error_message = "the control-plane pool must have image streaming enabled"
  }
  assert {
    condition     = google_project_service.containerfilesystem[0].service == "containerfilesystem.googleapis.com"
    error_message = "the Container File System API must be enabled"
  }
  assert {
    condition     = google_project_service.containerfilesystem[0].disable_on_destroy == false
    error_message = "the Container File System API must never be disabled by this flavor"
  }
}

run "streaming_needs_a_provisioned_cluster" {
  command = plan

  variables {
    image_streaming_enabled = true
    deploy_cluster          = false
    subnetwork              = "existing-subnet"
  }

  assert {
    condition     = length(google_project_service.containerfilesystem) == 0
    error_message = "no API is enabled when the flavor does not provision the cluster"
  }
}
