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
}
