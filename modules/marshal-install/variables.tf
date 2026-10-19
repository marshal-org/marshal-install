# =============================================================================
# modules/marshal-install — input variables
# =============================================================================
# This is the shared, cloud-agnostic guts of a Marshal install. A "flavor"
# (single-node-k3s, gcp-gke) wires up the cluster + providers and then calls
# this module. Everything below is what the module needs to: create the
# namespace, create the license + datastore Secrets, and `helm install` the
# Marshal umbrella chart with the right values.
#
# Almost every variable has a safe default. In practice a flavor only needs to
# supply: installation_jwt, deployment_id, registry_pull_token, chart_version,
# ingress_host, and the datastore connection info.
#
# Variables are grouped required-first within each section.
# =============================================================================


# ── Release identity ─────────────────────────────────────────────────────────
# One Marshal instance == one Helm release in its own namespace. To run a second
# isolated instance on the same cluster (e.g. prod + staging), instantiate this
# module again with a different release_name + namespace.

variable "release_name" {
  description = "Helm release name. Also used to suffix cluster-scoped objects so two releases never collide. Example: \"marshal\" or \"marshal-prod\"."
  type        = string
  default     = "marshal"
}

variable "namespace" {
  description = "Kubernetes namespace the control-plane workloads (api/gateway/web/marketplace) run in. Session pods run in a SEPARATE namespace (see spaces_namespace)."
  type        = string
  default     = "marshal"
}

variable "create_namespace" {
  description = "Whether THIS module creates the namespace. Set false when the flavor already created it (e.g. single-node-k3s creates the ns to hold its in-cluster Postgres/Redis first)."
  type        = bool
  default     = true
}


# ── Chart source (REQUIRED: chart_version) ───────────────────────────────────
# The Marshal product is one umbrella Helm chart. The chart version IS the
# product version and pins the exact image Bill-of-Materials — you do NOT pick
# per-component image tags.

variable "chart" {
  description = <<-EOT
    Where to pull the umbrella chart from. Two forms:
      • OCI (normal installs):  oci://registry.marshal.codes/marshal-charts/marshal
        Requires helm to be logged in to registry.marshal.codes — the flavor's
        helm provider does this automatically from deployment_id + registry_pull_token.
      • Local path (pre-release / dev testing):  ../../marshal/infra/helm/marshal
        No registry auth needed; chart_version is ignored.
  EOT
  type        = string
  default     = "oci://registry.marshal.codes/marshal-charts/marshal"
}

variable "chart_version" {
  description = "Pinned chart (== product) version, e.g. \"0.5.0\" (current). REQUIRED for an OCI chart; ignored for a local-path chart. Find the version in your onboarding email or via `helm show chart oci://registry.marshal.codes/marshal-charts/marshal`. Day-2 upgrade = bump this and re-apply."
  type        = string
  default     = null
}


# ── License + registry credentials (REQUIRED) ────────────────────────────────
# You get all three from your Marshal onboarding: a Marshal operator mints a
# "deployment" in the deployment-manager back-office and hands you these over a
# secure one-time channel. See the flavor README ("Getting your credentials").

variable "installation_jwt" {
  description = "The installation JWT — your license. An Ed25519-signed token. The module stores it in a K8s Secret (key `jwt`) that api + marketplace mount as MARSHAL_LICENSE_JWT. From your onboarding email / the deployment-manager console."
  type        = string
  sensitive   = true
}

variable "deployment_id" {
  description = "Your deployment id, e.g. \"dep_ab12cd\" (the JWT `sub`). Doubles as the registry username for pulling images/chart from registry.marshal.codes. Not secret. From onboarding."
  type        = string
  default     = ""
}

variable "registry_pull_token" {
  description = "Registry pull token, e.g. \"mrpt_9f3c…\" — a read-only, revocable password. ONE token authenticates all three pulls from registry.marshal.codes: the product images (registry.marshal.codes/marshal/*), the Helm chart (oci://registry.marshal.codes/marshal-charts/marshal), and — with registry_auth_mode=\"secret\" — the in-session tool images (registry.marshal.codes/marshal-tools/*). The proxy authenticates on the token in the PASSWORD; the Basic-auth username is ignored. From onboarding. Required unless you pull everything through your own credential-free cache (registry_auth_mode != \"secret\") AND use a local-path chart."
  type        = string
  sensitive   = true
  default     = ""
}


