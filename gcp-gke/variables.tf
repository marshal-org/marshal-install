# =============================================================================
# gcp-gke flavor — input variables
# =============================================================================
# Installs Marshal on GKE. Two postures via `deploy_cluster`:
#   • deploy_cluster = false (default) — reuse an EXISTING GKE cluster (BYO).
#   • deploy_cluster = true            — provision a PRIVATE GKE cluster (private
#     nodes + Cloud NAT egress + internal ingress), then install onto it.
# Datastore posture (recommended): external Cloud SQL Postgres + bundled Redis.
# Fill the REQUIRED block; the rest have GKE-appropriate defaults.
# =============================================================================


# ── GKE cluster to target (REQUIRED) ─────────────────────────────────────────
# Auth uses your Application Default Credentials: run
#   gcloud auth application-default login
# (or provide a service account on CI). Reuse needs container.clusters.get;
# provisioning needs container.admin + compute network admin on the project.

variable "project_id" {
  description = "GCP project the cluster lives in (reuse) or will be created in (provision)."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name — of your existing cluster (reuse) or the name to create (provision)."
  type        = string
  default     = "marshal"
}

variable "location" {
  description = "Cluster location: a region (\"europe-west1\") for a regional cluster or a zone (\"europe-west1-b\") for a zonal one. Also the default provider region."
  type        = string
}


# ── Credentials from your Marshal onboarding (REQUIRED) ──────────────────────
# See the top-level README → Credentials for what these are and where to get them.

variable "installation_jwt" {
  description = "Installation JWT (your license). From onboarding."
  type        = string
  sensitive   = true
}

variable "deployment_id" {
  description = "Deployment id, e.g. \"dep_ab12cd\". Also the registry pull username. From onboarding."
  type        = string
}

variable "registry_pull_token" {
  description = "Registry pull token \"mrpt_…\". From onboarding."
  type        = string
  sensitive   = true
}


# ── Product version + routing (REQUIRED) ─────────────────────────────────────

variable "chart_version" {
  description = "Marshal chart (== product) version, e.g. \"0.5.0\" (current). Bump + re-apply to upgrade."
  type        = string
}

variable "ingress_host" {
  description = "Hostname for the console + API, e.g. \"marshal.acme.com\". Marshal is internal-only by default (internal LB) — point this host's DNS at the internal ingress IP within your network."
  type        = string
}

variable "extra_ingress_hosts" {
  description = "Extra hostnames routed to the same backends as ingress_host on the SAME Ingress — e.g. a Tailscale MagicDNS name alongside the primary public DNS name. Each needs its own DNS record pointing at the ingress IP. tls_mode=\"self_signed\"/\"inline\" fold these into the cert's SAN list automatically; tls_mode=\"secret\"/\"none\" — your responsibility / not applicable."
  type        = list(string)
  default     = []
  nullable    = false
}


# ── Datastores — Postgres + Redis toggled INDEPENDENTLY ──────────────────────
# Recommended: external Postgres (Cloud SQL — durable source of truth) + bundled
# Redis (in-cluster; Redis holds only ephemeral/reconstructible state, so managed
# Redis is an unnecessary cost). Reach Cloud SQL over the VPC (private IP).

variable "database_mode" {
  description = "Postgres source: \"external\" (RECOMMENDED — supply database_url; Cloud SQL) or \"bundled\" (in-cluster, demo/eval only)."
  type        = string
  default     = "external"
}

variable "redis_mode" {
  description = "Redis source: \"bundled\" (DEFAULT — in-cluster; all Redis state is ephemeral) or \"external\" (supply redis_url; Memorystore)."
  type        = string
  default     = "bundled"
}

variable "database_url" {
  description = "database_mode=\"external\": full Postgres 16 DSN, e.g. \"postgres://marshal:PW@10.20.0.5:5432/marshal?sslmode=require\" (Cloud SQL private IP). Leave \"\" only when database_mode=\"bundled\"."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redis_url" {
  description = "redis_mode=\"external\": full Redis 7 DSN, e.g. \"redis://10.30.0.4:6379\" (Memorystore private IP). Ignored (leave \"\") when redis_mode=\"bundled\"."
  type        = string
  sensitive   = true
  default     = ""
}


# ── Provision a private cluster (only when deploy_cluster = true) ─────────────
# Marshal runs on your INTERNAL network and is not exposed to the internet, so a
# provisioned cluster is private by default: private nodes (no public IPs), a
# locked-down control plane, an internal load balancer — with Cloud NAT for the
# egress Marshal needs (image pulls from registry.marshal.codes, license/token
# hosts). Reuse (deploy_cluster=false) ignores every variable in this section.

