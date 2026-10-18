# =============================================================================
# single-node-k3s flavor — input variables
# =============================================================================
# The simplest Marshal deployment: a single node already running k3s (BYO — the
# customer's GCP VM is the primary path), optional in-cluster Postgres/Redis, and
# the shared install module. Fill the REQUIRED block; the rest have safe defaults.
# =============================================================================


# ── Provision or reuse ───────────────────────────────────────────────────────
# deploy_cluster = false (default): install onto an EXISTING k3s node you already
#   run (BYO — the primary path), reached via kubeconfig_path below.
# deploy_cluster = true: provision a PRIVATE GCE VM (no public IP) + Cloud NAT and
#   install k3s on it (see "Provision a private GCE node" below). This is a
#   two-step flow: apply once to stand up the node, fetch its kubeconfig over IAP,
#   then apply again with deploy_cluster=false + kubeconfig_path to install Marshal
#   (a brand-new private node has no reachable kubeconfig for a single-apply
#   install). Outputs print the exact commands.

variable "deploy_cluster" {
  description = "false (default) = install onto an existing k3s node (kubeconfig_path). true = provision a private GCE VM running k3s (infra only; see the two-step note above)."
  type        = bool
  default     = false
}


# ── Cluster connection (used when deploy_cluster = false) ────────────────────

variable "kubeconfig_path" {
  description = "Path to a kubeconfig for the k3s node. On the node it is /etc/rancher/k3s/k3s.yaml (copy it out and rewrite the 127.0.0.1 server to the node's reachable IP). ~ is expanded."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context to use. \"\" uses the current-context."
  type        = string
  default     = ""
}


# ── Credentials from your Marshal onboarding (REQUIRED) ──────────────────────
# A Marshal operator mints these in the deployment-manager and sends them over a
# secure one-time channel. See README → "Get your credentials".

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
  description = "Registry pull token \"mrpt_…\" for pulling Marshal images + chart. From onboarding."
  type        = string
  sensitive   = true
}


# ── Product version + routing (REQUIRED) ─────────────────────────────────────

variable "chart_version" {
  description = "Marshal chart (== product) version to install, e.g. \"0.5.0\" (current). Bump + re-apply to upgrade."
  type        = string
}

variable "ingress_host" {
  description = "Hostname the console + API are served on, e.g. \"marshal.acme.com\". No real DNS? Use sslip.io against the node IP: \"marshal.203-0-113-5.sslip.io\" (dashes for dots)."
  type        = string
}

variable "extra_ingress_hosts" {
  description = "Extra hostnames routed to the same backends as ingress_host on the SAME Ingress — e.g. a Tailscale MagicDNS name alongside the primary public DNS name. Each needs its own DNS record pointing at the node. tls_mode=\"self_signed\"/\"inline\" fold these into the cert's SAN list automatically; tls_mode=\"secret\"/\"none\" — your responsibility / not applicable."
  type        = list(string)
  default     = []
  nullable    = false
}


# ── In-cluster datastores (default: provisioned for you) ─────────────────────
# k3s has no managed Postgres/Redis, so by default this flavor deploys a minimal
# postgres:16 + redis:7 into the cluster (local-path PVC for Postgres). Fine for a
# single-node / evaluation deployment. For a durable production datastore, set
# provision_datastores=false and supply your own DSNs below.

variable "provision_datastores" {
  description = "true = deploy in-cluster Postgres + Redis. false = you supply database_url + redis_url (managed/external)."
  type        = bool
  default     = true
}

variable "database_url" {
  description = "provision_datastores=false: full Postgres 16 DSN, e.g. \"postgres://marshal:PW@HOST:5432/marshal?sslmode=require\"."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redis_url" {
  description = "provision_datastores=false: full Redis 7 DSN, e.g. \"redis://HOST:6379\"."
  type        = string
  sensitive   = true
  default     = ""
}

variable "postgres_image" {
  description = "Image for the in-cluster Postgres (provision_datastores=true). Pulled from your `registry` prefix path automatically? No — this is a public image, pulled directly. Override to mirror it if your node has no public egress."
  type        = string
  default     = "postgres:16-alpine"
}

variable "redis_image" {
  description = "Image for the in-cluster Redis (provision_datastores=true)."
  type        = string
  default     = "redis:7-alpine"
}

variable "postgres_storage" {
  description = "PersistentVolumeClaim size for the in-cluster Postgres."
  type        = string
  default     = "10Gi"
}

variable "storage_class" {
  description = "StorageClass for the Postgres PVC. k3s ships \"local-path\" as the default. \"\" uses the cluster default."
  type        = string
  default     = "local-path"
}


# ── Registry posture ─────────────────────────────────────────────────────────
# Single node: simplest is direct pull from registry.marshal.codes with the pull
# token (the default). If you already run the shared pull-through cache, point
# image_cache_registry at it (and switch registry_auth_mode) so this install pulls
# from the cache instead of our rate-limited registry.

variable "image_cache_registry" {
  description = "Shared pull-through image cache endpoint (fronts registry.marshal.codes), e.g. \"harbor.acme.internal/marshal\". SHARED, ONE PER CUSTOMER: set up once and reuse across ALL your Marshal installs; NOT provisioned here. When set it becomes the image prefix for product + tool images. \"\" => direct pull via `registry`."
  type        = string
  default     = ""
  nullable    = false
}

