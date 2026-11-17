# http_mode (chart ingress.http): the default leaves the chart values as they
# were; every combination the chart would refuse fails the plan here first.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "tls" {}

variables {
  installation_jwt   = "mock"
  deployment_id      = "mock"
  chart_version      = "0.36.0"
  ingress_host       = "marshal.example.com"
  database_mode      = "bundled"
  ingress_class_name = "traefik"
  tls_mode           = "self_signed"
}

run "default_sends_nothing" {
  command = plan

  assert {
    condition     = !contains(keys(local.ingress_values.ingress), "http")
    error_message = "http_mode = serve (default) must not add ingress.http"
  }
}

run "redirect_on_traefik" {
  command = plan

  variables {
    http_mode = "redirect"
  }

  assert {
    condition     = local.ingress_values.ingress.http == "redirect"
    error_message = "http_mode = redirect must render ingress.http = redirect"
  }
}

run "needs_tls" {
  command = plan

  variables {
    http_mode = "redirect"
    tls_mode  = "none"
  }

  expect_failures = [helm_release.marshal]
}

run "gke_managed_certificate_counts_as_https" {
  command = plan

  variables {
    http_mode          = "off"
    tls_mode           = "none"
    ingress_class_name = "gce"
    ingress_annotations = {
      "networking.gke.io/managed-certificates" = "marshal-cert"
    }
  }

  assert {
    condition     = local.ingress_values.ingress.http == "off"
    error_message = "a Google-managed certificate must count as HTTPS"
  }
}

run "previews_on_http_refused" {
  command = plan

  variables {
    http_mode      = "off"
    preview_domain = "preview.example.com"
    preview_scheme = "http"
  }

  expect_failures = [helm_release.marshal]
}

run "redirect_on_gce_internal_refused" {
  command = plan

  variables {
    http_mode          = "redirect"
    ingress_class_name = "gce-internal"
  }

  expect_failures = [helm_release.marshal]
}

run "off_on_nginx_refused" {
  command = plan

  variables {
    http_mode          = "off"
    ingress_class_name = "nginx"
  }

  expect_failures = [helm_release.marshal]
}

run "unknown_controller_refused" {
  command = plan

  variables {
    http_mode          = "redirect"
    ingress_class_name = ""
  }

  expect_failures = [helm_release.marshal]
}
