# Static IP for the Ingress — codifies what has to be done by hand otherwise:
# GKE's gce-internal IngressClass requires a static IP with Purpose=
# SHARED_LOADBALANCER_VIP to serve HTTP+HTTPS on the same address once TLS is
# on (tls_mode != "none"). Without it, terraform apply succeeds but the
# ingress controller loops on "WillNotConfigureFrontend" and :443 never opens.
#
# Migrating an ALREADY-APPLIED HTTP-only install to this: the existing
# ephemeral ingress IP can't be promoted to static in-place (a plain
# `gcloud compute addresses create --addresses <existing-ip>` 409s — "already
# in use"). One-time runbook: delete the old HTTP-only forwarding rule to free
# the IP, then immediately reserve that same IP as static (brief downtime,
# DNS unaffected):
#   gcloud compute forwarding-rules delete <old-http-fr> --project=<p> --region=<r>
#   gcloud compute addresses create <name> --project=<p> --region=<r> \
#     --subnet=<subnet> --purpose=SHARED_LOADBALANCER_VIP --addresses=<existing-ip>
# then `terraform import google_compute_address.ingress[0] projects/<p>/regions/<r>/addresses/<name>`
# before applying, so Terraform adopts it instead of trying to create a
# duplicate. New installs need none of this — nothing pre-exists to conflict.

locals {
  # Gateway mode (gateway.tf) always pins the Gateway to this address, so the
  # IP and DNS stay put across applies and when switching from the Ingress.
  needs_static_ip = var.internal_ingress && (var.tls_mode != "none" || var.ingress_mode == "gateway")
}

resource "google_compute_address" "ingress" {
  count   = local.needs_static_ip && var.create_ingress_static_ip ? 1 : 0
  name    = var.ingress_static_ip_name
  project = var.project_id
  region  = local.region
  # NOT local.subnetwork_name directly: that local resolves via
  # google_compute_subnetwork.subnet, which only exists when deploy_cluster=
  # true (provisioning). This resource isn't gated by deploy_cluster at all
  # (needs_static_ip only cares about internal_ingress/tls_mode), so in the
  # default REUSE path (deploy_cluster=false) local.subnetwork_name would
  # resolve to null and fail. Mirror cluster.tf's own condition exactly.
  subnetwork   = var.deploy_cluster && var.create_network ? local.subnetwork_name : (var.subnetwork != "" ? var.subnetwork : null)
  address_type = "INTERNAL"
  purpose      = "SHARED_LOADBALANCER_VIP"

  # Reuse mode (deploy_cluster=false, the default) needs var.subnetwork
  # explicitly set — fail fast with a clear message instead of a cryptic GCP
  # API error on an empty subnetwork.
  lifecycle {
    precondition {
      condition     = (var.deploy_cluster && var.create_network) || var.subnetwork != ""
      error_message = "An ingress static IP (needed once tls_mode != \"none\", the default) requires var.subnetwork when reusing an existing cluster/network (deploy_cluster=false or create_network=false)."
    }
  }

  depends_on = [google_project_service.required]
}

# ── Destroy: wait for GKE to let go of the address ───────────────────────────
# The chart's Ingress (or Gateway) makes GKE build a load balancer whose
# forwarding rules hold this address and the proxy-only subnet. GKE deletes
# them itself, asynchronously, after the Ingress is gone, and only while the
# cluster still exists. A first destroy failed on exactly that: the release
# went, the cluster was deleted while GKE was still tearing the load balancer
# down, and the address and the proxy-only subnet were then "in use" by
# forwarding rules nothing would ever delete. A second destroy succeeded.
#
# This resource sits between the two on destroy: the release depends on it
# (main.tf), and it depends on the address, the proxy-only subnet and the
# cluster. So the release is destroyed first, then this waits until no
# forwarding rule holds the address any more, and only then do the cluster,
# the subnet and the address go. Nothing happens at create.
#
# It needs gcloud on the machine running the destroy (a prerequisite of this
# flavor anyway). Without gcloud, or after 10 minutes, it gives up and lets
# the destroy continue rather than blocking it; the README's "Tearing down"
# section has the manual cleanup.
resource "terraform_data" "ingress_lb_released" {
  count = local.needs_static_ip && var.create_ingress_static_ip ? 1 : 0

  input = {
    project = var.project_id
    address = google_compute_address.ingress[0].address
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      command -v gcloud >/dev/null 2>&1 || { echo "gcloud not found: not waiting for GKE to release ${self.input.address}"; exit 0; }
      err=$(mktemp); trap 'rm -f "$err"' EXIT
      for i in $(seq 1 60); do
        # A failed list (expired credentials, a network blip) is not "no rules
        # left": retry it rather than letting the destroy race GKE.
        if rules=$(gcloud compute forwarding-rules list --project "${self.input.project}" \
          --filter="IPAddress=${self.input.address}" --format="value(name)" 2>"$err"); then
          [ -z "$rules" ] && exit 0
          echo "waiting for GKE to delete the forwarding rule(s) on ${self.input.address} ($i/60): $(echo $rules)"
        else
          echo "gcloud could not list forwarding rules, retrying ($i/60): $(tail -n 1 "$err")"
        fi
        sleep 10
      done
      echo "forwarding rules still hold ${self.input.address} after 10 minutes; see gcp-gke/README.md, Tearing down"
    EOT
  }

  depends_on = [google_container_cluster.this, google_compute_subnetwork.proxy_only]
}