variable "registry" {
  description = "Low-level image prefix used only when image_cache_registry is \"\". Direct pull (default): \"registry.marshal.codes/marshal\"."
  type        = string
  default     = "registry.marshal.codes/marshal"
}

variable "registry_auth_mode" {
  description = "\"secret\" (direct pull with the token, default), \"none\" (open in-network mirror), or \"workloadIdentity\"."
  type        = string
  default     = "secret"
}


# ── Ingress / TLS ────────────────────────────────────────────────────────────

variable "ingress_class_name" {
  description = "IngressClass. k3s bundles Traefik as \"traefik\" (default)."
  type        = string
  default     = "traefik"
}

variable "ingress_annotations" {
  description = "Extra Ingress annotations (e.g. a cert-manager cluster-issuer)."
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
# Traefik (k3s's bundled ingress) has no static-IP requirement like GKE's
# gce-internal class, so unlike the gcp-gke flavor there's nothing else to
# wire up here — just these four pass-through variables.
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


# ── Provision a private GCE node (only when deploy_cluster = true) ───────────
# Stands up a VM running k3s. Default: private (no public IP), Cloud NAT for egress
# (image pulls from registry.marshal.codes, license/token hosts); access over IAP.
# public_ip = true instead gives it a static external IP that serves the app.
# Every variable here is ignored when deploy_cluster = false.

variable "project_id" {
  description = "GCP project to create the VM in. REQUIRED when deploy_cluster=true."
  type        = string
  default     = ""
}

variable "zone" {
  description = "GCE zone for the VM, e.g. \"europe-west1-b\". REQUIRED when deploy_cluster=true."
  type        = string
  default     = ""
}

variable "machine_type" {
  description = "VM machine type. Default e2-standard-4 (4 vCPU / 16 GB) runs k3s + the control plane + a few session pods."
  type        = string
  default     = "e2-standard-4"
}

variable "boot_disk_size_gb" {
  description = "VM boot disk size (GB) — holds images + local-path PVs."
  type        = number
  default     = 100
}

variable "boot_disk_type" {
  description = "VM boot disk type: pd-balanced (default), pd-ssd, pd-standard."
  type        = string
  default     = "pd-balanced"
}

variable "vm_image" {
  description = "Boot image (family or self-link). Default is Debian 12."
  type        = string
  default     = "projects/debian-cloud/global/images/family/debian-12"
}

variable "create_network" {
  description = "true (default) = create a dedicated VPC + subnet for the node. false = reuse existing network/subnetwork (set them below)."
  type        = bool
  default     = true
}

variable "network" {
  description = "create_network=false: existing VPC name (or self-link)."
  type        = string
  default     = ""
}

variable "subnetwork" {
  description = "create_network=false: existing subnet name (or self-link) in the zone's region."
  type        = string
  default     = ""
}

variable "subnet_cidr" {
  description = "create_network=true: CIDR of the created subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "create_nat" {
  description = "Create a Cloud Router + Cloud NAT for the private node's egress. true (default). Set false only if the reused network already has NAT."
  type        = bool
  default     = true
}

variable "admin_source_ranges" {
  description = "CIDRs allowed to reach the node's k3s API (tcp/6443) and SSH (tcp/22) — your admin/VPN/bastion ranges. IAP's range (35.235.240.0/20) is always allowed for IAP SSH. Example: [\"10.8.0.0/24\"]."
  type        = list(string)
  default     = []
}

variable "public_ip" {
  description = "false (default) = private node, egress via Cloud NAT, no inbound from the internet. true = reserve a STATIC external IP for the node and open tcp/80+443 to public_http_source_ranges, so Traefik serves the app straight from the node (no load balancer). k3s API (6443) and SSH stay limited to IAP + admin_source_ranges either way. The static IP keeps billing while the VM is stopped."
  type        = bool
  default     = false
}

variable "public_http_source_ranges" {
  description = "public_ip=true: CIDRs allowed to reach tcp/80+443 on the node. Default: the whole internet."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_service_account_email" {
  description = "Service account for the VM. \"\" (default) = the project's default compute SA with default scopes (today's behaviour). Set it to give the node a dedicated identity (runs with the cloud-platform scope; grant it only what it needs)."
  type        = string
  default     = ""
}

variable "k3s_channel" {
  description = "k3s release channel passed to the installer (INSTALL_K3S_CHANNEL), e.g. \"stable\" (default) or a pinned version like \"v1.29\"."
  type        = string
  default     = "stable"
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
  description = "Relay endpoint. \"\" => chart default (https://hooks.marshal.codes). Only used when webhook_relay_enabled = true. Needs outbound 443 from the node to whichever host this resolves to."
  type        = string
  default     = ""
  nullable    = false
}

variable "auth_broker_url" {
  description = "Turns on Settings > Slack by setting the broker's bare origin, e.g. \"https://auth.marshal.codes\". \"\" (default) => disabled. Requires installation_jwt. Needs outbound 443 from the node to whichever host this points at."
  type        = string
  default     = ""
  nullable    = false
}


# ── Escape hatch ─────────────────────────────────────────────────────────────

variable "values_overrides" {
  description = "Extra raw values-YAML documents merged last into the chart (e.g. resources, autoscaling, api.extraEnv). Each item a YAML string."
  type        = list(string)
  default     = []
}