# ── Where images come from ───────────────────────────────────────────────────
# Two supported postures:
#   1. DIRECT PULL (simplest — good for a single-node eval): the cluster pulls
#      straight from registry.marshal.codes using deployment_id + the pull token.
#      registry = "registry.marshal.codes/marshal", registry_auth_mode = "secret".
#   2. PULL-THROUGH CACHE (recommended, and required at scale): point
#      `image_cache_registry` at the shared cache you run (see below). Every image
#      — product images AND per-session tool images — resolves under it, so pulls
#      hit your cache instead of registry.marshal.codes.

variable "image_cache_registry" {
  description = <<-EOT
    Endpoint of your pull-through image cache — the mirror that fronts
    registry.marshal.codes. When set, ALL image pulls (product images + per-session
    tool images) resolve under it, as <image_cache_registry>/<repo>:<tag>. Wired to
    the chart's global.registry. "" => fall back to `registry` (direct pull).

    SHARED, ONE PER CUSTOMER. This cache is a CUSTOMER-LEVEL resource, NOT a
    per-deployment one: you set it up ONCE (a registry mirror / Harbor proxy-cache /
    GCP AR remote repo / ECR pull-through cache), authenticated to
    registry.marshal.codes with your pull token in ITS upstream config, and EVERY
    Marshal install you run (prod, staging, …) points at THIS SAME cache. It is NOT
    provisioned by this module — it is infrastructure you own and reuse.

    Why it matters: registry.marshal.codes enforces a rate limit, so the many
    per-session tool-image pulls MUST come from your cache, not our registry.

    Examples:
      europe-west1-docker.pkg.dev/acme-shared/marshal-cache/marshal   (GCP AR remote repo)
      123456789.dkr.ecr.us-east-1.amazonaws.com/marshal               (ECR pull-through cache)
      harbor.acme.internal/marshal                                     (Harbor proxy cache)
  EOT
  type        = string
  default     = ""
  nullable    = false
}

variable "registry" {
  description = "Low-level image registry prefix images resolve under, as <registry>/<repo>:<tag>, used ONLY when image_cache_registry is \"\". Default \"registry.marshal.codes/marshal\" is the DIRECT-PULL posture (needs registry_auth_mode=\"secret\"). Prefer setting image_cache_registry (the shared cache) over changing this."
  type        = string
  default     = "registry.marshal.codes/marshal"
}

