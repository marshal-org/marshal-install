# Private GKE cluster provisioning — ALL of this is gated on deploy_cluster=true
# (count = 0 otherwise, so the reuse path creates none of it). Design goal:
# Marshal runs internal-only, so nodes are private (no public IPs), the control
# plane is locked to authorized networks, and Cloud NAT provides the egress the
# install needs (image pulls from registry.marshal.codes, license/token hosts).

locals {
  provision = var.deploy_cluster

  # GKE region for the router/NAT/subnet, derived from `location` whether it is a
  # region ("europe-west1") or a zone ("europe-west1-b").
  region = length(split("-", var.location)) == 3 ? join("-", slice(split("-", var.location), 0, 2)) : var.location

  # Network/subnet names handed to the cluster + router: created here, or the
  # existing ones the operator named. one() is null-safe over the count-0 side.
  network_name    = var.create_network ? one(google_compute_network.vpc[*].name) : var.network
  subnetwork_name = var.create_network ? one(google_compute_subnetwork.subnet[*].name) : var.subnetwork
}

# ── VPC + subnet (create_network = true) ─────────────────────────────────────
resource "google_compute_network" "vpc" {
  count                   = local.provision && var.create_network ? 1 : 0
  name                    = "${var.cluster_name}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  count                    = local.provision && var.create_network ? 1 : 0
  name                     = "${var.cluster_name}-subnet"
  project                  = var.project_id
  region                   = local.region
  network                  = google_compute_network.vpc[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true # nodes reach Google APIs without public IPs

  secondary_ip_range {
    range_name    = var.pods_range_name
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = var.services_range_name
    ip_cidr_range = var.services_cidr
  }
}

# ── Proxy-only subnet — REQUIRED for the internal Application Load Balancer ───
# GKE's internal L7 ILB (what IngressClass "gce-internal" actually uses) needs a
# dedicated purpose=REGIONAL_MANAGED_PROXY subnet in the region — NOT the same
# thing as the node subnet above. Without it the Ingress never gets an address
# (confirmed live: 55+ minutes, zero events, no address). Only needed for
# internal_ingress=true; the external "gce" IngressClass doesn't require one.
variable "proxy_only_subnet_cidr" {
  description = "CIDR for the regional proxy-only subnet the internal ALB needs. /23 is Google's recommended minimum."
  type        = string
  default     = "10.40.0.0/23"
}

resource "google_compute_subnetwork" "proxy_only" {
  count         = local.provision && var.create_network && var.internal_ingress ? 1 : 0
  name          = "${var.cluster_name}-proxy-only"
  project       = var.project_id
  region        = local.region
  network       = google_compute_network.vpc[0].id
  ip_cidr_range = var.proxy_only_subnet_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# ── Cloud Router + Cloud NAT — REQUIRED egress for private nodes ──────────────
# Without NAT, private nodes cannot reach registry.marshal.codes and the install
# fails on image pulls. On by default when provisioning; set create_nat=false only
# if the (reused) network already has NAT covering this subnet.
variable "create_nat" {
  description = "Create a Cloud Router + Cloud NAT for private-node egress. true (default). Set false only when reusing a network that already provides NAT for the subnet."
  type        = bool
  default     = true
}

resource "google_compute_router" "router" {
  count   = local.provision && var.create_nat ? 1 : 0
  name    = "${var.cluster_name}-router"
  project = var.project_id
  region  = local.region
  network = local.network_name
}

resource "google_compute_router_nat" "nat" {
  count                              = local.provision && var.create_nat ? 1 : 0
  name                               = "${var.cluster_name}-nat"
  project                            = var.project_id
  region                             = local.region
  router                             = google_compute_router.router[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ── Private cluster ──────────────────────────────────────────────────────────
variable "deletion_protection" {
  description = "GKE deletion protection. true (default) guards a real cluster from `terraform destroy`; set false for disposable test clusters."
  type        = bool
  default     = true
}

resource "google_container_cluster" "this" {
  count    = local.provision ? 1 : 0
  name     = var.cluster_name
  location = var.location
  project  = var.project_id

  network    = local.network_name
  subnetwork = local.subnetwork_name

  # Run a separately-managed node pool (below), not the default one.
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Private nodes; control-plane endpoint private (or public-but-authorized).
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = var.enable_private_endpoint
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # IAM-gated DNS endpoint (container.clusters.connect), the one control-plane
  # path that needs neither a bastion nor an allowlist re-applied every time the
  # operator's IP moves. The block is absent unless asked for, so the live
  # customer clusters plan no change.
  #
  # Deliberately does NOT turn the IP endpoint off, even though that would be
  # stricter: doing so makes GKE derive enable_private_endpoint = true, which
  # every later plan then wants to strip back to null. One of our own internal
  # clusters carries that scar: it has to declare the derived value to stop it.
  dynamic "control_plane_endpoints_config" {
    for_each = var.dns_endpoint_enabled ? [1] : []
    content {
      dns_endpoint_config {
        allow_external_traffic = true
      }
    }
  }

  # Keyless GCP/AR auth — pairs with registry_auth_mode = "workloadIdentity".
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # REQUIRED for the module's Ingress (internal_ingress / ingress_class_name =
  # "gce"/"gce-internal") to work at all — without this, no IngressClass exists
  # in the cluster and every Ingress object silently sits with no controller
  # watching it (0 events, no address, forever). Confirmed live: a customer POC
  # install's Ingress never got an IP after 55+ minutes because this wasn't set
  # and the GKE API's default for newly-created clusters is disabled, not the
  # classic assumed-enabled default.
  addons_config {
    http_load_balancing {
      disabled = false
    }
  }

  release_channel {
    channel = var.release_channel
  }

  # The Gateway CRDs and GatewayClasses (gke-l7-rilb, ...) exist only with the
  # Gateway API turned on. Only in gateway mode, so ingress installs plan no
  # change to their cluster.
  dynamic "gateway_api_config" {
    for_each = var.ingress_mode == "gateway" ? ["standard"] : []
    content {
      channel = "CHANNEL_STANDARD"
    }
  }
  min_master_version  = var.kubernetes_version
  deletion_protection = var.deletion_protection

  depends_on = [google_compute_router_nat.nat]
}

# ── Image streaming API (image_streaming_enabled = true) ──────────────────────
# The pools need the Container File System API before GKE can stream to them.
# Never disabled by this flavor: something else in the project may use it.
resource "google_project_service" "containerfilesystem" {
  count              = local.provision && var.image_streaming_enabled ? 1 : 0
  project            = var.project_id
  service            = "containerfilesystem.googleapis.com"
  disable_on_destroy = false
}

# ── Node pools ───────────────────────────────────────────────────────────────
# "spaces_pools" (below) is a map of however many SESSION/SPACE-workload
# pools a customer wants — one google_container_node_pool per entry, named
# "<cluster_name>-<key>-pool" and labeled workload=<key>. "control_plane"
# (further below) stays a separate, dedicated resource — it has its own
# chart-coupled taint/toleration wiring (taint_control_plane_pool) that
# nothing here shares. Both exist unconditionally when deploy_cluster=true;
# whether control-plane's split actually ISOLATES anything depends on
# taint_control_plane_pool — see that variable before flipping it.
#
# moved blocks at the bottom of this file carry existing customers' state
# from the original hardcoded "primary"/"big" resource addresses to this
# for_each form without a destroy/recreate.
resource "google_container_node_pool" "spaces" {
  for_each = local.provision ? var.spaces_pools : {}

  depends_on = [google_project_service.containerfilesystem]

  name     = coalesce(each.value.pool_name, "${var.cluster_name}-${each.key}-pool")
  cluster  = google_container_cluster.this[0].name
  location = var.location
  project  = var.project_id
  version  = var.kubernetes_version

  # Fixed size, or autoscaling when node_count is null.
  node_count = each.value.node_count

  dynamic "autoscaling" {
    for_each = each.value.node_count == null ? toset(["autoscale"]) : toset([])
    content {
      min_node_count = each.value.min_node_count
      max_node_count = each.value.max_node_count
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # GKE's own default (max_surge=1, max_unavailable=0) needs headroom for a
  # WHOLE EXTRA node beyond your steady-state count during any rolling update
  # (disk/machine_type change, auto_upgrade, etc.) — confirmed live: a disk
  # resize on a 3-node e2-standard-8 pool hit "Quota 'CPUS_ALL_REGIONS'
  # exceeded (Limit: 32)" because the surge node needed 8 more vCPU than the
  # 25/32 already in use. max_surge=0/max_unavailable=1 replaces nodes ONE AT
  # A TIME in place instead (briefly fewer nodes, never more), which fits
  # inside whatever quota you already have. Change only if you know you have
  # comfortable CPU quota margin.
  upgrade_settings {
    max_surge       = var.node_pool_max_surge
    max_unavailable = var.node_pool_max_unavailable
  }

  node_config {
    machine_type    = each.value.machine_type
    disk_size_gb    = each.value.disk_size_gb
    disk_type       = each.value.disk_type
    service_account = var.node_service_account != "" ? var.node_service_account : null
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = { "workload" = each.key }
    spot            = each.value.spot

    linux_node_config {
      sysctls = var.node_sysctls
    }

    # Opt-in (image_streaming_enabled / max_parallel_image_pulls). Rendered
    # only when set: both are Computed in the provider, so an absent block
    # leaves existing pools untouched.
    dynamic "gcfs_config" {
      for_each = var.image_streaming_enabled ? [1] : []
      content {
        enabled = true
      }
    }

    dynamic "kubelet_config" {
      for_each = var.max_parallel_image_pulls != null ? [1] : []
      content {
        max_parallel_image_pulls = var.max_parallel_image_pulls
      }
    }

    dynamic "taint" {
      for_each = each.value.taint ? [1] : []
      content {
        key    = "workload"
        value  = each.key
        effect = "NO_SCHEDULE"
      }
    }

    # Node-level Workload Identity + hardening.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

resource "google_container_node_pool" "control_plane" {
  count = local.provision ? 1 : 0

  depends_on = [google_project_service.containerfilesystem]

  name     = "${var.cluster_name}-control-plane-pool"
  cluster  = google_container_cluster.this[0].name
  location = var.location
  project  = var.project_id
  version  = var.kubernetes_version

  node_count = var.control_plane_node_count

  dynamic "autoscaling" {
    for_each = var.control_plane_node_count == null ? toset(["autoscale"]) : toset([])
    content {
      min_node_count = var.control_plane_min_node_count
      max_node_count = var.control_plane_max_node_count
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = var.node_pool_max_surge
    max_unavailable = var.node_pool_max_unavailable
  }

  node_config {
    machine_type    = var.control_plane_machine_type
    disk_size_gb    = var.control_plane_disk_size_gb
    disk_type       = var.control_plane_disk_type
    service_account = var.node_service_account != "" ? var.node_service_account : null
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = { "workload" = "control-plane" }

    linux_node_config {
      sysctls = var.node_sysctls
    }

    # Same opt-ins as the spaces pools (see there). Never Spot.
    dynamic "gcfs_config" {
      for_each = var.image_streaming_enabled ? [1] : []
      content {
        enabled = true
      }
    }

    dynamic "kubelet_config" {
      for_each = var.max_parallel_image_pulls != null ? [1] : []
      content {
        max_parallel_image_pulls = var.max_parallel_image_pulls
      }
    }

    # DEFAULT FALSE — see taint_control_plane_pool's description. An empty
    # dynamic block means no taint at all: this pool behaves like any other
    # untainted pool until deliberately flipped on.
    dynamic "taint" {
      for_each = var.taint_control_plane_pool ? [1] : []
      content {
        key    = "workload"
        value  = "control-plane"
        effect = "NO_SCHEDULE"
      }
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}


# ── State migration: primary/big -> spaces_pools[*] ──────────────────────────
# 2026-09-10: generalized the old hardcoded "primary" (spaces) and "big"
# (opt-in third pool, itself only a few hours old at this point) resources
# into the spaces_pools for_each above. These moved blocks carry existing
# state to the new addresses instead of destroying+recreating live node
# pools. Customers must set spaces_pools with a "spaces" key (and "big" if
# they'd turned create_big_pool on) matching their old values for this to be
# a true no-op apply. Ask your Marshal contact for the worked example if you
# are migrating an existing pool.
moved {
  from = google_container_node_pool.primary[0]
  to   = google_container_node_pool.spaces["spaces"]
}

moved {
  from = google_container_node_pool.big[0]
  to   = google_container_node_pool.spaces["big"]
}