variable "deploy_cluster" {
  description = "false (default) = reuse the existing cluster named above. true = provision a new private GKE cluster, then install onto it."
  type        = bool
  default     = false
}

# -- Networking --
variable "create_network" {
  description = "true (default) = create a dedicated VPC + subnet (with secondary ranges for pods/services). false = reuse an existing VPC/subnet (set network, subnetwork, and the range names below to match it)."
  type        = bool
  default     = true
}

variable "network" {
  description = "create_network=false: name (or self-link) of the existing VPC to place the cluster in."
  type        = string
  default     = ""
}

variable "subnetwork" {
  description = "create_network=false: name (or self-link) of the existing subnet (in `location`'s region) for the nodes."
  type        = string
  default     = ""
}

variable "subnet_cidr" {
  description = "create_network=true: primary CIDR of the created node subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_range_name" {
  description = "Name of the subnet secondary range for Pods (VPC-native). create_network=true creates it; create_network=false must match an existing secondary range on your subnet."
  type        = string
  default     = "marshal-pods"
}

variable "services_range_name" {
  description = "Name of the subnet secondary range for Services. create_network=true creates it; create_network=false must match an existing one."
  type        = string
  default     = "marshal-services"
}

variable "pods_cidr" {
  description = "create_network=true: CIDR for the Pods secondary range (large — one IP block per node)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "create_network=true: CIDR for the Services secondary range."
  type        = string
  default     = "10.30.0.0/20"
}

# -- Private control plane --
variable "enable_private_endpoint" {
  description = "true (default) = the control-plane API endpoint is PRIVATE (reachable only from within the VPC / authorized networks) — run terraform + kubectl from inside the network (bastion, VPN, or a peered admin subnet). false = a PUBLIC endpoint still locked to master_authorized_networks (use when you administer from outside the VPC). Nodes are always private either way."
  type        = bool
  default     = true
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the control-plane API — your admin/bastion/VPN ranges. REQUIRED when deploy_cluster=true (an empty list would lock you out of a private endpoint). Example: [{ cidr_block = \"10.8.0.0/24\", display_name = \"admin-vpn\" }]."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "master_ipv4_cidr_block" {
  description = "A /28 for the Google-managed control plane's private endpoint. Must not overlap your other ranges."
  type        = string
  default     = "172.16.0.0/28"
}

# -- Node pool(s) --
# The control-plane pool (control_plane_*, further below) is a SEPARATE,
# dedicated pool for the long-lived api/gateway/web/marketplace/redis pods —
# it has its own chart-coupled taint/toleration wiring (taint_control_plane_
# pool) and never shares variables with the pools below.
#
# Everything that runs SESSION/SPACE workloads is `spaces_pools`: a map of
# however many pools you want (originally a single hardcoded "primary" pool;
# generalized so a customer can add e.g. a bigger-machine pool alongside the
# default one without a new variable per pool). Each entry becomes its own
# google_container_node_pool, named "<cluster_name>-<key>-pool" and labeled
# workload=<key> — so pod scheduling/observability by pool stays meaningful
# with an arbitrary number of entries, not just the original two.

variable "spaces_pools" {
  description = <<-EOT
    Session/space-workload node pools, keyed by a short pool-name suffix
    (used in the pool's GCP name and its workload=<key> node label). Default
    is a single "spaces" entry matching this variable's pre-generalization
    defaults (e2-standard-4, 100GB, autoscaling 1-5/zone) — an install that
    sets nothing here still gets the same single-pool behavior as before.

    Add more entries for more pools (e.g. a "big" pool with a larger
    machine_type) — each is untainted by default (taint=false), so it's just
    extra capacity any spaces pod can land on by ordinary scheduling. Set
    taint=true only if you're scheduling something onto it some other way
    (manual nodeSelector/toleration) — there's no chart-side wiring that
    tolerates a spaces_pools taint automatically (unlike control-plane's).

    pool_name overrides the GCP node pool name (default
    "<cluster_name>-<key>-pool"). GKE node pool `name` is IMMUTABLE — a
    mismatch forces destroy+recreate of a live pool, not an in-place rename.
    Only needed when migrating an existing pool whose real name predates
    this key (e.g. the original single-pool installs' "<cluster_name>-pool",
    with no pool-name suffix) into spaces_pools — set pool_name to the
    existing live name so the map key can be anything without forcing a
    replace. New pools/customers never need this.

    spot = true puts the pool on Spot VMs: much cheaper, but GKE can reclaim a
    node at any time and the spaces on it restart. Meant for test and
    development clusters. Marking an EXISTING pool spot replaces the pool
    (destroy + create), so set it when the pool is first created. The
    control-plane pool never uses Spot.
  EOT
  type = map(object({
    machine_type   = string
    disk_size_gb   = number
    disk_type      = optional(string, "pd-balanced")
    node_count     = optional(number) # null (default) = autoscaling
    min_node_count = optional(number, 1)
    max_node_count = optional(number, 5)
    taint          = optional(bool, false)
    pool_name      = optional(string) # see description above
    spot           = optional(bool, false)
  }))
  default = {
    spaces = {
      machine_type = "e2-standard-4"
      disk_size_gb = 100
    }
  }
}

# ── Image pulls on fresh nodes ───────────────────────────────────────────────
# A node the autoscaler just added has an empty image cache, so the first space
# on it waits for every tool image to download before it starts. Both settings
# below are off unless set, and apply only to the pools this flavor creates
# (deploy_cluster = true).

variable "image_streaming_enabled" {
  description = <<-EOT
    Turn on GKE image streaming on every node pool this flavor creates (space
    pools and the control-plane pool), and enable the Container File System
    API it needs (containerfilesystem.googleapis.com; never disabled again by
    this flavor). Containers start before their images are fully downloaded,
    which shortens space start on a freshly added node.

    Requires GKE 1.30.1-gke.1329000 or later and the default COS_CONTAINERD
    node image (this flavor never sets another one). Images must come from
    Artifact Registry, which the default registry cache already does. If you
    set node_service_account to a custom SA, grant it
    roles/serviceusage.serviceUsageConsumer on this project. If a VPC Service
    Controls perimeter protects the project, add containerfilesystem.googleapis.com
    to it.

    Turning this on for a running install makes GKE replace the nodes of every
    pool it touches without waiting for a maintenance window; spaces on them
    restart. Setting it back to false does not turn streaming off on existing
    pools (GKE keeps the live value): run
    `gcloud container node-pools update <pool> --cluster <cluster> --location <location> --no-enable-image-streaming`
    for that. No effect when deploy_cluster = false.
  EOT
  type        = bool
  default     = false
}

variable "max_parallel_image_pulls" {
  description = <<-EOT
    How many images a node pulls at once (kubelet maxParallelImagePulls), on
    every node pool this flavor creates. 2 to 5. null (default) keeps GKE's own
    default (2 or 3, depending on the boot disk type). The kubelet pulls the
    images of ONE pod one after another whatever this is set to; the limit
    applies across pods. It helps when several spaces start on the same new
    node at once (a scale-up burst), not the start of a single space: for that,
    use image_streaming_enabled. A higher value means more disk and network
    I/O during the burst. Like any node_config
    change, setting or changing it replaces the nodes of every pool it
    touches. No effect when deploy_cluster = false.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.max_parallel_image_pulls == null || try(var.max_parallel_image_pulls >= 2 && var.max_parallel_image_pulls <= 5 && floor(var.max_parallel_image_pulls) == var.max_parallel_image_pulls, false)
    error_message = "max_parallel_image_pulls must be null or a whole number from 2 to 5 (GKE's allowed range)."
  }
}

variable "node_sysctls" {
  description = "Extra kernel sysctls applied to both node pools (linux_node_config.sysctls). Defaults raise fs.inotify limits generously — GKE's default (~8192-12288 watches) is easy to exhaust with a handful of file-watching containers sharing a node, and watches are cheap (~1KB kernel memory each) so a large headroom costs little. Changing this forces a rolling node replacement (same as any node_config change) — see gcp-gke/README.md's Day-2 notes before applying to an already-running pool with live sessions on it."
  type        = map(string)
  default = {
    "fs.inotify.max_user_watches"   = "1048576"
    "fs.inotify.max_user_instances" = "8192"
  }
}

# -- Control-plane node pool (separate from the spaces pool above) --
variable "control_plane_machine_type" {
  description = <<-EOT
    Machine type for the CONTROL-PLANE node pool (api/gateway/web/marketplace/
    redis only — never runs session workloads). Default e2-standard-8 (8 vCPU
    / 32 GB) — NOT e2-standard-2/4 despite control-plane pods needing "far
    less" than a session-hosting node: the chart's own baseline (autoscaling
    minReplicas=2 each for api/gateway/web/marketplace, values.yaml's
    `resources.*.requests`) already sums to ~4.4 vCPU of requests before HPA
    ever scales out further, which doesn't fit an e2-standard-4's ~3.9 vCPU
    allocatable (confirmed live: e2-standard-2 left pods permanently Pending
    on "Insufficient cpu"). The real, correct distinction from the spaces
    pool is disk (control_plane_disk_size_gb, 50GB vs. 100GB) — control-plane
    has no per-session ephemeral-storage demand — not a smaller machine type.
  EOT
  type        = string
  default     = "e2-standard-8"
}

variable "control_plane_disk_size_gb" {
  description = "Control-plane pool node boot disk size (GB). No per-session ephemeral-storage demand here (unlike disk_size_gb, the spaces pool) — 50 is generous headroom for control-plane images/logs."
  type        = number
  default     = 50
}

variable "control_plane_disk_type" {
  description = "Control-plane pool node boot disk type."
  type        = string
  default     = "pd-balanced"
}

variable "control_plane_node_count" {
  description = "Fixed nodes per zone for the control-plane pool. null (default) = autoscaling."
  type        = number
  default     = null
}

variable "control_plane_min_node_count" {
  description = "Control-plane pool autoscaling floor (per zone)."
  type        = number
  default     = 1
}

variable "control_plane_max_node_count" {
  description = "Control-plane pool autoscaling ceiling (per zone). Small on purpose — this pool never scales with session count."
  type        = number
  default     = 2
}

variable "taint_control_plane_pool" {
  description = <<-EOT
    Taint the control-plane pool NoSchedule (key=workload, value=control-plane)
    AND set the module's control_plane_node_selector/tolerations to match
    (see main.tf) -- both derive from this ONE toggle so the taint and the
    matching chart toleration always land in the SAME apply. DEFAULT FALSE.

    Still requires the Marshal chart to already be running a
    version with controlPlane.nodeSelector/tolerations wiring (>= 0.9.0)
    BEFORE this is ever set true -- an older chart version ignores those
    values entirely, so its control-plane pods would carry no toleration
    and become unschedulable the moment the taint lands (an outage). Bump
    chart_version to >= 0.9.0 first, confirm it's healthy, THEN flip this.
  EOT
  type        = bool
  default     = false
}

variable "node_pool_max_surge" {
  description = "Extra nodes created (beyond your steady-state count) during a rolling node pool update. 0 (default, safer for tight CPU quota) replaces nodes one at a time in place; GKE's own default is 1, which needs quota headroom for a whole extra node."
  type        = number
  default     = 0
}

variable "node_pool_max_unavailable" {
  description = "Nodes taken offline at once during a rolling node pool update. 1 (default) pairs with max_surge=0 for a true one-at-a-time in-place replacement."
  type        = number
  default     = 1
}

variable "release_channel" {
  description = "GKE release channel: RAPID | REGULAR (default) | STABLE. Controls the auto-upgrade cadence."
  type        = string
  default     = "REGULAR"
}

variable "kubernetes_version" {
  description = "Optional control-plane version pin (min_master_version), e.g. \"1.29\". null (default) tracks the release channel."
  type        = string
  default     = null
}

variable "node_service_account" {
  description = "Email of the IAM service account for the nodes. \"\" (default) uses the project's default compute SA. For least privilege, pass a dedicated SA with only logging/monitoring/AR-read roles."
  type        = string
  default     = ""
}


# ── Registry posture ─────────────────────────────────────────────────────────
# Default is direct pull from registry.marshal.codes with the token (works with
# Cloud NAT egress). RECOMMENDED at scale: a GCP Artifact Registry remote repo
# mirroring registry.marshal.codes + registry_auth_mode="workloadIdentity"
# (Workload Identity is enabled on the provisioned cluster) for keyless pulls.

variable "registry" {
  description = "Image registry prefix. Direct pull (default): \"registry.marshal.codes/marshal\". GCP AR remote-repo mirror: \"<region>-docker.pkg.dev/<project>/marshal-cache/marshal\"."
  type        = string
  default     = "registry.marshal.codes/marshal"
}

variable "tools_registry" {
  description = "Registry prefix for session/marketplace TOOL images (separate marshal-tools/* upstream namespace) — only needed if you're BYO-ing your own mirror (registry set by hand, create_registry_cache=false) and it doesn't follow the \"swap trailing /marshal for /marshal-tools\" convention. Ignored (computed automatically) when create_registry_cache=true."
  type        = string
  default     = ""
}

variable "registry_auth_mode" {
  description = "\"secret\" (direct pull with the token, default) or \"workloadIdentity\" (nodes pull via GKE Workload Identity from a cloud mirror — no in-cluster pull secret)."
  type        = string
  default     = "secret"
}


# ── Ingress / TLS ────────────────────────────────────────────────────────────
# Marshal is internal-only by default → an INTERNAL load balancer.

variable "internal_ingress" {
  description = "true (default) = internal load balancer (IngressClass \"gce-internal\") — reachable only inside your VPC, matching Marshal's internal-only model. false = external GCLB (uses ingress_class_name). Flip to false only if you deliberately expose Marshal."
  type        = bool
  default     = true
}

variable "ingress_class_name" {
  description = "IngressClass used when internal_ingress=false. \"gce\" (default) = external GKE Ingress; set your nginx class if you run ingress-nginx."
  type        = string
  default     = "gce"
}

variable "ingress_annotations" {
  description = <<-EOT
    Extra Ingress annotations. Common GKE ones:
      "kubernetes.io/ingress.regional-static-ip-name" = "marshal-ip"  # internal static IP
      "networking.gke.io/managed-certificates"        = "marshal-cert"
    Or with cert-manager: "cert-manager.io/cluster-issuer" = "letsencrypt".
  EOT
  type        = map(string)
  default     = {}
}

variable "ingress_tls" {
  description = "ADVANCED escape hatch — leave [] (default) and use tls_mode below instead. Non-empty always wins over tls_mode. Ingress TLS blocks: [{ hosts = [\"marshal.acme.com\"], secretName = \"marshal-tls\" }]."
  type = list(object({
    hosts      = list(string)
    secretName = string
  }))
  default = []
}

# HTTPS is the default posture (tls_mode="self_signed") — see
# modules/marshal-install/variables.tf for the full description of each mode.
# gce-internal (internal_ingress=true, the default) additionally needs a static
# IP to serve HTTP+HTTPS on one address once TLS is on — see create_ingress_
# static_ip below, auto-enabled alongside tls_mode.
variable "tls_mode" {
  description = "\"self_signed\" (DEFAULT, generates + manages a placeholder cert) | \"inline\" (tls_cert_pem/tls_key_pem) | \"secret\" (you manage the k8s Secret yourself, name it via tls_secret_name) | \"none\" (HTTP only)."
  type        = string
  default     = "self_signed"
}

variable "tls_cert_pem" {
  description = "PEM cert (tls_mode=\"inline\" only)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tls_key_pem" {
  description = "PEM private key (tls_mode=\"inline\" only)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tls_secret_name" {
  description = "Existing k8s TLS Secret name (tls_mode=\"secret\" only)."
  type        = string
  default     = "marshal-tls"
}

variable "create_ingress_static_ip" {
  description = "Reserve a static internal IP (Purpose=SHARED_LOADBALANCER_VIP) for the Ingress. Required by internal_ingress=true to serve HTTP+HTTPS on one address once tls_mode != \"none\" — without it the ingress controller loops on \"WillNotConfigureFrontend\" and never opens :443. Default true. Set false if you manage this IP yourself (e.g. terraform import an existing one under ingress_static_ip_name instead of creating it fresh)."
  type        = bool
  default     = true
}

variable "ingress_static_ip_name" {
  description = "Name for the reserved static IP (created when create_ingress_static_ip=true) or of an existing one to reference (create_ingress_static_ip=false)."
  type        = string
  default     = "marshal-ingress-ip"
}

variable "ingress_mode" {
  description = "\"ingress\" (default) = GKE Ingress (class gce-internal), as before. \"gateway\" = a Gateway API Gateway (class gateway_class_name) instead, which is what lets an INTERNAL load balancer use a Google-managed, auto-renewing certificate (see create_managed_certificate). Needs chart_version >= 0.27.0 and internal_ingress = true. Switching an existing install moves the load balancer: expect a few minutes without traffic on the same IP and DNS name. See gateway.tf."
  type        = string
  default     = "ingress"

  validation {
    condition     = contains(["ingress", "gateway"], var.ingress_mode)
    error_message = "ingress_mode must be \"ingress\" or \"gateway\"."
  }
}

variable "gateway_class_name" {
  description = "GatewayClass when ingress_mode = \"gateway\". \"gke-l7-rilb\" (default) = regional internal Application Load Balancer, reachable only inside your VPC."
  type        = string
  default     = "gke-l7-rilb"
}

variable "create_managed_certificate" {
  description = "ingress_mode = \"gateway\" only. true = create a Google-managed Certificate Manager certificate (regional, DNS-authorized) for ingress_host and, when set, *.preview_domain. Google issues and renews it. After the first apply, add the CNAME records from the managed_certificate_dns_records output, wait for managed_certificate_state = ACTIVE, then apply again: that apply moves HTTPS onto the managed certificate. Until then HTTPS serves the tls_mode certificate. extra_ingress_hosts are not on it. Needs the certificatemanager.googleapis.com API."
  type        = bool
  default     = false
}

variable "gateway_certificate_names" {
  description = "ingress_mode = \"gateway\" only. Certificate Manager certificates you already have (names, same project and region) for the HTTPS listener. Used together with the one create_managed_certificate makes. Empty (default) = HTTPS uses the tls_mode certificate."
  type        = list(string)
  default     = []
}

variable "preview_domain" {
  description = "Wildcard host for session port-previews, e.g. \"preview.acme.com\". \"\" disables previews."
  type        = string
  default     = ""
}

variable "preview_scheme" {
  description = "\"https\" or \"http\" for preview URLs."
  type        = string
  default     = "https"
}


# ── Release identity ─────────────────────────────────────────────────────────

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "marshal"
}

variable "namespace" {
  description = "Control-plane namespace."
  type        = string
  default     = "marshal"
}

variable "chart" {
  description = "Chart source. Default is the private OCI ref. Use a local path for pre-release testing."
  type        = string
  default     = "oci://registry.marshal.codes/marshal-charts/marshal"
}


# ── Webhook Relay + Auth Broker (both optional — chart default is OFF/empty) ──
# Both gate a whole route group in the api rather than erroring when left at
# their default: Settings > Webhooks / Settings > Slack 404 on every call with
# no other signal. Found live against a real deployment in August 2026, which
# is why they are called out here rather than left to discovery. Decide
# explicitly.

variable "webhook_relay_enabled" {
  description = "Turns on Settings > Webhooks. Requires installation_jwt (the Relay authenticates by installation identity)."
  type        = bool
  default     = false
  nullable    = false
}

variable "webhook_relay_url" {
  description = "Relay endpoint. \"\" => chart default (https://hooks.marshal.codes). Only used when webhook_relay_enabled = true. Needs outbound 443 from the cluster to whichever host this resolves to."
  type        = string
  default     = ""
  nullable    = false
}

variable "auth_broker_url" {
  description = "Turns on Settings > Slack by setting the broker's bare origin, e.g. \"https://auth.marshal.codes\". \"\" (default) => disabled. Requires installation_jwt. Needs outbound 443 from the cluster to whichever host this points at."
  type        = string
  default     = ""
  nullable    = false
}


# ── Escape hatch ─────────────────────────────────────────────────────────────

variable "values_overrides" {
  description = "Extra raw values-YAML documents merged last into the chart. Each item a YAML string."
  type        = list(string)
  default     = []
}


# ── Install mode ─────────────────────────────────────────────────────────────

variable "install_marshal" {
  description = <<-EOT
    true (default) = this apply installs Marshal with helm, as it always has.
    false = PROVISION ONLY: build the cluster, node pools, registry cache,
    buckets and static IP, but install nothing — something else (ArgoCD) owns
    the release. Mirrors single-node-k3s's provision-only path, except that one
    reuses deploy_cluster for the same purpose; here deploy_cluster already
    means "create the cluster", so the install needs its own switch.

    In this mode terraform still COMPUTES every GKE-derived chart value — read
    them with `terraform output -raw argocd_derived_values` and feed that into
    the ArgoCD Application. Do not retype them: the registry endpoints and the
    storage GSA email are derived, and a wrong supervisor annotation fails only
    at session runtime (see buckets.tf).
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "dns_endpoint_enabled" {
  description = <<-EOT
    Expose the control plane on its Google-managed DNS endpoint, reachable from
    anywhere and gated by the container.clusters.connect IAM permission instead
    of an IP allowlist. Lets an operator run kubectl without a bastion and
    without master_authorized_networks drifting open — the same trade
    one of our own internal clusters makes.
  EOT
  type        = bool
  default     = false
  nullable    = false
}
