# The supervisor gets its own GSA with access to the spaces bucket only. Session
# pods run agent code and must not reach the audit bucket through the shared
# storage GSA.

mock_provider "google" {
  source = "./tests/mocks"
}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "tls" {}

# The shared mock gives every GSA the same email; give each its own so the
# asserts can tell the two apart. override_during = plan makes the emails known
# at plan time.
override_resource {
  target          = google_service_account.storage
  override_during = plan
  values = {
    name  = "projects/test-project/serviceAccounts/marshal-storage@test-project.iam.gserviceaccount.com"
    email = "marshal-storage@test-project.iam.gserviceaccount.com"
  }
}

override_resource {
  target          = google_service_account.supervisor_storage
  override_during = plan
  values = {
    name  = "projects/test-project/serviceAccounts/marshal-sup-storage@test-project.iam.gserviceaccount.com"
    email = "marshal-sup-storage@test-project.iam.gserviceaccount.com"
  }
}

variables {
  project_id                       = "test-project"
  installation_jwt                 = "mock"
  deployment_id                    = "mock"
  registry_pull_token              = "mock"
  chart_version                    = "0.32.0"
  location                         = "europe-west1"
  ingress_host                     = "marshal.example.com"
  deploy_cluster                   = true
  install_marshal                  = false
  database_mode                    = "bundled"
  redis_mode                       = "bundled"
  dns_endpoint_enabled             = true
  create_audit_persistence_bucket  = true
  create_spaces_persistence_bucket = true
}

run "supervisor_has_own_gsa" {
  command = plan

  assert {
    condition     = google_service_account.supervisor_storage[0].account_id == "marshal-sup-storage"
    error_message = "supervisor GSA account_id must be <cluster>-sup-storage"
  }
  assert {
    condition     = google_storage_bucket_iam_member.spaces_persistence_supervisor_object_admin[0].member == "serviceAccount:marshal-sup-storage@test-project.iam.gserviceaccount.com"
    error_message = "supervisor GSA must get the spaces-bucket grant"
  }
  assert {
    condition     = google_storage_bucket_iam_member.audit_persistence_object_admin[0].member == "serviceAccount:marshal-storage@test-project.iam.gserviceaccount.com"
    error_message = "the audit-bucket grant must stay on the shared storage GSA only"
  }
  assert {
    condition     = google_storage_bucket_iam_member.spaces_persistence_object_admin[0].member == "serviceAccount:marshal-storage@test-project.iam.gserviceaccount.com"
    error_message = "the api's storage GSA must keep its spaces-bucket grant"
  }
  assert {
    condition     = google_service_account_iam_member.storage_workload_identity_supervisor[0].service_account_id == google_service_account.supervisor_storage[0].name
    error_message = "the supervisor WI binding must sit on the supervisor GSA"
  }
  assert {
    condition     = google_service_account_iam_member.storage_workload_identity[0].service_account_id == google_service_account.storage[0].name
    error_message = "the api WI binding must stay on the storage GSA"
  }
  assert {
    condition     = yamldecode(output.argocd_derived_values).supervisor.serviceAccount.annotations["iam.gke.io/gcp-service-account"] == "marshal-sup-storage@test-project.iam.gserviceaccount.com"
    error_message = "supervisor KSA must be annotated with the supervisor GSA"
  }
  assert {
    condition     = yamldecode(output.argocd_derived_values).api.serviceAccount.annotations["iam.gke.io/gcp-service-account"] == "marshal-storage@test-project.iam.gserviceaccount.com"
    error_message = "api KSA must keep the storage GSA"
  }
  assert {
    condition     = output.supervisor_storage_service_account == "marshal-sup-storage@test-project.iam.gserviceaccount.com"
    error_message = "output must print the supervisor GSA email"
  }
}

run "long_cluster_name_fits_account_id_limit" {
  command = plan

  variables {
    cluster_name = "abcdefghijklmnopq-rst"
  }

  assert {
    condition     = google_service_account.supervisor_storage[0].account_id == "abcdefghijklmnopq-sup-storage"
    error_message = "account_id must cut the cluster name to 18 chars and drop a trailing dash"
  }
  assert {
    condition     = length(google_service_account.supervisor_storage[0].account_id) <= 30
    error_message = "account_id must be at most 30 chars"
  }
}

run "spaces_bucket_off_creates_no_supervisor_gsa" {
  command = plan

  variables {
    create_spaces_persistence_bucket = false
  }

  assert {
    condition     = length(google_service_account.supervisor_storage) == 0
    error_message = "no supervisor GSA without the spaces bucket"
  }
  assert {
    condition     = output.supervisor_storage_service_account == null
    error_message = "output must be null without the spaces bucket"
  }
}
