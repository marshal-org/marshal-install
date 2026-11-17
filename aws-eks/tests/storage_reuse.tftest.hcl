# A bucket toggle on a reused cluster (deploy_cluster = false) must stop with
# the guidance message, not an "Invalid index" on aws_iam_role.storage[0].

mock_provider "aws" {
  mock_data "aws_eks_cluster" {
    defaults = {
      endpoint              = "https://mock.eks.example.com"
      certificate_authority = [{ data = "bW9jaw==" }]
    }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "tls" {}
mock_provider "random" {}
mock_provider "harbor" {}

variables {
  cluster_name        = "test"
  region              = "eu-west-1"
  installation_jwt    = "mock"
  deployment_id       = "mock"
  registry_pull_token = "mock"
  chart_version       = "0.32.0"
  ingress_host        = "marshal.example.com"
  install_marshal     = false
  database_url        = "postgres://u:p@db.example.com:5432/marshal"
}

run "reuse_audit_bucket_is_rejected" {
  command = plan
  variables {
    deploy_cluster                  = false
    create_audit_persistence_bucket = true
  }
  expect_failures = [output._storage_buckets_require_provisioning]
}

run "reuse_spaces_bucket_is_rejected" {
  command = plan
  variables {
    deploy_cluster                   = false
    create_spaces_persistence_bucket = true
  }
  expect_failures = [output._storage_buckets_require_provisioning]
}

run "reuse_without_toggles_plans" {
  command = plan
  variables {
    deploy_cluster = false
  }
}
