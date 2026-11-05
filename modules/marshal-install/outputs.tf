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
  value       = local.app_url
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

    Reach it (the port-forward above works from anywhere kubectl does):
      1. http://localhost:8080, while the port-forward runs: the console, the API and the CLI.
      2. ${local.app_url}, once ${var.ingress_host} resolves to the load balancer
         and this machine can reach it. An internal load balancer answers inside the network only.
      No DNS of your own yet? Any placeholder ingress_host works; use the port-forward.

    Claim the owner account (first run only):
      Read the setup token. Terraform never reads it, so it is not in state:
         kubectl get secret ${var.secrets_existing_secret != "" ? var.secrets_existing_secret : "${var.release_name}-app-secrets"} -n ${var.namespace} -o jsonpath='{.data.SETUP_TOKEN}' | base64 -d
      Then open this link, with <TOKEN> replaced by that value (the part after # never leaves your browser):
         http://localhost:8080/setup#token=<TOKEN>        over the port-forward
         ${local.app_url}/setup#token=<TOKEN>   once the host link above works
      If the page does not prefill the token (charts older than 0.26), open /setup on the
      same address and paste the token by hand.
      If the command prints nothing, the secret has no SETUP_TOKEN key and first-run
      setup is off: add one (any random string) to the secret and restart the api.
      The token works until the owner exists, then the page reports "already set up".
      No browser? Claim it over the API instead. Read the password without echo
      (it must not contain a " or a \):
         read -rs PW
         curl -s -X POST http://localhost:8080/api/auth/setup -H 'Content-Type: application/json' -d "{\"token\":\"<TOKEN>\",\"email\":\"you@example.com\",\"password\":\"$PW\",\"org_name\":\"Your Org\"}"
      A 201 with a session means the owner exists; a second attempt returns 409. Against
      ${local.app_url} instead, add -k while the certificate is the placeholder.
      The CLI then logs in with:  marshal login --server <url> --password
      (plain 'marshal login' opens a browser, which hangs on a machine without one).

    First space (in this order):
      1. Connect the spaces bucket, if you created one: Settings > Space Storage, then
         Save & enable. Do this BEFORE the first space: a space created earlier still
         loses its workspace when it is stopped.
      2. Marketplace > Stacks: Install stack on default-engineering (it installs the
         packages it needs and creates a draft), then Stacks > open it > Publish v1.
         A new install has no stacks or manifests, so "New space" has nothing to offer
         until you do.
      3. New space > Create a manifest, from that stack, then launch the space.
      Steps with screenshots: https://docs.marshal.codes/getting-started/owner ("Publish your first stack").
    %{if var.preview_domain != ""~}

    Previews need DNS too: point a wildcard record *.${var.preview_domain} at the
    same target as ${var.ingress_host}. If the installer requested a certificate for
    you (ACM on AWS, Certificate Manager on GKE), add the wildcard's validation record
    from its output as well. Without
    the wildcard record, preview URLs (${var.preview_scheme}://<port>.${var.preview_domain}) do not resolve.
    %{endif~}
    %{if var.tls_mode == "self_signed" && length(var.ingress_tls) == 0~}

    ⚠ TLS cert is a Marshal-generated PLACEHOLDER (self-signed, Subject O=
      "Marshal Platform Temp Cert"), so browsers and clients warn.
      ${indent(2, trimspace(var.tls_next_steps))}
    %{endif~}

    ${var.extra_next_steps == "" ? "" : "${trimspace(var.extra_next_steps)}\n\n"}Day-2:
      • Upgrade   — check out the new installer tag, set chart_version, answer every
                    new entry in capabilities.yaml in terraform.tfvars (pin node sizes),
                    then terraform init -upgrade, terraform plan, and apply only a plan
                    that replaces nothing you did not choose. pin_bundled_datastores = false
                    only when that upgrade turns the control-plane taint on and the bundled
                    Redis/Postgres runs off the control-plane pool today.
      • Object storage for stop/resume is configured per org, not here: an
        owner or admin connects the bucket in Settings > Space Storage and enables it
        (the API routes behind that screen are PUT /api/org/space-storage with
        provider, bucket, region (S3: the bucket's own region) and path_prefix, then
        PATCH /api/org/space-storage/enabled with {"enabled":true}). Until then a stopped
        space loses its workspace unless it runs on a size with a persistent disk.
  EOT
}
