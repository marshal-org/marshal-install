# =============================================================================
# aws-eks flavor — input variables
# =============================================================================
# Installs Marshal onto EKS. Two postures via `deploy_cluster`:
#   • deploy_cluster = false (default) — reuse an EXISTING EKS cluster (BYO).
#   • deploy_cluster = true            — provision a private-endpoint-capable
#     EKS cluster (VPC + two node groups + OIDC/IRSA + EBS CSI + the AWS Load
#     Balancer Controller), then install onto it. Mirrors gcp-gke's toggle.
#
# Datastores: Postgres defaults to "external" (supply database_url — an RDS
# instance you already run) but, UNLIKE gcp-gke (which never provisions Cloud
# SQL), this flavor CAN also provision the RDS instance itself via
# create_rds=true (see database.tf) — new surface area beyond GCP parity,
# added deliberately for a from-scratch AWS account with nothing pre-existing.
# Redis stays bundled (in-cluster) by default either way.
# =============================================================================


# ── EKS cluster to target (REQUIRED) ─────────────────────────────────────────
# Auth uses your normal AWS credential chain (env vars, shared profile, an
# assumed role on CI, or IRSA if applying from within another cluster). Reuse
# needs eks:DescribeCluster plus enough Kubernetes RBAC on the target cluster
# (via EKS access entries or the legacy aws-auth ConfigMap) for this identity to
# create namespaces/secrets/the helm release.

variable "cluster_name" {
  description = "Name of your existing EKS cluster."
  type        = string
}

variable "region" {
  description = "AWS region the cluster lives in. Also the default provider region."
  type        = string
}


# ── Provision a cluster (instead of reusing one) ─────────────────────────────
# Mirrors gcp-gke's deploy_cluster toggle shape exactly.

variable "deploy_cluster" {
  description = "false (default) = reuse the existing cluster named above. true = provision a new EKS cluster (VPC, two node groups, OIDC/IRSA, EBS CSI addon, AWS Load Balancer Controller), then install onto it."
  type        = bool
  default     = false
}


# ── Networking (only used when deploy_cluster = true) ────────────────────────
# Marshal runs on your internal network — nodes are private (no public IPs),
# egress goes through a NAT gateway. UNLIKE gcp-gke's private-endpoint-by-
# default posture, the cluster's API endpoint defaults to PUBLIC (locked to
# cluster_endpoint_public_access_cidrs) — deliberately, because provisioning
# and installing happen in the SAME apply and there's often no pre-existing
# VPN/bastion into a brand-new AWS account yet. Flip cluster_endpoint_public_
# access to false once you have private access sorted (VPN/bastion/peering).

variable "create_network" {
  description = "true (default) = create a dedicated VPC + public/private subnets (one pair per AZ) + a NAT gateway. false = reuse a VPC you already run, by setting vpc_id + private_subnet_ids (+ public_subnet_ids for an internet-facing load balancer). The cluster, nodes, bastion and RDS are still created by this flavor; only the network is yours."
  type        = bool
  default     = true
}

# ── Reusing your own VPC (create_network = false) ────────────────────────────
# Why these are first-class inputs rather than an escape hatch: every one of
# them has a requirement EKS or the load balancer controller enforces silently
# (two AZs, a default route, the internal-elb tag), so they are validated by
# preconditions in main.tf rather than discovered during a 20-minute apply.
# scripts/preflight-aws.sh checks the same things read-only, before tfvars
# exist, which is the cheaper place to find them.

variable "vpc_id" {
  description = "VPC to install into, e.g. \"vpc-0a1b2c3d\". REQUIRED when create_network=false, ignored otherwise. Must be the VPC that owns every subnet below, which is checked at plan time."
  type        = string
  default     = ""
}

variable "private_subnet_ids" {
  description = "Private subnets for the nodes, the bastion and RDS. REQUIRED when create_network=false. At least two, in at least two different AZs, because EKS refuses a cluster otherwise. Each needs a default route (NAT, transit gateway or proxy) or nodes cannot pull images, and enough free IP addresses for your sessions, since the VPC CNI gives every pod a real subnet IP."
  type        = list(string)
  default     = []
}

