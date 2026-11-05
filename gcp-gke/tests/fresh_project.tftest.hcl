# A fresh project: a 0.28.0 install rehearsal needed two failed
# applies before the third one worked, and came up with an empty control-plane
# pool. These pin the fixes.

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

run "apis_enabled_for_what_is_created" {
  command = plan

  assert {
    condition = alltrue([for api in [
      "compute.googleapis.com",
      "container.googleapis.com",
      "artifactregistry.googleapis.com",
      "secretmanager.googleapis.com",
    ] : contains(keys(google_project_service.required), api)])
    error_message = "a provisioned cluster with the registry cache needs compute, container, artifactregistry and secretmanager enabled"
  }
  assert {
    condition     = alltrue([for s in google_project_service.required : s.disable_on_destroy == false])
    error_message = "the flavor must never disable an API on destroy"
  }
  assert {
    condition     = !contains(keys(google_project_service.required), "certificatemanager.googleapis.com")
    error_message = "Certificate Manager only when a managed certificate is requested"
  }
  assert {
    condition     = length(google_project_service_identity.artifactregistry) == 1
    error_message = "the Artifact Registry service agent must be created before it is granted the secret"
  }
}

run "apis_opt_out" {
  command = plan

  variables {
    enable_project_apis = false
  }

  assert {
    condition     = length(google_project_service.required) == 0
    error_message = "enable_project_apis = false must enable nothing"
  }
}

run "no_cache_no_secret_manager" {
  command = plan

  variables {
    create_registry_cache = false
  }

  assert {
    condition     = !contains(keys(google_project_service.required), "secretmanager.googleapis.com")
    error_message = "Secret Manager is only needed by the registry cache"
  }
  assert {
    condition     = length(google_project_service_identity.artifactregistry) == 0
    error_message = "no service agent without the cache"
  }
}

run "pools_start_with_nodes" {
  command = plan

  assert {
    condition     = google_container_node_pool.control_plane[0].initial_node_count == 1
    error_message = "the autoscaled control-plane pool must start with at least one node"
  }
  assert {
    condition     = google_container_node_pool.spaces["spaces"].initial_node_count == 1
    error_message = "the default spaces pool must start at its min_node_count"
  }
}

# A fixed-size pool is sized by node_count alone (initial_node_count stays
# unset, which plans as unknown, so it is not asserted); a min-0 autoscaled
# pool starts empty.
run "min_zero_pool_starts_empty" {
  command = plan

  variables {
    control_plane_node_count = 2
    spaces_pools = {
      spaces = { machine_type = "e2-standard-4", disk_size_gb = 100, node_count = 3 }
      big    = { machine_type = "e2-standard-16", disk_size_gb = 200, min_node_count = 0, max_node_count = 4 }
    }
  }

  assert {
    condition     = google_container_node_pool.spaces["big"].initial_node_count == 0
    error_message = "a min-0 pool starts empty"
  }
}

run "taint_schedules_bundled_redis_on_the_control_plane" {
  command = plan

  variables {
    taint_control_plane_pool = true
  }

  assert {
    condition     = yamldecode(output.argocd_derived_values).redis.master.nodeSelector.workload == "control-plane"
    error_message = "the taint must schedule bundled Redis on the control-plane pool"
  }
}

# An upgrade with bundled datastores keeps them next to their zone-bound volume:
# the platform moves to the tainted pool, Redis does not.
run "unpinned_datastores_stay_put" {
  command = plan

  variables {
    taint_control_plane_pool = true
    pin_bundled_datastores   = false
  }

  assert {
    condition     = !can(yamldecode(output.argocd_derived_values).redis) && yamldecode(output.argocd_derived_values).controlPlane.nodeSelector.workload == "control-plane"
    error_message = "pin_bundled_datastores = false must leave Redis unpinned while the platform still moves"
  }
}

run "external_datastores_have_no_redis_values" {
  command = plan

  variables {
    database_mode = "external"
    database_url  = "postgres://u:p@10.0.0.5:5432/marshal"
    redis_mode    = "external"
    redis_url     = "redis://10.0.0.6:6379"
  }

  assert {
    condition     = !contains(keys(yamldecode(output.argocd_derived_values)), "redis")
    error_message = "no redis values when Redis is external"
  }
}

run "kubeconfig_uses_the_dns_endpoint" {
  command = plan

  assert {
    condition     = endswith(output.kubeconfig_command, " --dns-endpoint")
    error_message = "with dns_endpoint_enabled the kubeconfig command must pass --dns-endpoint"
  }
}

run "kubeconfig_without_the_dns_endpoint" {
  command = plan

  variables {
    dns_endpoint_enabled       = false
    master_authorized_networks = [{ cidr_block = "10.8.0.0/24", display_name = "admin" }]
  }

  assert {
    condition     = !strcontains(output.kubeconfig_command, "--dns-endpoint")
    error_message = "without the DNS endpoint the kubeconfig command must not pass --dns-endpoint"
  }
}

# The first of the two applies for Cloud SQL on a new VPC installs nothing, so it
# is not blocked by the missing database_url.
run "provision_only_skips_database_url" {
  command = plan

  variables {
    database_mode = "external"
    database_url  = ""
  }

  assert {
    condition     = contains(keys(google_project_service.required), "sqladmin.googleapis.com") && contains(keys(google_project_service.required), "servicenetworking.googleapis.com")
    error_message = "external Postgres must enable the Cloud SQL APIs the README's steps need"
  }
}
