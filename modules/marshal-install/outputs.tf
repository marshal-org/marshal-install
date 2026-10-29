# Post-install values a flavor re-exports and an operator uses to verify + reach
# the deployment.

output "namespace" {
  description = "Namespace the control-plane workloads run in."
  value       = var.namespace
}

output "spaces_namespace" {
  description = "Namespace session pods run in (<release>-spaces unless overridden)."
  value       = local.spaces_namespace
}

output "release_name" {
  description = "Helm release name."
  value       = helm_release.marshal.name
}

output "chart_version" {
  description = "Installed chart (== product) version. Bump the input and re-apply to upgrade."
  value       = helm_release.marshal.version
}

output "app_url" {
  description = "URL of the Marshal web console + API."
  value       = "${length(local.effective_ingress_tls) > 0 ? "https" : "http"}://${var.ingress_host}"
}

output "preview_url_pattern" {
  description = "Wildcard pattern session port-previews are served under (null when previews are disabled)."
  value       = var.preview_domain == "" ? null : "${var.preview_scheme}://<port>.${var.preview_domain}"
}

output "next_steps" {
  description = "Copy-paste commands to verify the install and finish setup."
  value       = <<-EOT
    Marshal ${helm_release.marshal.version} installed as release "${helm_release.marshal.name}" in namespace "${var.namespace}".

    Verify:
      ${var.kubeconfig_command}
      kubectl get pods -n ${var.namespace}
      kubectl logs -n ${var.namespace} -l app.kubernetes.io/component=api -c migrate   # "migrations applied"
      kubectl logs -n ${var.namespace} -l app.kubernetes.io/component=api --tail=-1 | grep "license state"
      kubectl port-forward -n ${var.namespace} svc/api 8080:8080 &
      curl -s localhost:8080/api/version

    Reach it:
      ${length(local.effective_ingress_tls) > 0 ? "https" : "http"}://${var.ingress_host}
    %{if var.preview_domain != ""~}

    Previews need DNS too: point a wildcard record *.${var.preview_domain} at the
    same target as ${var.ingress_host}. If you requested an ACM certificate, the
    wildcard's validation record is in acm_validation_records as well. Without
    the wildcard record, preview URLs (${var.preview_scheme}://<port>.${var.preview_domain}) do not resolve.
    %{endif~}
    %{if var.tls_mode == "self_signed" && length(var.ingress_tls) == 0~}

    ⚠ TLS cert is a Marshal-generated PLACEHOLDER (self-signed, Subject O=
      "Marshal Platform Temp Cert") — browsers/clients will warn. Replace it
      with tls_mode="inline" (paste real PEM into tfvars), or with a mode your
      platform supports. Read the TLS section of your cloud's README before
      switching: an AWS load balancer serves certificates from ACM and cannot
      read a Kubernetes TLS Secret at all, so tls_mode="secret" needs more than
      a one-line change there;
      no other config needs to change.
    %{endif~}

    Day-2:
      • Upgrade   — bump chart_version and re-apply.
      • Object storage for pause/resume is configured per-org via the API
        (PUT /api/org/space-storage), not here.
  EOT
}