variable "tools_registry" {
  description = <<-EOT
    Registry prefix session/marketplace TOOL images resolve under — a SEPARATE
    upstream namespace (marshal-tools/*) from the control-plane images `registry`
    points at (marshal/*). "" (default) lets the chart derive it by swapping
    var.registry's trailing "/marshal" for "/marshal-tools", which is correct
    for the direct-pull default and for a cache mirroring the whole
    registry.marshal.codes host under one prefix (e.g. this repo's
    create_registry_cache). Set this EXPLICITLY if your own custom mirror
    doesn't follow that "/marshal" naming convention — otherwise every session
    fails to start with "failed to resolve reference ... not found".
  EOT
  type        = string
  default     = ""
}

variable "registry_auth_mode" {
  description = "How THIS CLUSTER authenticates to `registry`. one of: \"secret\" (chart builds a dockerconfigjson from the creds below, replicates it into the sessions namespace, stamps it on all pods — use for direct pull), \"workloadIdentity\" (nodes pull with GKE WI / EKS IRSA — use with a cloud pull-through cache), \"none\" (open cache, anonymous pull)."
  type        = string
  default     = "secret"

  validation {
    condition     = contains(["secret", "workloadIdentity", "none"], var.registry_auth_mode)
    error_message = "registry_auth_mode must be one of: secret, workloadIdentity, none."
  }
}

variable "registry_secret_server" {
  description = "registry_auth_mode=\"secret\" only: the registry host the pull credential authenticates against. \"\" (default) derives it from the registry the images actually come from (image_cache_registry when set, otherwise registry), which is right in every normal case. Set it explicitly only when the credential belongs to a different host than the images."
  type        = string
  default     = ""
}


# ── Datastores: Postgres 16 + Redis 7 (toggled INDEPENDENTLY) ────────────────
# Marshal needs one Postgres and one Redis. Each is configured on its own because
# they have very different durability needs:
#
#   • Postgres is the SOURCE OF TRUTH — sessions, orgs, credentials, manifests,
#     and audit all live here. It needs durability + backups, so the recommended
#     mode is "external": your managed Postgres (Cloud SQL / RDS / …). Marshal
#     does not own its data durability.
#   • Redis holds ONLY ephemeral / TTL'd / reconstructible state — WS tokens, SSE
#     event streams, pod addresses, OAuth state, short-TTL annotation drafts,
#     buffered usage counters. NOTHING persistent is Redis-only. So an in-cluster
#     ("bundled") Redis is fine and is the DEFAULT — paying for managed Redis buys
#     durability Marshal doesn't need. Flip to "external" only if you already run
#     managed Redis and would rather point at it.
#
# "external" mode stores the DSN you supply in a K8s Secret the api/gateway read
# (DATABASE_URL / REDIS_URL). "bundled" mode enables the chart's in-cluster
# subchart for that engine.

variable "database_mode" {
  description = "Postgres source: \"external\" (RECOMMENDED — supply database_url; your managed Postgres, the durable source of truth) or \"bundled\" (chart's in-cluster Postgres, demo/eval only)."
  type        = string
  default     = "external"

  validation {
    condition     = contains(["external", "bundled"], var.database_mode)
    error_message = "database_mode must be one of: external, bundled."
  }
}

variable "redis_mode" {
  description = "Redis source: \"bundled\" (DEFAULT — in-cluster; Redis state is all ephemeral/reconstructible, so no managed Redis needed) or \"external\" (supply redis_url; point at your managed Redis)."
  type        = string
  default     = "bundled"

  validation {
    condition     = contains(["external", "bundled"], var.redis_mode)
    error_message = "redis_mode must be one of: external, bundled."
  }
}

variable "database_url" {
  description = "database_mode=\"external\": full Postgres 16 DSN, e.g. \"postgres://marshal:PW@HOST:5432/marshal?sslmode=require\". Cloud SQL private IP, RDS, or the k3s flavor's in-cluster Postgres all fit here."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redis_url" {
  description = "redis_mode=\"external\": full Redis 7 DSN, e.g. \"redis://HOST:6379\" or \"rediss://default:PW@HOST:6380\" (managed, TLS+auth). Ignored when redis_mode=\"bundled\"."
  type        = string
  sensitive   = true
  default     = ""
}


# ── Public routing / ingress (REQUIRED: ingress_host) ────────────────────────

variable "kubeconfig_command" {
  description = "The cloud-specific command that points kubectl at the new cluster, printed verbatim in next_steps. Each flavor sets its own; the default is deliberately not runnable, because this module does not know the cluster's name, region or project."
  type        = string
  default     = "# point kubectl at the new cluster first; see your cloud's README"
}

variable "ingress_host" {
  description = "Primary app hostname — web + api + gateway are path-routed under it. Example: \"marshal.acme.com\". For a quick k3s test with no real DNS use an sslip.io host like \"marshal.203-0-113-5.sslip.io\"."
  type        = string
}

variable "ingress_enabled" {
  description = "Create the Ingress. Set false only if you front Marshal with your own gateway/LB and route to the Services yourself."
  type        = bool
  default     = true
}

variable "ingress_class_name" {
  description = "IngressClass. Flavors set a sensible default (k3s: \"traefik\"; GKE: \"gce\" or your nginx class). \"\" uses the cluster's default IngressClass."
  type        = string
  default     = ""
}

variable "ingress_annotations" {
  description = "Extra annotations on the Ingress — e.g. cert-manager (\"cert-manager.io/cluster-issuer\": \"letsencrypt\") or GKE static-IP / managed-cert annotations."
  type        = map(string)
  default     = {}
}

variable "extra_ingress_hosts" {
  description = "Extra hostnames routed to the same api/gateway/web backends as ingress_host, each on its own rule on the SAME Ingress object — e.g. a Tailscale MagicDNS name alongside the primary public DNS name. Each entry needs its own DNS record pointing at the Ingress/LB. TLS: tls_mode=\"self_signed\"/\"inline\" fold these into the cert's SAN list automatically (see tls.tf); tls_mode=\"secret\" requires the caller's own Secret to already cover them; the aws-eks flavor's ACM cert (alb_tls.tf) only auto-covers these for tls_mode=\"self_signed\" — bring your own SANs for \"inline\" there."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "ingress_tls" {
  description = "ADVANCED / power-user escape hatch. TLS blocks for the Ingress: { hosts = [\"marshal.acme.com\"], secretName = \"marshal-tls\" }. Leave [] (default) to let tls_mode below decide automatically — set this explicitly only for multi-host/SAN combos tls_mode can't express. When non-empty, this always wins over tls_mode."
  type = list(object({
    hosts      = list(string)
    secretName = string
  }))
  default = []
}

# ── TLS (on by default — see tls_mode) ───────────────────────────────────────
# HTTPS is the default posture. Out of the box (tls_mode="self_signed") Terraform
# generates a placeholder cert and manages the k8s Secret itself, so there's
# always something to replace rather than a decision to make on day one.
# Swap in a real cert per your PKI story via tls_mode="inline" (paste PEM
# content into tfvars) or tls_mode="secret" (you manage the k8s Secret
# yourself — e.g. cert-manager — and just name it).

variable "tls_mode" {
  description = <<-EOT
    How the Ingress TLS certificate is sourced:
      "self_signed" (DEFAULT) — Terraform generates a placeholder self-signed
        cert covering ingress_host (+ the preview wildcard if set) and creates/
        manages the k8s Secret. Loudly NOT for production use as-is — replace it
        (see tls_cert_pem/tls_key_pem or tls_secret_name) once you have a real
        cert; the module keeps managing the Secret either way so there's zero
        Terraform diff when you rotate it via tls_mode="inline".
      "inline" — supply tls_cert_pem + tls_key_pem (PEM content); Terraform
        creates the Secret from them instead of generating one.
      "secret" — you already manage a k8s TLS Secret yourself (e.g. cert-manager
        issuing + rotating it); Terraform only references it by name
        (tls_secret_name), never creates or reads its contents.
      "none" — HTTP only, no TLS (the old default; matches ingress_tls=[]).
  EOT
  type        = string
  default     = "self_signed"

  validation {
    condition     = contains(["self_signed", "inline", "secret", "none"], var.tls_mode)
    error_message = "tls_mode must be one of: self_signed, inline, secret, none."
  }
}

variable "tls_cert_pem" {
  description = "PEM-encoded certificate (tls_mode=\"inline\" only). Ignored otherwise."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tls_key_pem" {
  description = "PEM-encoded private key (tls_mode=\"inline\" only). Ignored otherwise."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tls_secret_name" {
  description = "Name of an existing k8s TLS Secret you manage yourself (tls_mode=\"secret\" only). For \"self_signed\"/\"inline\" the module always names its managed Secret \"marshal-tls\" — this variable is ignored in those modes."
  type        = string
  default     = "marshal-tls"
}

variable "preview_domain" {
  description = "Wildcard host for per-session port previews, e.g. \"preview.acme.com\" (customers reach *.preview.acme.com). Leave \"\" to disable previews. For k3s tests an sslip.io wildcard works."
  type        = string
  default     = ""
}

variable "preview_scheme" {
  description = "Scheme for preview URLs: \"https\" (default) or \"http\" (test without TLS)."
  type        = string
  default     = "https"
}


# ── Session-pod namespace ────────────────────────────────────────────────────

variable "spaces_namespace" {
  description = "Namespace session pods run in (separate from the control-plane ns). \"\" => \"<release_name>-spaces\". The chart always sets this explicitly so two releases never share a session namespace."
  type        = string
  default     = ""
}


# ── License tuning (optional — chart defaults are the canonical SaaS hosts) ───
# Leave these at their defaults unless Marshal told you to override them (e.g. a
# dedicated/regional online tier).

variable "license_jwks_url" {
  description = "Public JWKS the cluster verifies the installation JWT against. \"\" => chart default (https://keys.marshal.codes/.well-known/jwks.json)."
  type        = string
  default     = ""
}

variable "license_refresh_url" {
  description = "Online endpoint the api exchanges the installation JWT at for a short-lived operational license. null => chart default (https://tokens.marshal.codes/v1/license). Set \"\" (empty string) to DISABLE the refresh loop entirely (fully offline license)."
  type        = string
  default     = null
}

variable "license_enforce" {
  description = "When true, new sessions are paused once the deployment is de-licensed past grace. Default false = observe-only (state logged, nothing blocked)."
  type        = bool
  default     = false
}


# ── Marketplace (optional — chart defaults point at the Marshal SaaS tier) ────

variable "marketplace_upstream" {
  description = "Canonical upstream package catalog the in-cluster marketplace proxies. \"\" => chart default (https://marketplace.marshal.codes)."
  type        = string
  default     = ""
}

variable "marketplace_token_exchange_url" {
  description = "Token-exchange host the in-cluster marketplace trades the installation JWT for a short-lived marketplace token. \"\" => chart default (https://tokens.marshal.codes)."
  type        = string
  default     = ""
}

variable "marketplace_customer_repos" {
  description = "Optional customer-owned package sources merged on top of the upstream catalog. Each: { url = \"https://github.com/acme/marshal-packages\", authSecret = { name = \"acme-pkgs\", key = \"token\" } }. Package names must be namespaced (acme/foo) and cannot shadow official packages."
  type        = list(any)
  default     = []
}


# ── Webhook Relay + Auth Broker (both optional — chart default is OFF/empty) ──
# Both gate whole route groups in the api rather than erroring: left off, the
# corresponding UI pages (Settings > Webhooks, Settings > Slack) 404 on every
# call with no other signal: the api gates the whole route group on the value
# being set, it does not fail at startup. Decide explicitly rather than
# discovering this live.

variable "webhook_relay_enabled" {
  description = "Turns on Settings > Webhooks (org admins can point external services like a GitHub App at the cluster without inbound access, via an outbound connection to the Relay). Requires installation_jwt to be set (the Relay authenticates by installation identity)."
  type        = bool
  default     = false
  nullable    = false
}

variable "webhook_relay_url" {
  description = "Relay endpoint. \"\" => chart default (https://hooks.marshal.codes, Marshal's hosted tier). Only used when webhook_relay_enabled = true. Needs outbound 443 from the cluster to whichever host this resolves to."
  type        = string
  default     = ""
  nullable    = false
}

variable "auth_broker_url" {
  description = "Turns on Settings > Slack (brokered OAuth so an org can connect Slack, and eventually other Google/OAuth login, without registering their own app) by setting the broker's bare origin, e.g. \"https://auth.marshal.codes\" (Marshal's hosted tier). \"\" (default) => disabled. Requires installation_jwt to be set (the broker authenticates by installation identity). Needs outbound 443 from the cluster to whichever host this points at."
  type        = string
  default     = ""
  nullable    = false
}


# ── App secrets (JWT_SECRET + KMS_LOCAL_KEY) + KMS backend ───────────────────
# These two long-lived secrets are sourced by the CHART, never put in tfvars.
#   generated  — chart creates + KEEPS them (never rotated, survive upgrades).
#                Safe default. BACK UP the resulting Secret: losing KMS_LOCAL_KEY
#                makes all stored credentials unrecoverable.
#   existing   — you pre-create a Secret with keys JWT_SECRET + KMS_LOCAL_KEY.
#   externalSecrets — chart emits ExternalSecret CRDs (needs External Secrets
#                Operator); supply secrets_external_secrets.

variable "secrets_provider" {
  description = "How the chart sources JWT_SECRET + KMS_LOCAL_KEY: \"generated\" | \"existing\" | \"externalSecrets\"."
  type        = string
  default     = "generated"

  validation {
    condition     = contains(["generated", "existing", "externalSecrets"], var.secrets_provider)
    error_message = "secrets_provider must be one of: generated, existing, externalSecrets."
  }
}

variable "secrets_existing_secret" {
  description = "secrets_provider=\"existing\": name of a pre-created K8s Secret in `namespace` holding keys JWT_SECRET + KMS_LOCAL_KEY."
  type        = string
  default     = ""
}

variable "secrets_external_secrets" {
  description = <<-EOT
    secrets_provider="externalSecrets": the chart's `secrets.externalSecrets`
    block, passed through as-is. Example:
      {
        secretStoreRef = { name = "gcp-secret-manager", kind = "ClusterSecretStore" }
        remoteRefs = {
          jwtSecret   = { key = "projects/P/secrets/marshal-jwt-secret/versions/latest" }
          kmsLocalKey = { key = "projects/P/secrets/marshal-kms-key/versions/latest" }
        }
      }
    null when not using External Secrets Operator.
  EOT
  type        = any
  default     = null
}

variable "kms_backend" {
  description = "Credential-encryption KMS backend: \"local\" (key from KMS_LOCAL_KEY, default) or \"aws\" (future work)."
  type        = string
  default     = "local"
}


# ── Web console sign-in ──────────────────────────────────────────────────────

variable "basic_auth_enabled" {
  description = "Email/password login for the web console. On by default so a fresh install can sign in. Disable only if you front the app with your own SSO/identity proxy."
  type        = bool
  default     = true
}

variable "api_service_account_annotations" {
  description = "Annotations on the api's Kubernetes ServiceAccount, e.g. { \"iam.gke.io/gcp-service-account\" = \"...\" } to bind GKE Workload Identity for audit-sync / space-storage object storage access. {} (default) sets none."
  type        = map(string)
  default     = {}
}

variable "supervisor_service_account_annotations" {
  description = "Annotations on the supervisor's Kubernetes ServiceAccount (the KSA session pods run under, in the spaces namespace), e.g. { \"iam.gke.io/gcp-service-account\" = \"...\" } to bind GKE Workload Identity so the supervisor can do spaces-persistence snapshot/restore blob I/O. Distinct from api_service_account_annotations because the supervisor — not the api — does that runtime I/O. {} (default) sets none."
  type        = map(string)
  default     = {}
}

variable "control_plane_node_selector" {
  description = "nodeSelector for the control-plane Deployments (api/gateway/web/marketplace), passed straight to the chart's controlPlane.nodeSelector. {} (default) — pods schedule anywhere, today's behavior. A flavor that provisions a dedicated/tainted control-plane node pool (e.g. gcp-gke's taint_control_plane_pool) should derive this from the SAME toggle that applies the taint, not set it independently — otherwise the taint and the toleration can land in separate applies, and a cluster can end up tainted with no pod able to schedule there."
  type        = map(string)
  default     = {}
}

variable "control_plane_tolerations" {
  description = "tolerations for the control-plane Deployments, matching control_plane_node_selector's taint. [] (default). Each entry passed straight to the chart's controlPlane.tolerations (e.g. { key = \"workload\", operator = \"Equal\", value = \"control-plane\", effect = \"NoSchedule\" })."
  type        = list(any)
  default     = []
}


# ── Escape hatch ─────────────────────────────────────────────────────────────

variable "values_overrides" {
  description = "Extra raw values-YAML documents merged LAST (highest precedence) into the helm_release — for anything not surfaced as a first-class variable (api.extraEnv, resources, autoscaling, pdb, …). Each list item is a YAML string. Use `yamlencode({...})` or `file(\"extra.yaml\")`."
  type        = list(string)
  default     = []
}
