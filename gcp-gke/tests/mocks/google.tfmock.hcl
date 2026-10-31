# Shared mock data for the google provider in this flavor's plan-only tests.
# Every *.tftest.hcl declares its own mock_provider "google" with
# source = "./tests/mocks". Values only need to be well-formed: nothing here
# reaches a real API.

mock_data "google_client_config" {
  defaults = {
    access_token = "mock-token"
  }
}

mock_data "google_project" {
  defaults = {
    number = "123456789012"
  }
}

# A random string fails the IAM member's service_account_id validation, which
# only an applied run (next_steps.tftest.hcl) reaches.
mock_resource "google_service_account" {
  defaults = {
    name  = "projects/test-project/serviceAccounts/marshal-storage@test-project.iam.gserviceaccount.com"
    email = "marshal-storage@test-project.iam.gserviceaccount.com"
  }
}
