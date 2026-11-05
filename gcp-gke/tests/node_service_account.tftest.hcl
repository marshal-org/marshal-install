# Node service account: new installs get a dedicated SA; existing pools
# pinned to "default" keep the Compute default (service_account = null, which
# is what every pool had before), so upgrading replaces no pool.
#
# The null cases assert on the resolved locals: the provider's
# node_config.service_account is Optional+Computed, so a null config value
# reads as unknown in a plan.

mock_provider "google" {
  source = "./tests/mocks"
}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "tls" {}

override_resource {
  target          = google_service_account.nodes
  override_during = plan
  values = {
    name  = "projects/test-project/serviceAccounts/marshal-nodes@test-project.iam.gserviceaccount.com"
    email = "marshal-nodes@test-project.iam.gserviceaccount.com"
  }
}

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

run "new_install_uses_dedicated_sa" {
  command = plan

  assert {
    condition     = google_service_account.nodes[0].account_id == "marshal-nodes"
    error_message = "the dedicated node SA must be <cluster_name>-nodes"
  }
  assert {
    condition     = google_container_node_pool.spaces["spaces"].node_config[0].service_account == "marshal-nodes@test-project.iam.gserviceaccount.com"
    error_message = "space pools must run as the dedicated SA by default"
  }
  assert {
    condition     = google_container_node_pool.control_plane[0].node_config[0].service_account == "marshal-nodes@test-project.iam.gserviceaccount.com"
    error_message = "the control-plane pool must run as the dedicated SA by default"
  }
  assert {
    condition     = google_project_iam_member.nodes_default_node_sa[0].role == "roles/container.defaultNodeServiceAccount"
    error_message = "the dedicated SA needs the default node SA role"
  }
  assert {
    condition     = length(google_project_iam_member.nodes_service_usage) == 0
    error_message = "serviceUsageConsumer only with image streaming"
  }
  assert {
    condition     = google_artifact_registry_repository_iam_member.node_reader_dedicated[0].member == "serviceAccount:marshal-nodes@test-project.iam.gserviceaccount.com"
    error_message = "the dedicated SA must read the registry cache"
  }
  assert {
    condition     = length(google_artifact_registry_repository_iam_member.node_reader) == 0
    error_message = "no pool runs as the Compute default, so it must get no cache grant"
  }
}

run "long_cluster_name_fits_account_id" {
  command = plan

  variables {
    cluster_name = "a-very-long-cluster-name-x-y"
  }

  assert {
    condition     = length(google_service_account.nodes[0].account_id) <= 30
    error_message = "account_id must fit 30 characters"
  }
  assert {
    condition     = google_service_account.nodes[0].account_id == "a-very-long-cluster-name-nodes"
    error_message = "account_id must be the cut cluster name plus -nodes"
  }
}

# The upgrade path: every existing pool pinned to "default", plus one new pool.
run "existing_pools_pinned_to_default" {
  command = plan

  variables {
    spaces_pools = {
      spaces      = { machine_type = "e2-standard-8", disk_size_gb = 200, service_account = "default", pool_name = "marshal-pool" }
      spaces16    = { machine_type = "e2-standard-16", disk_size_gb = 300, service_account = "default" }
      spaces16-sa = { machine_type = "e2-standard-16", disk_size_gb = 300, workload = "spaces16" }
    }
    control_plane_service_account = "default"
  }

  assert {
    condition     = local.spaces_pool_sa["spaces"] == null
    error_message = "a pinned pool must keep service_account = null (the Compute default), as before"
  }
  assert {
    condition     = local.spaces_pool_sa["spaces16"] == null
    error_message = "a pinned pool must keep service_account = null"
  }
  assert {
    condition     = local.control_plane_sa == null
    error_message = "the pinned control-plane pool must keep service_account = null"
  }
  assert {
    condition     = google_container_node_pool.spaces["spaces16-sa"].node_config[0].service_account == "marshal-nodes@test-project.iam.gserviceaccount.com"
    error_message = "the new pool must run as the dedicated SA"
  }
  assert {
    condition     = google_container_node_pool.spaces["spaces16-sa"].node_config[0].labels["workload"] == "spaces16"
    error_message = "workload overrides the node label"
  }
  assert {
    condition     = google_container_node_pool.spaces["spaces16-sa"].name == "marshal-spaces16-sa-pool"
    error_message = "the new pool keeps the key-based name"
  }
  assert {
    condition     = google_container_node_pool.spaces["spaces16"].node_config[0].labels["workload"] == "spaces16"
    error_message = "without workload the label stays the key"
  }
  assert {
    condition     = google_artifact_registry_repository_iam_member.node_reader[0].member == "serviceAccount:123456789012-compute@developer.gserviceaccount.com"
    error_message = "the Compute default keeps its cache grant while a pool still uses it"
  }
}

# Opting out: exactly the old behavior, nothing new created.
run "opt_out_is_the_old_behavior" {
  command = plan

  variables {
    create_node_service_account = false
  }

  assert {
    condition     = length(google_service_account.nodes) == 0 && length(google_project_iam_member.nodes_default_node_sa) == 0 && length(google_artifact_registry_repository_iam_member.node_reader_dedicated) == 0
    error_message = "opting out must create no SA and no grants"
  }
  assert {
    condition     = local.spaces_pool_sa["spaces"] == null && local.control_plane_sa == null
    error_message = "opting out must keep service_account = null on every pool"
  }
  assert {
    condition     = google_artifact_registry_repository_iam_member.node_reader[0].member == "serviceAccount:123456789012-compute@developer.gserviceaccount.com"
    error_message = "opting out keeps the Compute default's cache grant"
  }
}

# An explicit node_service_account still wins over the dedicated SA.
run "explicit_sa_wins" {
  command = plan

  variables {
    node_service_account = "custom@test-project.iam.gserviceaccount.com"
  }

  assert {
    condition     = length(google_service_account.nodes) == 0
    error_message = "an explicit SA must not create the dedicated one"
  }
  assert {
    condition     = google_container_node_pool.spaces["spaces"].node_config[0].service_account == "custom@test-project.iam.gserviceaccount.com" && google_container_node_pool.control_plane[0].node_config[0].service_account == "custom@test-project.iam.gserviceaccount.com"
    error_message = "every pool must run as the explicit SA"
  }
  assert {
    condition     = google_artifact_registry_repository_iam_member.node_reader[0].member == "serviceAccount:custom@test-project.iam.gserviceaccount.com"
    error_message = "the explicit SA keeps its cache grant, as before"
  }
}

run "image_streaming_grants_service_usage" {
  command = plan

  variables {
    image_streaming_enabled = true
  }

  assert {
    condition     = google_project_iam_member.nodes_service_usage[0].role == "roles/serviceusage.serviceUsageConsumer"
    error_message = "image streaming needs serviceUsageConsumer on the dedicated SA"
  }
}

run "bad_override_is_rejected" {
  command = plan

  variables {
    control_plane_service_account = "not-an-email"
  }

  expect_failures = [var.control_plane_service_account]
}
