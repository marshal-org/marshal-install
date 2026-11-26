# The supervisor runs in session pods, next to agent code. With both buckets
# on it must get its own IRSA role that reaches the spaces bucket only; the
# api's shared role (both buckets) must not trust the supervisor's KSA.

mock_provider "aws" {
  mock_data "aws_eks_cluster" {
    defaults = {
      endpoint              = "https://mock.eks.example.com"
      certificate_authority = [{ data = "bW9jaw==" }]
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock"
    }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/MOCK"
      url = "https://oidc.eks.eu-west-1.amazonaws.com/id/MOCK"
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
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

run "supervisor_role_reaches_spaces_bucket_only" {
  # The overrides give the buckets distinct, known ARNs at plan time, so the
  # policy statements below can be checked against them.
  command = plan
  override_resource {
    target          = aws_s3_bucket.spaces_persistence
    values          = { arn = "arn:aws:s3:::test-spaces-persistence-123456789012" }
    override_during = plan
  }
  override_resource {
    target          = aws_iam_role.supervisor_storage
    values          = { arn = "arn:aws:iam::123456789012:role/test-supervisor-storage-role" }
    override_during = plan
  }
  override_resource {
    target          = aws_s3_bucket.audit_persistence
    values          = { arn = "arn:aws:s3:::test-audit-persistence-123456789012" }
    override_during = plan
  }
  variables {
    deploy_cluster                   = true
    create_audit_persistence_bucket  = true
    create_spaces_persistence_bucket = true
  }

  assert {
    condition     = length(local.storage_irsa_subjects) == 1 && local.storage_irsa_subjects[0] == "system:serviceaccount:${var.namespace}:${var.release_name}-api"
    error_message = "only the api's KSA may assume the shared storage role (it reaches the audit bucket)"
  }
  assert {
    condition     = length(aws_iam_role.supervisor_storage) == 1
    error_message = "the supervisor needs its own storage role when the spaces bucket is on"
  }
  assert {
    condition     = local.supervisor_storage_bucket_arns == tolist([aws_s3_bucket.spaces_persistence[0].arn])
    error_message = "the supervisor's policy may name the spaces bucket, nothing else"
  }
  assert {
    condition     = !contains(local.supervisor_storage_bucket_arns, aws_s3_bucket.audit_persistence[0].arn)
    error_message = "the supervisor's policy must not name the audit bucket"
  }
  assert {
    condition     = !contains(local.storage_irsa_subjects, local.supervisor_irsa_subject)
    error_message = "the supervisor's KSA must not be able to assume the shared role"
  }
  assert {
    condition     = local.supervisor_service_account_annotations["eks.amazonaws.com/role-arn"] == aws_iam_role.supervisor_storage[0].arn
    error_message = "the supervisor's KSA must carry the supervisor role, not the shared one"
  }
}

run "spaces_only_still_gets_supervisor_role" {
  command = plan
  variables {
    deploy_cluster                   = true
    create_spaces_persistence_bucket = true
  }
  assert {
    condition     = length(aws_iam_role.supervisor_storage) == 1
    error_message = "the supervisor role must exist whenever the spaces bucket does"
  }
}

run "no_spaces_bucket_no_supervisor_role" {
  command = plan
  variables {
    deploy_cluster                  = true
    create_audit_persistence_bucket = true
  }
  assert {
    condition     = length(aws_iam_role.supervisor_storage) == 0
    error_message = "no spaces bucket, no supervisor storage role"
  }
}
