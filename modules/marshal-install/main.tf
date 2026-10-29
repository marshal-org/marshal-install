# =============================================================================
# modules/marshal-install — the shared, cloud-agnostic Marshal install.
# =============================================================================
# Given a kubernetes + helm provider pointed at a cluster (configured by the
# calling flavor), this does everything the operator runbook
# (marshal/docs/deploy/install.md) does by hand:
#   1. create the control-plane namespace
#   2. create the license (installation JWT) Secret
#   3. create the datastore DSN Secrets (external mode)
#   4. helm install the umbrella chart with values assembled from the inputs
#
# The registry pull credential is NOT created here as a standalone Secret — the
# chart's `registryAuth.mode=secret` builds the dockerconfigjson, replicates it
# into the sessions namespace, and stamps it on every pod. We just pass the
# creds through. (Verified against marshal/infra/helm/marshal/values.yaml.)
# =============================================================================

locals {
  # Where session pods run. Mirror the chart's default (<release>-spaces) so the
  # output is accurate even when spaces_namespace is left empty.
  spaces_namespace = var.spaces_namespace != "" ? var.spaces_namespace : "${var.release_name}-spaces"

  # Effective image-pull prefix → chart's global.registry. The shared customer
  # pull-through cache (image_cache_registry) wins when set; otherwise fall back to
  # the low-level `registry` (direct-pull default). The chart routes tool-image
  # pulls to the same prefix, so per-session pulls also hit the cache.
  effective_registry = var.image_cache_registry != "" ? var.image_cache_registry : var.registry

  # The host the pull credential is stamped against. DERIVED from the registry
  # the images come from, because the two silently disagreeing is a trap: the
  # kubelet then has no credential for the host in the image reference, falls
  # back to an anonymous token and every pod sits in ImagePullBackOff with
  #
  #   failed to authorize: failed to fetch anonymous token: ... 401 Unauthorized
  #
  # which reads like a dead pull token rather than a host mismatch. Hit for real
  # on an install that overrode `registry` and left this at its old hardcoded
  # default of registry.marshal.codes.
  registry_secret_server = var.registry_secret_server != "" ? var.registry_secret_server : split("/", local.effective_registry)[0]

  # registryAuth block — shape depends on the mode.
  registry_auth = merge(
    { mode = var.registry_auth_mode },
    var.registry_auth_mode == "secret" ? {
      secret = {
        server   = local.registry_secret_server
        username = var.deployment_id
        password = var.registry_pull_token
      }
    } : {},
  )

  # Datastore wiring — Postgres and Redis are toggled INDEPENDENTLY. Each engine is
  # either a chart-bundled in-cluster subchart (bundledDeps.*) or an external DSN
  # Secret the chart reads. The recommended posture is external Postgres (the
  # source of truth — needs durability + backups) + bundled Redis (holds only
  # ephemeral/reconstructible state, so an in-cluster instance is fine).
  #
  # Built with merge() rather than one big `? {...} : {...}` conditional for two
  # reasons Terraform only reveals at plan time (not `validate`):
  #   1. A conditional evaluates BOTH branches, so `kubernetes_secret.db[0]` would
  #      throw "index 0 out of range" in bundled mode (count = 0). one() over the
  #      splat is null-safe: one([]) => null.
  #   2. Branches with different attributes trip "Inconsistent conditional result
  #      types". `X ? {obj} : {}` (object vs empty) unifies fine.
  pg_bundled    = var.database_mode == "bundled"
  redis_bundled = var.redis_mode == "bundled"
  datastore_values = merge(
    {
      bundledDeps = {
        postgresql = { enabled = local.pg_bundled }
        redis      = { enabled = local.redis_bundled }
      }
    },
    var.database_mode == "external" ? {
      externalDatabaseSecret = { name = one(kubernetes_secret.db[*].metadata[0].name), key = "database-url" }
    } : {},
    var.redis_mode == "external" ? {
      externalRedisSecret = { name = one(kubernetes_secret.redis[*].metadata[0].name), key = "redis-url" }
    } : {},
  )

  # license block — always set secretName/key/enforce; only override the SaaS
  # host defaults when the caller provided a value.
  license_values = {
    license = merge(
      {
        secretName = kubernetes_secret.license.metadata[0].name
        key        = "jwt"
        enforce    = var.license_enforce
      },
      var.license_jwks_url == "" ? {} : { jwksURL = var.license_jwks_url },
      var.license_refresh_url == null ? {} : { refreshURL = var.license_refresh_url },
    )
  }

  ingress_values = {
    ingress = merge(
      {
        enabled   = var.ingress_enabled
        className = var.ingress_class_name
        host      = var.ingress_host
      },
      length(var.ingress_annotations) > 0 ? { annotations = var.ingress_annotations } : {},
      length(var.extra_ingress_hosts) > 0 ? { extraHosts = var.extra_ingress_hosts } : {},
      var.preview_domain == "" ? {} : { preview = { domain = var.preview_domain, scheme = var.preview_scheme } },
      length(local.effective_ingress_tls) > 0 ? { tls = local.effective_ingress_tls } : {},
      # Only set in gateway mode, so the values an "ingress" install sends are
      # byte-identical to before (and still valid for charts older than 0.27.0).
      # One attribute per conditional: a two-attribute object and {} have no
      # common type, and validate does not catch it, only plan does.
      var.ingress_mode == "gateway" ? { mode = "gateway" } : {},
      var.ingress_mode == "gateway" ? {
        gateway = merge(
          { healthCheckPolicy = var.gateway.health_check_policy },
          var.gateway.class_name == "" ? {} : { className = var.gateway.class_name },
          length(var.gateway.annotations) > 0 ? { annotations = var.gateway.annotations } : {},
          length(var.gateway.addresses) > 0 ? { addresses = var.gateway.addresses } : {},
          length(var.gateway.cert_manager_certs) > 0 ? { certManagerCerts = var.gateway.cert_manager_certs } : {},
        )
      } : {},
    )
  }

  marketplace_values = {
    marketplace = merge(
      var.marketplace_upstream == "" ? {} : { upstream = var.marketplace_upstream },
      var.marketplace_token_exchange_url == "" ? {} : { tokenExchangeURL = var.marketplace_token_exchange_url },
      length(var.marketplace_customer_repos) > 0 ? { customerRepos = var.marketplace_customer_repos } : {},
    )
  }

  secrets_values = {
    secrets = merge(
      { provider = var.secrets_provider },
      var.secrets_existing_secret == "" ? {} : { existingSecret = var.secrets_existing_secret },
      var.secrets_external_secrets == null ? {} : { externalSecrets = var.secrets_external_secrets },
    )
    kms = { backend = var.kms_backend }
  }

  # Both off/empty by default — see variables.tf for why these are worth
  # setting explicitly rather than leaving at the chart's silent-404 default.
  webhook_relay_values = var.webhook_relay_enabled ? {
    webhookRelay = merge(
      { enabled = true },
      var.webhook_relay_url == "" ? {} : { url = var.webhook_relay_url },
    )
  } : {}

  auth_broker_values = var.auth_broker_url == "" ? {} : {
    authBroker = { url = var.auth_broker_url }
  }

  # Assemble the full values document. Each local contributes disjoint top-level
  # keys, so a shallow merge is correct and collision-free.
  chart_values = merge(
    {
      global          = { registry = local.effective_registry }
      registryAuth    = local.registry_auth
      auth            = { basic = { enabled = var.basic_auth_enabled } }
      spacesNamespace = var.spaces_namespace
    },
    var.tools_registry == "" ? {} : { toolsRegistryBase = var.tools_registry },
    length(var.api_service_account_annotations) == 0 ? {} : {
      api = { serviceAccount = { annotations = var.api_service_account_annotations } }
    },
    length(var.supervisor_service_account_annotations) == 0 ? {} : {
      supervisor = { serviceAccount = { annotations = var.supervisor_service_account_annotations } }
    },
    length(var.control_plane_node_selector) == 0 && length(var.control_plane_tolerations) == 0 ? {} : {
      controlPlane = merge(
        length(var.control_plane_node_selector) == 0 ? {} : { nodeSelector = var.control_plane_node_selector },
        length(var.control_plane_tolerations) == 0 ? {} : { tolerations = var.control_plane_tolerations },
      )
    },
    local.datastore_values,
    local.license_values,
    local.ingress_values,
    local.marketplace_values,
    local.secrets_values,
    local.webhook_relay_values,
    local.auth_broker_values,
  )
}

