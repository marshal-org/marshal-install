# max_parallel_image_pulls: applied to every pool the flavor creates; values
# outside GKE's 2-5 range are refused.

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
run "five_on_every_pool" {
  command = plan

  variables {
    max_parallel_image_pulls = 5
  }

  assert {
    condition     = alltrue([for p in google_container_node_pool.spaces : p.node_config[0].kubelet_config[0].max_parallel_image_pulls == 5])
    error_message = "every spaces pool must pull 5 images at once"
  }
  assert {
    condition     = google_container_node_pool.control_plane[0].node_config[0].kubelet_config[0].max_parallel_image_pulls == 5
    error_message = "the control-plane pool must pull 5 images at once"
  }
}

run "nine_is_refused" {
  command = plan

  variables {
    max_parallel_image_pulls = 9
  }

  expect_failures = [var.max_parallel_image_pulls]
}

run "one_is_refused" {
  command = plan

  variables {
    max_parallel_image_pulls = 1
  }

  expect_failures = [var.max_parallel_image_pulls]
}
