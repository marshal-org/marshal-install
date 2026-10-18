# GCE node running k3s — ALL gated on deploy_cluster=true (count = 0
# otherwise, so the reuse path creates none of it). By default the node has no
# public IP; Cloud NAT provides egress for image pulls (registry.marshal.codes)
# and the license/token hosts. public_ip = true gives it a static external IP
# instead (then create_nat can be false). Reach the node over IAP. This provisions INFRA ONLY — after
# the node is up, fetch its kubeconfig and run a second apply with
# deploy_cluster=false to install Marshal (see outputs + README).

locals {
  do_provision = var.deploy_cluster

  # Region for the router/NAT/subnet, derived from the zone (e.g. europe-west1-b
  # -> europe-west1).
  gce_region = var.zone != "" ? join("-", slice(split("-", var.zone), 0, 2)) : ""

  gce_network    = var.create_network ? one(google_compute_network.vpc[*].name) : var.network
  gce_subnetwork = var.create_network ? one(google_compute_subnetwork.subnet[*].name) : var.subnetwork

  # k3s installer: write a group-readable kubeconfig and add the node's internal IP
  # as a TLS SAN so the copied-out kubeconfig validates against the private IP.
  k3s_startup = <<-EOS
    #!/bin/bash
    set -euxo pipefail
    IP=$(hostname -I | awk '{print $1}')
    curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${var.k3s_channel}" sh -s - \
      --write-kubeconfig-mode 644 --tls-san "$IP"
  EOS
}

# ── VPC + subnet (create_network = true) ─────────────────────────────────────
resource "google_compute_network" "vpc" {
  count                   = local.do_provision && var.create_network ? 1 : 0
  name                    = "${var.release_name}-k3s-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  count                    = local.do_provision && var.create_network ? 1 : 0
  name                     = "${var.release_name}-k3s-subnet"
  project                  = var.project_id
  region                   = local.gce_region
  network                  = google_compute_network.vpc[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# ── Cloud Router + NAT — egress for the private node ─────────────────────────
resource "google_compute_router" "router" {
  count   = local.do_provision && var.create_nat ? 1 : 0
  name    = "${var.release_name}-k3s-router"
  project = var.project_id
  region  = local.gce_region
  network = local.gce_network
}

resource "google_compute_router_nat" "nat" {
  count                              = local.do_provision && var.create_nat ? 1 : 0
  name                               = "${var.release_name}-k3s-nat"
  project                            = var.project_id
  region                             = local.gce_region
  router                             = google_compute_router.router[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ── Firewall: IAP SSH always; k3s API + SSH from your admin ranges ───────────
resource "google_compute_firewall" "iap_ssh" {
  count     = local.do_provision ? 1 : 0
  name      = "${var.release_name}-k3s-iap-ssh"
  project   = var.project_id
  network   = local.gce_network
  direction = "INGRESS"
  # Google IAP forwarding range — lets you `gcloud compute ssh --tunnel-through-iap`.
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["marshal-k3s"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "admin" {
  count         = local.do_provision && length(var.admin_source_ranges) > 0 ? 1 : 0
  name          = "${var.release_name}-k3s-admin"
  project       = var.project_id
  network       = local.gce_network
  direction     = "INGRESS"
  source_ranges = var.admin_source_ranges
  target_tags   = ["marshal-k3s"]
  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }
}

# ── Public ingress (public_ip = true) ────────────────────────────────────────
# A static address, so DNS stays valid across VM stop/start (an ephemeral IP
# would change on every start).
resource "google_compute_address" "node" {
  count   = local.do_provision && var.public_ip ? 1 : 0
  name    = "${var.release_name}-k3s"
  project = var.project_id
  region  = local.gce_region
}

resource "google_compute_firewall" "public_http" {
  count         = local.do_provision && var.public_ip ? 1 : 0
  name          = "${var.release_name}-k3s-http-https"
  project       = var.project_id
  network       = local.gce_network
  direction     = "INGRESS"
  source_ranges = var.public_http_source_ranges
  target_tags   = ["marshal-k3s"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

# ── The node ─────────────────────────────────────────────────────────────────
resource "google_compute_instance" "node" {
  count        = local.do_provision ? 1 : 0
  name         = "${var.release_name}-k3s"
  project      = var.project_id
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["marshal-k3s"]

  boot_disk {
    initialize_params {
      image = var.vm_image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    network    = local.gce_network
    subnetwork = local.gce_subnetwork
    # No access_config => no external IP (private node, the default). With
    # public_ip = true the node gets the reserved static address above.
    dynamic "access_config" {
      for_each = var.public_ip ? [1] : []
      content {
        nat_ip = google_compute_address.node[0].address
      }
    }
  }

  dynamic "service_account" {
    for_each = var.node_service_account_email != "" ? [1] : []
    content {
      email  = var.node_service_account_email
      scopes = ["cloud-platform"]
    }
  }

  metadata_startup_script = local.k3s_startup

  # Machine-type edits need a stop; let Terraform do it instead of failing.
  # (A boot-disk SIZE change still replaces the VM — resize with gcloud first.)
  allow_stopping_for_update = true

  # k3s needs egress via Cloud NAT (private node) before it can pull images.
  depends_on = [google_compute_router_nat.nat]
}