variable "public_subnet_ids" {
  description = "Public subnets, used ONLY to give an internet-facing load balancer somewhere to live. Leave empty for the normal private posture: an internal ALB needs nothing here. Nodes are never placed in these."
  type        = list(string)
  default     = []
}

variable "tag_existing_subnets" {
  description = "true (default) = add the tags EKS and the AWS Load Balancer Controller need to the subnets you brought (kubernetes.io/role/internal-elb on private, kubernetes.io/role/elb on public, kubernetes.io/cluster/<cluster_name>=shared on both). Each tag is managed individually, so nothing else on your subnets is touched. Set false if your own IaC owns those subnets' tags, and add them yourself: without the role tag the Ingress never gets an address AND emits no events at all."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "CIDR for the created VPC."
  type        = string
  default     = "10.60.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread subnets/nodes across, when this flavor creates the network. Two is the cheapest EKS-legal minimum for a POC; add more for real HA. Empty (the default) takes the first two available AZs in var.region: the old default named eu-west-1 AZs, which is wrong in every other region and only shows up as an invalid-AZ error mid-apply."
  type        = list(string)
  default     = []
}

variable "single_nat_gateway" {
  description = "true (default) = one shared NAT gateway for all private subnets (cheaper; a single-AZ egress dependency). false = one NAT gateway per AZ (HA egress, roughly doubles NAT cost)."
  type        = bool
  default     = true
}

