# =============================================================================
# TLS — self-signed placeholder generation + managed Secret.
# =============================================================================
# HTTPS is the default posture (see tls_mode in variables.tf). This file only
# creates resources for the two modes the module itself manages a cert for
# ("self_signed" generates one, "inline" takes the caller's PEM content) —
# "secret" mode intentionally creates nothing here (the caller's own Secret is
# used as-is) and "none" disables TLS entirely.

locals {
  # Hosts the default/inline cert needs to cover: the primary host, any extra
  # ingress hosts, plus the preview wildcard when previews are enabled.
  # Mirrors how ingress_values (main.tf) derives hostnames from the same
  # variables.
  tls_hosts = distinct(compact(concat(
    [var.ingress_host],
    var.extra_ingress_hosts,
    [var.preview_domain != "" ? "*.${var.preview_domain}" : ""],
  )))

  # "self_signed"/"inline": the module always names the Secret it manages
  # "marshal-tls". "secret": use whatever name the caller already created.
  tls_secret_name_effective = var.tls_mode == "secret" ? var.tls_secret_name : "marshal-tls"

  # If the caller still sets the low-level ingress_tls directly, it always
  # wins (zero behavior change for anyone already using it explicitly).
  # Otherwise, derive it from tls_mode.
  effective_ingress_tls = length(var.ingress_tls) > 0 ? var.ingress_tls : (
    var.tls_mode == "none" ? [] : [
      { hosts = local.tls_hosts, secretName = local.tls_secret_name_effective }
    ]
  )
}

# ── Self-signed placeholder cert (tls_mode = "self_signed") ──────────────────
# Clearly labeled in the Subject so it's unmistakable in any cert viewer
# (browser padlock details, `openssl x509 -noout -subject`) that this is a
# Marshal-generated placeholder, not a real certificate.
resource "tls_private_key" "self_signed" {
  count     = var.tls_mode == "self_signed" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "this" {
  count           = var.tls_mode == "self_signed" ? 1 : 0
  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name  = var.ingress_host
    organization = "Marshal Platform Temp Cert"
  }

  dns_names             = local.tls_hosts
  validity_period_hours = 24 * 825 # ~825 days, same ceiling browsers already enforce

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# ── The Secret the module manages (self_signed generates it, inline takes the
#    caller's PEM as-is). Nothing is created for tls_mode = "secret" | "none".
resource "kubernetes_secret" "tls" {
  count = contains(["self_signed", "inline"], var.tls_mode) ? 1 : 0

  metadata {
    name      = local.tls_secret_name_effective
    namespace = var.namespace
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = var.tls_mode == "self_signed" ? tls_self_signed_cert.this[0].cert_pem : var.tls_cert_pem
    "tls.key" = var.tls_mode == "self_signed" ? tls_private_key.self_signed[0].private_key_pem : var.tls_key_pem
  }

  depends_on = [kubernetes_namespace.marshal]
}
