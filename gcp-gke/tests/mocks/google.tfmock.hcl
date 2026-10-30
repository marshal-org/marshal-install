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
