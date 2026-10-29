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
  description = "DNS records that prove you own the hostnames, for the manual-DNS path. Includes the preview wildcard (*.preview_domain) when preview_domain is set; a wildcard and its parent domain can share one record name. Add each one in whatever DNS you run, wait for the status below to read ISSUED, then apply again to turn HTTPS on. Empty when acm_request_certificate=false or when Route53 created them for you."
  value = var.acm_request_certificate && var.acm_validation_route53_zone_id == "" ? [
    for dvo in aws_acm_certificate.requested[0].domain_validation_options : {
      domain = dvo.domain_name
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      value  = dvo.resource_record_value
    }
  ] : []
}

output "acm_certificate_arn" {
  description = "The certificate the ALB is actually serving. Empty means HTTP only: either no certificate was supplied, or one was requested and has not been validated yet."
  value       = local.alb_certificate_arn
}

output "acm_certificate_status" {
  description = "ACM status of a certificate this flavor requested (PENDING_VALIDATION until the records resolve). null otherwise."
  value       = try(local.requested_cert_status, null)
}