variable "cluster_endpoint_private_access" {
  description = "Nodes always reach the API server privately over the VPC. true (default), should stay true."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Whether the API server also has a public endpoint (still locked to cluster_endpoint_public_access_cidrs below). false (default) — matches GKE's private-only posture: Marshal runs on your internal network, not exposed to the internet. Reach a private-only cluster via the bastion this flavor provisions (create_bastion) — run terraform/kubectl/helm from there, same pattern gcp-gke's customer install used. Set true only if you deliberately want a public (still CIDR-locked) endpoint instead of using the bastion."
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint — your admin/CI egress ranges. REQUIRED (non-empty) whenever cluster_endpoint_public_access=true, or you lock yourself out. Example: [{ cidr_block = \"203.0.113.4/32\", display_name = \"admin\" }]."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "kubernetes_version" {
  description = "EKS control-plane version. EKS has no GKE-style release channel — this is a hard pin, bump it deliberately."
  type        = string
  default     = "1.36"
}

variable "service_ipv4_cidr" {
  description = "Kubernetes Service CIDR, pinned explicitly rather than left to AWS's VPC-CIDR-dependent default (10.100.0.0/16 or 172.20.0.0/16) — the optional Harbor cache (harbor.tf) needs to pick a static ClusterIP with certainty it falls inside the real range."
  type        = string
  default     = "172.20.0.0/16"
}

variable "cluster_private_access_cidrs" {
  description = <<-EOT
    Which address ranges may reach the private Kubernetes API endpoint on 443.

    EMPTY (default) means the VPC's own CIDR, which is what lets you run the whole
    install as one apply from anywhere that can already route into the VPC: a VPN, a
    Twingate or Tailscale connector, a jump host. Without it the apply creates every
    AWS resource and then fails on the first Kubernetes resource with an i/o timeout,
    because the EKS cluster security group admits only the nodes.

    This is not the same as a public endpoint. The endpoint has no public address
    unless you ask for one, and reaching it still needs an AWS identity with an EKS
    access entry and Kubernetes RBAC. Set this to narrow which ranges can connect,
    and include whatever range your tunnel presents.
  EOT
  type        = list(string)
  default     = []
}

variable "bastion_install_permissions" {
  description = <<-EOT
    What the bastion's IAM role may do. Only read when create_bastion = true.

    TRUE (default). AdministratorAccess, because the bastion runs the whole install:
    it creates the cluster, the IAM roles, the OIDC provider, the EKS addons and the
    database, and none of that is possible with a read-only role. Delete the bastion
    when the install is finished and the permission goes with it.

    FALSE. ReadOnlyAccess plus narrow grants for the state bucket, the OIDC thumbprint
    and ACM. Enough to finish the Kubernetes half of an install whose AWS half was
    already applied from another machine. Choose this only if your policy forbids an
    administrative instance, and expect to run the AWS half yourself.
  EOT
  type        = bool
  default     = true
}

variable "create_bastion" {
  description = <<-EOT
    Provision a small bastion EC2 instance to reach the private cluster endpoint from: no
    public IP, no inbound ports, reached only through AWS Systems Manager, so there is no SSH
    key to manage.

    FALSE (default). Most organisations running a private EKS cluster already reach their VPC
    through a VPN, Twingate, Tailscale, Direct Connect or an existing jump host. With any of
    those, install from wherever you normally work and every later upgrade is one command from
    the same place. A bastion you do not need is another host inside your VPC holding
    cluster-admin, which is a cost rather than a convenience.

    Set true only if you have NO path into the VPC. Then the bastion becomes the machine you
    install from, start to finish: see https://docs.marshal.codes/installing/eks

    Your access has to RESOLVE the endpoint, not just route to it. Its DNS is in a Route53
    private hosted zone on the VPC, so a tunnel that forwards packets but keeps your laptop's
    DNS cannot resolve the hostname. Check with `kubectl get nodes` before install day.
  EOT
  type        = bool
  default     = false
}

variable "bastion_instance_type" {
  description = "Bastion EC2 instance type. Tiny and cheap — it only runs terraform/kubectl/helm, no workload."
  type        = string
  default     = "t3.micro"
}

variable "bastion_ami_id" {
  description = "Pin the bastion's AMI to a specific ID instead of tracking \"most recent\" al2023 (the default data.aws_ami.al2023 lookup). Leave null to keep tracking most-recent; set once you have a live bastion so a routine plan/apply doesn't propose replacing it out from under an in-progress session."
  type        = string
  default     = null
}


# ── Node groups (only used when deploy_cluster = true) ───────────────────────
# TWO groups, same split as gcp-gke: "spaces" runs session/space workloads,
# "control_plane" is a separate, dedicated group for the long-lived
# api/gateway/web/marketplace/redis pods. Both created unconditionally when
# provisioning; taint_control_plane_pool controls whether the split actually
# ISOLATES anything.

variable "node_instance_types" {
  description = "EC2 instance type(s) for the SPACES node group. Default m5.xlarge (4 vCPU / 16 GB) — parity with gcp-gke's e2-standard-4 default."
  type        = list(string)
  default     = ["m5.xlarge"]
}

variable "node_disk_size_gb" {
  description = "Spaces node group boot disk size (GB). Sized for session ephemeral-storage demand, same as gcp-gke's disk_size_gb."
  type        = number
  default     = 100
}

variable "node_desired_size" {
  description = "Spaces node group desired node count."
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = "Spaces node group autoscaling floor."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Spaces node group autoscaling ceiling."
  type        = number
  default     = 5
}

variable "control_plane_instance_types" {
  description = <<-EOT
    EC2 instance type(s) for the CONTROL-PLANE node group (api/gateway/web/
    marketplace/redis only — never session workloads). Default m5.2xlarge (8
    vCPU / 32 GB) — NOT smaller, for the exact reason gcp-gke's equivalent
    default (e2-standard-8) isn't smaller either: the chart's own baseline
    (autoscaling minReplicas=2 each for api/gateway/web/marketplace) already
    sums to ~4.4 vCPU of requests before any HPA scale-out, which a smaller
    instance can't allocate — confirmed live on the GCP side (e2-standard-2
    left pods permanently Pending on "Insufficient cpu"). Don't repeat that
    mistake here just because "control-plane needs less."
  EOT
  type        = list(string)
  default     = ["m5.2xlarge"]
}

variable "control_plane_disk_size_gb" {
  description = "Control-plane node group boot disk size (GB). No per-session ephemeral-storage demand here, unlike the spaces group."
  type        = number
  default     = 50
}

variable "control_plane_desired_size" {
  description = "Control-plane node group desired node count."
  type        = number
  default     = 1
}

variable "control_plane_min_size" {
  description = "Control-plane node group autoscaling floor."
  type        = number
  default     = 1
}

variable "control_plane_max_size" {
  description = "Control-plane node group autoscaling ceiling. Small on purpose — this group never scales with session count."
  type        = number
  default     = 2
}

variable "node_availability_zone" {
  description = "Pin BOTH node groups into one AZ, e.g. \"eu-west-1a\". \"\" (default) spreads them over every AZ in availability_zones. Pinning removes cross-AZ data transfer between the nodes, the ALB and RDS, which is the main per-GB charge in a steady-state install; the cost is that an AZ outage takes the whole deployment down rather than part of it. The cluster still needs subnets in at least two AZs (EKS requires it), so this only pins where nodes land. Changing it REPLACES both node groups, because a node group's subnets are immutable."
  type        = string
  default     = ""
}

variable "node_group_update_max_unavailable" {
  description = "Nodes taken offline at once during a rolling node group update. EKS has no max_surge=0 knob like GKE's (no way to force a true one-at-a-time in-place replacement without extra capacity) — this is the closest cost-conscious equivalent."
  type        = number
  default     = 1
}

variable "taint_control_plane_pool" {
  description = <<-EOT
    Taint the control-plane node group NoSchedule (key=workload, value=
    control-plane) AND set the module's control_plane_node_selector/
    tolerations to match (main.tf) — both derive from this ONE toggle so the
    taint and the matching chart toleration always land in the SAME apply.
    DEFAULT FALSE.

    Still requires the Marshal chart to already be running a
    version with controlPlane.nodeSelector/tolerations wiring (>= 0.9.0)
    BEFORE this is ever set true — an older chart version ignores those
    values entirely, so its control-plane pods would carry no toleration and
    become unschedulable the moment the taint lands (an outage). Confirm the
    chart version first, then flip this. Same chart-version-ordering gotcha
    already documented on gcp-gke's identical toggle.
  EOT
  type        = bool
  default     = false
}


# ── RDS Postgres (only used when deploy_cluster = true AND create_rds = true) ─
# UNLIKE gcp-gke (which never provisions Cloud SQL — "external" there only ever
# means "supply a DSN"), this flavor CAN also create the RDS instance itself.
# Small/cheap defaults below are POC sizing, not production sizing.

variable "create_rds" {
  description = "Provision a small RDS Postgres instance and use it as database_url automatically. false (default) — requires deploy_cluster=true (checked below)."
  type        = bool
  default     = false
}

variable "rds_instance_class" {
  description = "RDS instance class. db.t4g.micro (default) — cheapest Graviton burstable class, fine for POC write volume."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "RDS allocated storage (GB, gp3). 20 (default) is the smallest sensible size — gp3's baseline 3000 IOPS is plenty for a POC."
  type        = number
  default     = 20
}

variable "rds_engine_version" {
  description = "Postgres engine version. Must stay 16.x to match the chart's requirement."
  type        = string
  default     = "16.14"
}

variable "rds_backup_retention_period" {
  description = "Days of automated RDS backups. 1 (default) — short and cheap; this is a POC, not production."
  type        = number
  default     = 1
}

variable "rds_multi_az" {
  description = "Run the RDS instance across two AZs with a synchronous standby. false (default): Marshal is a developer tool, so an hour of downtime on its own database costs engineering time, not customer-facing availability, and Multi-AZ roughly doubles the instance bill. Turn it on only if you have decided that tradeoff differently."
  type        = bool
  default     = false
}

variable "rds_deletion_protection" {
  description = "Refuse to delete the RDS instance. true (default): this database holds the envelope-encrypted credential store and the audit trail, and deletion protection costs nothing. It also BLOCKS terraform destroy until you set this to false, which is the point."
  type        = bool
  default     = true
}

variable "rds_skip_final_snapshot" {
  description = "Skip the final snapshot when the instance is deleted. false (default): take one, because a snapshot is cents and an accidental destroy is the credential store. The snapshot is named <cluster_name>-postgres-final, so a second create/destroy cycle fails loudly on the duplicate name until you delete or rename the old snapshot. Set true only for a throwaway you intend to lose."
  type        = bool
  default     = false
}

variable "rds_db_name" {
  description = "Database name created on the RDS instance."
  type        = string
  default     = "marshal"
}

variable "rds_username" {
  description = "Master username created on the RDS instance."
  type        = string
  default     = "marshal"
}

variable "rds_extra_ingress_cidrs" {
  description = "Extra CIDR blocks allowed to reach the RDS security group on all ports, beyond the cluster nodes' own security group (which is always allowed). Use this to declare a real access path (e.g. a Tailscale subnet router) as first-class Terraform instead of an out-of-band SG rule that shows up as drift-to-remove on every refreshed plan. Empty (default) — no extra access."
  type        = list(string)
  default     = []
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
  description = "Marshal chart (== product) version, e.g. \"0.23.0\". Bump + re-apply to upgrade. There is no default on purpose: the version you install is the one you were issued."
  type        = string
}

variable "ingress_host" {
  description = "Hostname for the console + API, e.g. \"marshal.acme.com\". Marshal is internal-only by default (internal ALB) — point this host's DNS at the ALB's address within your network."
  type        = string
}

variable "extra_ingress_hosts" {
  description = "Extra hostnames routed to the same backends as ingress_host on the SAME Ingress/ALB — e.g. a Tailscale MagicDNS name alongside the primary public DNS name. Each needs its own DNS record pointing at the ALB. tls_mode=\"self_signed\" folds these into the generated ACM cert's SAN list automatically; tls_mode=\"inline\" must already cover them in the PEM you supply; tls_mode=\"secret\"/\"none\" — your responsibility / not applicable."
  type        = list(string)
  default     = []
  nullable    = false
}


# ── Datastores — Postgres + Redis toggled INDEPENDENTLY ──────────────────────
# Recommended: external Postgres (RDS — durable source of truth) + bundled
# Redis (in-cluster; Redis holds only ephemeral/reconstructible state, so
# managed Redis is an unnecessary cost). Reach RDS over the VPC (private IP).

variable "database_mode" {
  description = "Postgres source: \"external\" (RECOMMENDED — supply database_url; RDS) or \"bundled\" (in-cluster, demo/eval only)."
  type        = string
  default     = "external"
}

variable "redis_mode" {
  description = "Redis source: \"bundled\" (DEFAULT — in-cluster; all Redis state is ephemeral) or \"external\" (supply redis_url; ElastiCache)."
  type        = string
  default     = "bundled"
}

variable "database_url" {
  description = "database_mode=\"external\": full Postgres 16 DSN, e.g. \"postgres://marshal:PW@my-db.abc123.eu-west-1.rds.amazonaws.com:5432/marshal?sslmode=require\" (RDS private endpoint). Leave \"\" only when database_mode=\"bundled\"."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redis_url" {
  description = "redis_mode=\"external\": full Redis 7 DSN, e.g. \"rediss://my-cache.abc123.eu-west-1.cache.amazonaws.com:6379\" (ElastiCache, TLS+auth). Ignored (leave \"\") when redis_mode=\"bundled\"."
  type        = string
  sensitive   = true
  default     = ""
}

# ── Registry posture ─────────────────────────────────────────────────────────
# Unlike gcp-gke's create_registry_cache (a GCP Artifact Registry
# REMOTE_REPOSITORY mirroring any Docker v2 host), ECR's pull-through cache
# CANNOT mirror registry.marshal.codes: confirmed live against the real ECR
# API that `CreatePullThroughCacheRule` only accepts a hardcoded enum of known
# upstreams (ecr, ecr-public, docker-hub, github-container-registry,
# gitlab-container-registry, azure-container-registry, quay, k8s, chainguard)
# — AWS validates upstream_registry_url server-side against each type's real
# hostname, so there is no way to point it at a bespoke private registry
# under any parameter combination (UnsupportedUpstreamRegistryException).
#
# Three postures as a result:
#   1. DIRECT PULL (default) — registry.marshal.codes with the token.
#   2. create_harbor_cache (harbor.tf) — Terraform provisions Harbor in-cluster
#      as the mirror. PROVISION PATH ONLY (deploy_cluster=true); not wired
#      into reuse.
#   3. image_cache_registry (below) — point at a cache YOU already run
#      (self-hosted Harbor/Zot/Distribution, or any Docker v2 mirror reachable
#      from the cluster). The only pull-through option in the REUSE path
#      (deploy_cluster=false, the default) — see
#      https://docs.marshal.codes/installing/registry-options.

variable "image_cache_registry" {
  description = "Shared pull-through image cache endpoint (fronts registry.marshal.codes) you already run — e.g. \"harbor.acme.internal/marshal\". SHARED, ONE PER CUSTOMER: set up once and reuse across ALL your Marshal installs; NOT provisioned here (see create_harbor_cache for the provision-path alternative). When set it becomes the image prefix for product + tool images. \"\" => direct pull via `registry`. Ignored when create_harbor_cache=true."
  type        = string
  default     = ""
  nullable    = false
}

variable "registry" {
  description = "Low-level image prefix used only when image_cache_registry is \"\" and create_harbor_cache is false. Direct pull (default): \"registry.marshal.codes/marshal\"."
  type        = string
  default     = "registry.marshal.codes/marshal"
}

variable "tools_registry" {
  description = "Registry prefix for session/marketplace TOOL images (separate marshal-tools/* upstream namespace) — only needed if image_cache_registry doesn't follow the \"swap trailing /marshal for /marshal-tools\" convention. Ignored (computed automatically) when create_harbor_cache=true."
  type        = string
  default     = ""
}

variable "registry_auth_mode" {
  description = "How THIS CLUSTER authenticates to the effective registry: \"secret\" (direct pull with the token, default), \"workloadIdentity\" (IRSA — nodes pull via role from a cache like a self-hosted Harbor with anonymous-read disabled), or \"none\" (open/anonymous cache). Ignored when create_harbor_cache=true (forced to \"none\" — see main.tf)."
  type        = string
  default     = "secret"
}


# ── Ingress / TLS ─────────────────────────────────────────────────────────────
# Marshal is internal-only by default → an internal ALB. Unlike GKE (separate
# "gce" vs "gce-internal" IngressClasses), the AWS Load Balancer Controller uses
# ONE IngressClass ("alb") for both postures — internal vs internet-facing is an
# annotation (alb.ingress.kubernetes.io/scheme), wired in main.tf.
#
# Prerequisite this repo does NOT install: the AWS Load Balancer Controller
# must already be running in the target cluster (its own Helm chart + IRSA
# role) — see README.md.

variable "internal_ingress" {
  description = "true (default) = internal ALB (alb.ingress.kubernetes.io/scheme=internal) — reachable only inside your VPC, matching Marshal's internal-only model. false = internet-facing ALB. Flip to false only if you deliberately expose Marshal."
  type        = bool
  default     = true
}

variable "ingress_class_name" {
  description = "IngressClass. \"alb\" (default) — requires the AWS Load Balancer Controller already installed in the cluster (see README.md)."
  type        = string
  default     = "alb"
}

variable "ingress_annotations" {
  description = "Extra Ingress annotations, merged with this flavor's own ALB scheme/target-type annotations (main.tf). Common ones: \"alb.ingress.kubernetes.io/certificate-arn\" (ACM cert for a real listener), \"alb.ingress.kubernetes.io/subnets\" (only needed if the controller can't auto-discover via subnet tags)."
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

# ── ACM certificate for the ALB ──────────────────────────────────────────────
# The ALB terminates TLS from ACM and nothing else (see alb_tls.tf's header for
# the live proof). These three variables are the real-certificate paths; the
# tls_mode placeholder above is only ever a stand-in to get HTTPS listening.
#
#   1. acm_certificate_arn: you already have a cert in ACM. Nothing here
#      touches DNS. Works in BOTH the reuse and provision paths, unlike the
#      tls_mode import, which is provision-only.
#   2. acm_request_certificate + acm_validation_route53_zone_id: Terraform
#      requests a DNS-validated public cert and creates the validation records
#      for you. Route53 only.
#   3. acm_request_certificate alone: same request, but you add the validation
#      CNAMEs in whatever DNS you run. Two applies: the first prints the
#      records and leaves the ALB on HTTP, the second sees the cert ISSUED and
#      turns HTTPS on.

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate you already own, in THIS region (ALB cannot use a cert from another region). Wins over every other TLS source and skips the placeholder import entirely. Use this when your DNS lives outside Route53 or the cert comes from ACM Private CA."
  type        = string
  default     = ""
}

variable "acm_request_certificate" {
  description = "Request a DNS-validated public ACM certificate for ingress_host (+ extra_ingress_hosts + the preview wildcard). false (default). Validation records are created for you when acm_validation_route53_zone_id is set; otherwise read them from the acm_validation_records output, add them in your own DNS, then apply again to attach the issued cert."
  type        = bool
  default     = false
}

variable "acm_validation_route53_zone_id" {
  description = "Route53 hosted zone ID for the ingress_host, used to create the ACM validation records automatically and wait for issuance. \"\" (default) means you add the records yourself (two-phase apply). Requires acm_request_certificate=true."
  type        = string
  default     = ""
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


# ── Control-plane scheduling (reuse mode only — manual pass-through) ─────────
# When deploy_cluster=true, these are DERIVED from taint_control_plane_pool
# automatically (main.tf), same atomic derivation as gcp-gke. These raw
# variables are only consulted in reuse mode (deploy_cluster=false), where
# there's no node-group provisioning — set both together by hand if you
# already taint a node group yourself on the reused cluster.

variable "control_plane_node_selector" {
  description = "Reuse mode only. nodeSelector for the control-plane Deployments (api/gateway/web/marketplace), passed straight to the chart's controlPlane.nodeSelector. {} (default) — pods schedule anywhere."
  type        = map(string)
  default     = {}
}

variable "control_plane_tolerations" {
  description = "Reuse mode only. tolerations for the control-plane Deployments, matching whatever taint you applied yourself (if any) to a dedicated node group. [] (default)."
  type        = list(any)
  default     = []
}

# ── IRSA — manual pass-through ────────────────────────────────────────────────
# buckets.tf sets these automatically for the audit/spaces persistence
# buckets it provisions, but that's not the only reason to bind IRSA: a BYO
# IAM role (reuse mode) or any other AWS-integrated feature this flavor
# doesn't build for you needs a way in too. Merged with buckets.tf's own
# annotation in main.tf, so both compose instead of one silently overriding
# the other.
variable "api_service_account_annotations" {
  description = "Extra annotations on the api's Kubernetes ServiceAccount, e.g. { \"eks.amazonaws.com/role-arn\" = \"...\" } to bind a BYO IRSA role. Merged with the role buckets.tf creates (if any). {} (default) sets none beyond that."
  type        = map(string)
  default     = {}
}

variable "supervisor_service_account_annotations" {
  description = "Extra annotations on the supervisor's Kubernetes ServiceAccount, e.g. { \"eks.amazonaws.com/role-arn\" = \"...\" } to bind a BYO IRSA role. Merged with the role buckets.tf creates (if any). {} (default) sets none beyond that."
  type        = map(string)
  default     = {}
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
