# ALB terminates TLS itself using an ACM certificate — it has NO concept of
# reading a Kubernetes-native TLS Secret the way GKE's Ingress or nginx-ingress
# do. Confirmed live: with the shared install module's default
# (tls_mode="self_signed", which only ever creates a k8s Secret —
# modules/marshal-install/tls.tf), the ALB controller silently never creates
# an HTTPS:443 listener at all — no error anywhere, the Ingress object itself
# still lists "443" as if it worked, only `aws elbv2 describe-listeners` shows
# the truth (HTTP:80 only). Without this file, `tls_mode="self_signed"` (the
# default) quietly means "HTTP only" specifically on this flavor, unlike every
# other flavor where it's a real, working HTTPS placeholder.
#
# Fix: generate/import an ACM certificate and wire it via the
# alb.ingress.kubernetes.io/certificate-arn annotation — the actual mechanism
# ALB needs. Only for the two modes the shared module manages a cert for
# itself ("self_signed" generates one, "inline" takes the caller's PEM) —
# "secret" mode already has a working escape hatch (set
# alb.ingress.kubernetes.io/certificate-arn directly via ingress_annotations
# if you're bringing your own ACM cert) and "none" means HTTP-only on
# purpose. modules/marshal-install itself is untouched — this is entirely
# additive, flavor-local Terraform.

locals {
  # A real certificate (an ARN you own, or one we request) always beats the
  # tls_mode placeholder, so don't import a self-signed cert nobody will use.
  real_cert_supplied = var.acm_certificate_arn != "" || var.acm_request_certificate

  create_alb_cert = local.provision && contains(["self_signed", "inline"], var.tls_mode) && !local.real_cert_supplied

  # Same host list the shared module's tls.tf derives its own placeholder
  # cert for (var.ingress_host + extra_ingress_hosts + the preview wildcard,
  # if set) — kept in sync deliberately so the ALB's cert and the
  # (now-vestigial-for-ALB, but still module-managed) k8s Secret cert cover
  # the same names.
  alb_tls_hosts = distinct(compact(concat(
    [var.ingress_host],
    var.extra_ingress_hosts,
    [var.preview_domain != "" ? "*.${var.preview_domain}" : ""],
  )))
}

# ── self_signed: generate our own placeholder (separate from the module's
#    own self-signed cert, which ALB can never use) ──────────────────────────
resource "tls_private_key" "alb_self_signed" {
  count     = local.create_alb_cert && var.tls_mode == "self_signed" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  count           = local.create_alb_cert && var.tls_mode == "self_signed" ? 1 : 0
  private_key_pem = tls_private_key.alb_self_signed[0].private_key_pem

  subject {
    common_name  = var.ingress_host
    organization = "Marshal Platform Temp Cert"
  }

  dns_names             = local.alb_tls_hosts
  validity_period_hours = 24 * 825 # ~825 days, same ceiling browsers already enforce

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# ── ACM import — self_signed uses the cert generated above; inline uses the
#    caller's own PEM content directly (no need to regenerate) ─────────────
resource "aws_acm_certificate" "alb" {
  count = local.create_alb_cert ? 1 : 0

  certificate_body = var.tls_mode == "self_signed" ? tls_self_signed_cert.alb[0].cert_pem : var.tls_cert_pem
  private_key      = var.tls_mode == "self_signed" ? tls_private_key.alb_self_signed[0].private_key_pem : var.tls_key_pem

  tags = { Name = "${var.cluster_name}-alb-tls" }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Request a real cert (acm_request_certificate) ────────────────────────────
# Public ACM certs are free, auto-renewing, and work on an INTERNAL ALB: the
# ALB never has to be reachable from the internet, only the DNS name has to be
# in a zone the customer controls, and the record it points at can be private.
resource "aws_acm_certificate" "requested" {
  count = var.acm_request_certificate ? 1 : 0

  domain_name               = var.ingress_host
  subject_alternative_names = [for h in local.alb_tls_hosts : h if h != var.ingress_host]
  validation_method         = "DNS"

  tags = { Name = "${var.cluster_name}-alb-tls-requested" }

  lifecycle {
    create_before_destroy = true
  }
}

# Only when the zone is in Route53. Everyone else reads the acm_validation_records
# output and adds the same CNAMEs wherever their DNS actually lives.
resource "aws_route53_record" "acm_validation" {
  for_each = var.acm_request_certificate && var.acm_validation_route53_zone_id != "" ? {
    for dvo in aws_acm_certificate.requested[0].domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  } : {}

  zone_id = var.acm_validation_route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.value]
  ttl     = 60
  # ACM re-issues on renewal with the same validation record, but a wildcard
  # SAN and its parent can resolve to the SAME record name, so allow a clobber
  # rather than failing the apply on a duplicate.
  allow_overwrite = true
}

# Blocks the apply until ACM reports ISSUED. Only exists on the Route53 path:
# with manual DNS there is nothing for Terraform to wait on, and a wait would
# just hang for however long the operator takes to add the record.
resource "aws_acm_certificate_validation" "requested" {
  count = var.acm_request_certificate && var.acm_validation_route53_zone_id != "" ? 1 : 0

  certificate_arn         = aws_acm_certificate.requested[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

locals {
  requested_validation = one(aws_acm_certificate_validation.requested[*])
  # Attributes, not the object. Every aws_acm_certificate carries private_key,
  # which the provider marks sensitive, requested certs included, and a
  # collection holding a sensitive value is itself sensitive in Terraform, so
  # one(...[*]).arn came out sensitive and outputs refused to render:
  #   Error: Output refers to sensitive values
  # Splatting the attribute never builds that object.
  requested_cert_arn    = one(aws_acm_certificate.requested[*].arn)
  requested_cert_status = one(aws_acm_certificate.requested[*].status)
  imported_cert_arn     = one(aws_acm_certificate.alb[*].arn)

  # Priority: your own ARN, then a cert we requested, then the placeholder.
  #
  # On the manual-DNS path the requested cert is only attached once AWS reports
  # it ISSUED. That is deliberate: an ALB listener rejects a certificate still
  # in PENDING_VALIDATION, so the first apply has to come up on HTTP, and the
  # second apply (after the operator adds the CNAME) is what turns HTTPS on.
  #
  # coalesce() skips "" as well as null, but ERRORS when every argument is
  # empty. Confirmed live: "no non-null, non-empty-string arguments". The
  # try() is therefore load-bearing, because "no certificate at all" is a
  # legitimate state (HTTP only) and it is the default on the reuse path.
  alb_certificate_arn = try(coalesce(
    var.acm_certificate_arn,
    try(local.requested_validation.certificate_arn, ""),
    try(local.requested_cert_status, "") == "ISSUED" ? try(local.requested_cert_arn, "") : "",
    try(local.imported_cert_arn, ""),
  ), "")
}
