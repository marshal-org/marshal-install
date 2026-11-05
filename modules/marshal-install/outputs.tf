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
      kubectl port-forward -n ${var.namespace} svc/web 8080:80 &
      curl -s localhost:8080/api/version      # the web Service serves the console and the API on one port

    Reach it:
      ${length(local.effective_ingress_tls) > 0 ? "https" : "http"}://${var.ingress_host}

    Claim the owner account (first run only):
      Read the setup token. Terraform never reads it, so it is not in state:
         kubectl get secret ${var.secrets_existing_secret != "" ? var.secrets_existing_secret : "${var.release_name}-app-secrets"} -n ${var.namespace} -o jsonpath='{.data.SETUP_TOKEN}' | base64 -d
      Then open this link, with <TOKEN> replaced by that value (the part after # never leaves your browser):
         ${length(local.effective_ingress_tls) > 0 ? "https" : "http"}://${var.ingress_host}/setup#token=<TOKEN>
      If the page does not prefill the token (charts older than 0.26), open
      ${length(local.effective_ingress_tls) > 0 ? "https" : "http"}://${var.ingress_host}/setup and paste the token by hand.
      If the command prints nothing, the secret has no SETUP_TOKEN key and first-run
      setup is off: add one (any random string) to the secret and restart the api.
      The token works until the owner exists, then the page reports "already set up".
      No browser? Claim it over the API instead. Read the password without echo
      (it must not contain a " or a \):
         read -rs PW
         curl -s -X POST ${length(local.effective_ingress_tls) > 0 ? "https" : "http"}://${var.ingress_host}/api/auth/setup -H 'Content-Type: application/json' -d "{\"token\":\"<TOKEN>\",\"email\":\"you@example.com\",\"password\":\"$PW\",\"org_name\":\"Your Org\"}"
      A 201 with a session means the owner exists; a second attempt returns 409. Add -k
      while the certificate is the placeholder. If that host is not reachable from this
      machine, run it against http://localhost:8080 over the port-forward above.
      The CLI then logs in with:  marshal login --server <url> --password
      (plain 'marshal login' opens a browser, which hangs on a machine without one).

    First space (in this order):
      1. Connect the spaces bucket, if you created one: Settings > Space Storage, then
         Save & enable. Do this BEFORE the first space: a space created earlier still
         loses its workspace when it is stopped.
      2. Marketplace: install a stack (for example default-engineering) and publish it.
         A new install has no stacks or manifests, so "New space" has nothing to offer
         until you do.
      3. New space > Create a manifest, from that stack, then launch the space.
      Steps with screenshots: https://docs.marshal.codes/getting-started/owner ("Publish your first stack").
    %{if var.preview_domain != ""~}

    Previews need DNS too: point a wildcard record *.${var.preview_domain} at the
    same target as ${var.ingress_host}. If you requested an ACM certificate, the
    wildcard's validation record is in acm_validation_records as well. Without
    the wildcard record, preview URLs (${var.preview_scheme}://<port>.${var.preview_domain}) do not resolve.
    %{endif~}
    %{if var.tls_mode == "self_signed" && length(var.ingress_tls) == 0~}

    ⚠ TLS cert is a Marshal-generated PLACEHOLDER (self-signed, Subject O=
      "Marshal Platform Temp Cert") — browsers/clients will warn. Replace it
      with tls_mode="inline" (paste real PEM into tfvars; on AWS the installer
      imports it into ACM), with acm_certificate_arn where your cloud's flavor
      has one, or with a mode your platform supports. Read the TLS section of
      your cloud's README before
      switching: an AWS load balancer serves certificates from ACM and cannot
      read a Kubernetes TLS Secret at all, so tls_mode="secret" needs more than
      a one-line change there;
      no other config needs to change.
    %{endif~}

    ${var.extra_next_steps == "" ? "" : "${trimspace(var.extra_next_steps)}\n\n"}Day-2:
      • Upgrade   — bump chart_version and re-apply.
      • Object storage for stop/resume is configured per org, not here: an
        owner or admin connects the bucket in Settings > Space Storage and enables it
        (the API routes behind that screen are PUT /api/org/space-storage, then
        PATCH /api/org/space-storage/enabled with {"enabled":true}). Until then a stopped
        space loses its workspace unless it runs on a size with a persistent disk.
  EOT
}