# ── Namespace ────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "marshal" {
  count = var.create_namespace ? 1 : 0
  metadata {
    name   = var.namespace
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

# ── License (installation JWT) Secret ────────────────────────────────────────
resource "kubernetes_secret" "license" {
  metadata {
    name      = "marshal-license"
    namespace = var.namespace
  }
  data       = { jwt = var.installation_jwt }
  depends_on = [kubernetes_namespace.marshal]
}

# ── External datastore DSN Secrets (each created only in its external mode) ───
resource "kubernetes_secret" "db" {
  count = var.database_mode == "external" ? 1 : 0
  metadata {
    name      = "marshal-db"
    namespace = var.namespace
  }
  data       = { database-url = var.database_url }
  depends_on = [kubernetes_namespace.marshal]
}

resource "kubernetes_secret" "redis" {
  count = var.redis_mode == "external" ? 1 : 0
  metadata {
    name      = "marshal-redis"
    namespace = var.namespace
  }
  data       = { redis-url = var.redis_url }
  depends_on = [kubernetes_namespace.marshal]
}

# ── The umbrella chart ───────────────────────────────────────────────────────
resource "helm_release" "marshal" {
  name      = var.release_name
  namespace = var.namespace
  chart     = var.chart
  version   = var.chart_version

  # `terraform apply` waits until the release's resources are ready.
  wait    = true
  timeout = 900 # 15m — first install pulls images + runs migrations

  values = concat([yamlencode(local.chart_values)], var.values_overrides)

  depends_on = [
    kubernetes_namespace.marshal,
    kubernetes_secret.license,
    kubernetes_secret.db,
    kubernetes_secret.redis,
    kubernetes_secret.tls,
  ]
}
