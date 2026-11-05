output "app_url" {
  description = "Marshal web console + API URL."
  value       = module.marshal.app_url
}

output "namespace" {
  description = "Control-plane namespace."
  value       = module.marshal.namespace
}

output "spaces_namespace" {
  description = "Session-pod namespace."
  value       = module.marshal.spaces_namespace
}

output "chart_version" {
  description = "Installed product version."
  value       = module.marshal.chart_version
}

# The bastion is how you reach a private-only endpoint, and until now the only
# way to find it was to go looking in the console: the flavor created an
# instance you have to target by id and then did not tell you the id.
output "bastion_instance_id" {
  description = "Instance id of the SSM bastion, for `aws ssm start-session --target <id>`. Empty when create_bastion=false or when reusing a cluster."
  value       = try(one(aws_instance.bastion[*].id), "")
}

output "next_steps" {
  description = "Verify + reach the deployment."
  value       = module.marshal.next_steps
}

# ── ACM (only populated when this flavor requested the certificate) ──────────
output "acm_validation_records" {
  description = "The DNS records to add, for the manual-DNS path. One entry per distinct record: a wildcard and its parent domain share one CNAME, so it is listed once, with both names under domains. Add each in whatever DNS you run. On Cloudflare the CNAME must be DNS-only (grey cloud), not proxied. Wait for acm_certificate_status_line to read ISSUED, then apply again to turn HTTPS on. Empty when acm_request_certificate=false or when Route53 created them for you."
  value = [
    for r in values(local.acm_validation_records) : {
      domains = r.domains
      name    = r.name
      type    = r.type
      value   = r.value
    }
  ]
}

output "acm_certificate_arn" {
  description = "The certificate the ALB is actually serving. Empty means HTTP only: either no certificate was supplied, or one was requested and has not been validated yet."
  value       = local.alb_certificate_arn
}

output "acm_certificate_status" {
  description = "ACM status of a certificate this flavor requested (PENDING_VALIDATION until the records resolve). null otherwise."
  value       = try(local.requested_cert_status, null)
}

output "acm_certificate_status_line" {
  description = "One line on where the certificate stands, and what to do next."
  # On the Route53 path aws_acm_certificate_validation holds the apply until the
  # cert is ISSUED, and alb_certificate_arn then picks it up, so only the
  # manual-DNS path ever shows a status other than ISSUED here.
  value = (
    var.acm_certificate_arn != "" ? "Certificate: using your own ACM certificate. HTTPS is on." :
    var.acm_request_certificate ? (
      local.alb_certificate_arn != "" ? "Certificate: ISSUED. HTTPS is on." :
      local.requested_cert_status == "PENDING_VALIDATION" ? "Certificate: PENDING_VALIDATION. Add the records in acm_validation_records to your DNS (Cloudflare: DNS-only, grey cloud, not proxied), then apply again. The site is HTTP only until then." :
      # VALIDATION_TIMED_OUT (ACM gives up after 72 hours), FAILED (a CAA record,
      # for example), or REVOKED. Adding records now does nothing: ACM never
      # retries, so the certificate has to be requested again.
      "Certificate: ${local.requested_cert_status}. ACM will not retry this one. Request a new one with: terraform apply -replace='aws_acm_certificate.requested[0]', then add the new records in acm_validation_records. The site is HTTP only until then."
    ) :
    local.create_alb_cert ? "Certificate: imported into ACM (placeholder or your PEM). HTTPS is on." :
    lookup(var.ingress_annotations, "alb.ingress.kubernetes.io/certificate-arn", "") != "" ? "Certificate: the ARN set in ingress_annotations. HTTPS is on if that certificate is ISSUED." :
    "Certificate: none. The ALB serves HTTP only."
  )
}
