# next_steps on the install path: what a first install needs to be told
# (DNS-endpoint credentials, the storage and load-balancer warnings, the
# no-DNS access pointer). Applied against mocks, because the module's
# next_steps reads the helm release, which a plan does not know yet.

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
  install_marshal      = true
  database_mode        = "bundled"
  redis_mode           = "bundled"
  dns_endpoint_enabled = true
}

run "first_install_is_warned" {
  command = apply

  assert {
    condition     = strcontains(output.next_steps, "get-credentials marshal --location europe-west1 --project test-project --dns-endpoint")
    error_message = "next_steps must fetch credentials over the DNS endpoint when it is on"
  }
  assert {
    condition     = strcontains(output.next_steps, "5 to 15")
    error_message = "next_steps must warn that the load balancer is not ready yet"
  }
  assert {
    condition     = strcontains(output.next_steps, "Space storage is OFF")
    error_message = "next_steps must warn when the spaces bucket is off"
  }
  assert {
    condition     = strcontains(output.next_steps, "Reaching Marshal")
    error_message = "next_steps must point at the no-DNS access path"
  }
  # The port-forward path leads: the host link works only once DNS exists and
  # the internal load balancer is reachable.
  assert {
    condition     = strcontains(output.next_steps, "http://localhost:8080/setup#token=<TOKEN>")
    error_message = "next_steps must give the setup link over the port-forward"
  }
  assert {
    condition     = length(split("http://localhost:8080/setup", output.next_steps)[0]) < length(split("https://marshal.example.com/setup", output.next_steps)[0])
    error_message = "the port-forward setup link must come before the host link"
  }
  # The placeholder-certificate advice is GKE's, not the ALB's.
  assert {
    condition     = !strcontains(output.next_steps, "acm_certificate_arn") && strcontains(output.next_steps, "create_managed_certificate")
    error_message = "next_steps on GKE must not print the AWS TLS advice"
  }
  # Every line of the multi-line tls_next_steps lands at the paragraph's
  # two-space indent: the heredoc strips the template's own indent from the
  # first line only, so the continuation lines get theirs from indent(2, ...).
  assert {
    condition     = strcontains(output.next_steps, "\n  Replace it with tls_mode = \"inline\" (your certificate and key in tfvars),\n  tls_mode = \"secret\" (a TLS Secret you manage, for example from cert-manager), or\n  a Google-managed certificate: ingress_mode = \"gateway\" and\n  create_managed_certificate = true.")
    error_message = "every line of tls_next_steps must align at the paragraph's indent"
  }
  assert {
    condition     = strcontains(output.next_steps, "Tearing down, in this order") && strcontains(output.next_steps, "deletion_protection = false") && !strcontains(output.next_steps, "force_destroy_buckets = true")
    error_message = "next_steps must print the teardown order, with force_destroy_buckets only when there are buckets"
  }
}

run "spaces_bucket_on_no_warning" {
  command = apply

  variables {
    create_spaces_persistence_bucket = true
    create_audit_persistence_bucket  = true
  }

  assert {
    condition     = !strcontains(output.next_steps, "Space storage is OFF")
    error_message = "no storage warning once the spaces bucket is on"
  }
  assert {
    condition     = strcontains(output.next_steps, "Settings > Auditing > Storage > provider Google Cloud Storage")
    error_message = "next_steps must tell the owner to connect the audit bucket"
  }
  assert {
    condition     = strcontains(output.next_steps, "deletion_protection = false and force_destroy_buckets = true")
    error_message = "with buckets, teardown step 2 must set force_destroy_buckets"
  }
}

# External Postgres with no database_url installs an api that cannot start, so
# the plan stops instead of warning.
run "external_database_needs_url" {
  command = plan

  variables {
    database_mode = "external"
    database_url  = ""
  }

  expect_failures = [output.next_steps]
}

# Your own network (create_network = false): the VPC, and any Cloud SQL on it,
# are not this install's, so the teardown must not tell you to delete them.
# The Cloud SQL APIs are not added either.
run "own_network_keeps_cloud_sql" {
  command = apply

  variables {
    create_network = false
    network        = "acme-vpc"
    subnetwork     = "acme-subnet"
    database_mode  = "external"
    database_url   = "postgres://u:p@10.0.0.5:5432/marshal"
  }

  assert {
    condition     = !strcontains(output.next_steps, "Delete the Cloud SQL instance") && strcontains(output.next_steps, "this install did not create the VPC")
    error_message = "on your own network the teardown must not delete Cloud SQL or its peering"
  }
  assert {
    condition     = !contains(keys(google_project_service.required), "sqladmin.googleapis.com")
    error_message = "a network the install did not create gets no Cloud SQL APIs"
  }
}

# The installer's own VPC with Cloud SQL: the teardown removes it before the destroy.
run "own_vpc_deletes_cloud_sql_first" {
  command = apply

  variables {
    database_mode = "external"
    database_url  = "postgres://u:p@10.0.0.5:5432/marshal"
  }

  assert {
    condition     = strcontains(output.next_steps, "Delete the Cloud SQL instance") && strcontains(output.next_steps, "deletion_protection = false")
    error_message = "on the installer's VPC the teardown must remove Cloud SQL and PSA, and turn off deletion protection"
  }
}

# A reused cluster: nothing for the installer to unprotect.
run "reused_cluster_no_deletion_protection_step" {
  command = apply

  variables {
    deploy_cluster = false
    cluster_name   = "existing"
    subnetwork     = "acme-subnet"
  }

  assert {
    condition     = !strcontains(output.next_steps, "deletion_protection = false")
    error_message = "deletion_protection only applies to a cluster the installer built"
  }
}
