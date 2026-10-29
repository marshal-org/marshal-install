# ingress_mode = "gateway": expose Marshal through a Gateway API Gateway instead
# of a GKE Ingress (chart ingress.mode=gateway, marshal#1689). The reason to do
# it: a GKE Ingress on an internal load balancer cannot use a Google-managed
# (Certificate Manager) certificate, a Gateway can, so HTTPS gets a real,
# auto-renewing certificate with nothing in the cluster to rotate.
#
# What this flavor wires for it:
#   - the cluster's Gateway API (cluster.tf, gateway_api_config) when it
#     provisions the cluster; on a reused cluster turn it on yourself
#     (gcloud container clusters update <name> --gateway-api=standard).
#   - the Gateway pinned to the same reserved internal IP the Ingress uses
#     (ingress_ip.tf), so DNS does not change.
#   - optionally, the managed certificate itself (below), handed to the chart
#     only once Google reports it ACTIVE — the same two-apply flow as the
#     aws-eks ACM certificate (alb_tls.tf). Before that, HTTPS serves the
#     tls_mode certificate through the Gateway, so there is no gap.

locals {
  gateway_mode = var.ingress_mode == "gateway"

  create_managed_cert = local.gateway_mode && var.create_managed_certificate

  # One DNS authorization per domain. An authorization for preview.acme.com
  # also covers *.preview.acme.com.
  managed_cert_auth_domains = local.create_managed_cert ? merge(
    { host = var.ingress_host },
    var.preview_domain == "" ? {} : { preview = var.preview_domain },
  ) : {}

  managed_cert_domains = compact([
    var.ingress_host,
    var.preview_domain == "" ? "" : "*.${var.preview_domain}",
  ])

  managed_cert_state  = try(google_certificate_manager_certificate.managed[0].managed[0].state, null)
  managed_cert_active = local.managed_cert_state == "ACTIVE"

  gateway_cert_names = concat(
    var.gateway_certificate_names,
    local.managed_cert_active ? [google_certificate_manager_certificate.managed[0].name] : [],
  )

  # The internal static IP (ingress_ip.tf) is always reserved in gateway mode.
  gateway_addresses = local.needs_static_ip ? [{ type = "NamedAddress", value = var.ingress_static_ip_name }] : []
}

resource "google_certificate_manager_dns_authorization" "managed" {
  for_each = local.managed_cert_auth_domains

  name     = "${var.cluster_name}-${each.key}-dns-auth"
  project  = var.project_id
  location = local.region
  domain   = each.value
}

resource "google_certificate_manager_certificate" "managed" {
  count = local.create_managed_cert ? 1 : 0

  name     = "${var.cluster_name}-marshal-cert"
  project  = var.project_id
  location = local.region

  managed {
    domains            = local.managed_cert_domains
    dns_authorizations = [for a in google_certificate_manager_dns_authorization.managed : a.id]
  }
}

check "gateway_mode_internal" {
  assert {
    condition     = !local.gateway_mode || var.internal_ingress
    error_message = "ingress_mode = \"gateway\" needs internal_ingress = true (regional internal load balancer, class gke-l7-rilb)."
  }
}

check "managed_certificate_needs_gateway" {
  assert {
    condition     = !var.create_managed_certificate || local.gateway_mode
    error_message = "create_managed_certificate = true needs ingress_mode = \"gateway\": a GKE Ingress on an internal load balancer cannot use a Certificate Manager certificate."
  }
}
