# Thin wrapper: hand the shared install module GKE-appropriate defaults + the
# datastore config. Cluster access is wired in providers.tf (reuse OR the private
# cluster provisioned in cluster.tf). All real install logic lives in the module.

locals {
  # Internal-only by default → GKE's internal Ingress class.
  effective_ingress_class = var.internal_ingress ? "gce-internal" : var.ingress_class_name

  # create_registry_cache=true self-wires the install onto the cache created in
  # registry_cache.tf — no need to also hand-set registry/registry_auth_mode.
  effective_registry      = var.create_registry_cache ? local.registry_cache_endpoint : var.registry
  effective_registry_auth = var.create_registry_cache ? "workloadIdentity" : var.registry_auth_mode
  # Explicitly computed (not left to the chart's regex-swap fallback) whenever
  # we control the cache; var.tools_registry only matters for a BYO mirror.
  effective_tools_registry = var.create_registry_cache ? local.registry_cache_tools_endpoint : var.tools_registry

  # Workload Identity annotation binding the api's KSA to the storage GSA —
  # see buckets.tf. Empty (no annotation) when neither bucket is enabled.
  api_service_account_annotations = local.create_any_storage_bucket ? {
    "iam.gke.io/gcp-service-account" = google_service_account.storage[0].email
  } : {}

  # Same GSA on the SUPERVISOR's KSA — the supervisor (in session pods) does the
  # spaces-persistence snapshot/restore blob I/O, so it needs the identity at
  # runtime. Gated on the spaces bucket specifically (the supervisor never
  # touches the audit bucket). Paired with the WI binding in buckets.tf.
  supervisor_service_account_annotations = var.create_spaces_persistence_bucket ? {
    "iam.gke.io/gcp-service-account" = google_service_account.storage[0].email
  } : {}

  # Derived from the SAME toggle that taints the control-plane pool
  # (cluster.tf) — never set independently, so the taint and the matching
  # chart toleration always land in the same apply. taint_control_plane_pool=
  # false (default) means both stay empty (no-op, current behavior).
  control_plane_node_selector = var.taint_control_plane_pool ? { workload = "control-plane" } : {}
  control_plane_tolerations = var.taint_control_plane_pool ? [
    { key = "workload", operator = "Equal", value = "control-plane", effect = "NoSchedule" }
  ] : []

  # Self-wires the static IP name into the annotations whenever one is needed
  # (local.needs_static_ip, ingress_ip.tf) — regardless of whether THIS apply
  # creates it (create_ingress_static_ip=true) or it already exists out-of-band
  # (false — e.g. terraform import'd, or set up by hand before this module
  # managed it). Using var.ingress_static_ip_name directly (not the resource's
  # .name) means this is correct in both cases with no dependency on the
  # resource actually existing in state.
  effective_ingress_annotations = merge(
    var.ingress_annotations,
    local.needs_static_ip ? {
      "kubernetes.io/ingress.regional-static-ip-name" = var.ingress_static_ip_name
    } : {},
  )
}

module "marshal" {
  source = "../modules/marshal-install"
  count  = var.install_marshal ? 1 : 0

  create_namespace = true
  namespace        = var.namespace
  release_name     = var.release_name

  chart         = var.chart
  chart_version = var.chart_version

  kubeconfig_command = "gcloud container clusters get-credentials ${var.cluster_name} --location ${var.location} --project ${var.project_id}"

  installation_jwt    = var.installation_jwt
  deployment_id       = var.deployment_id
  registry_pull_token = var.registry_pull_token

  registry           = local.effective_registry
  registry_auth_mode = local.effective_registry_auth
  tools_registry     = local.effective_tools_registry

  api_service_account_annotations        = local.api_service_account_annotations
  supervisor_service_account_annotations = local.supervisor_service_account_annotations
  control_plane_node_selector            = local.control_plane_node_selector
  control_plane_tolerations              = local.control_plane_tolerations

  # Postgres + Redis toggled independently (default: external Cloud SQL + bundled Redis).
  database_mode = var.database_mode
  redis_mode    = var.redis_mode
  database_url  = var.database_url
  redis_url     = var.redis_url

  ingress_host        = var.ingress_host
  extra_ingress_hosts = var.extra_ingress_hosts
  ingress_class_name  = local.effective_ingress_class
  ingress_annotations = local.effective_ingress_annotations
  ingress_mode        = var.ingress_mode
  gateway = {
    class_name         = var.gateway_class_name
    addresses          = local.gateway_addresses
    cert_manager_certs = local.gateway_cert_names
  }
  ingress_tls     = var.ingress_tls
  tls_mode        = var.tls_mode
  tls_cert_pem    = var.tls_cert_pem
  tls_key_pem     = var.tls_key_pem
  tls_secret_name = var.tls_secret_name
  preview_domain  = var.preview_domain
  preview_scheme  = var.preview_scheme

  webhook_relay_enabled = var.webhook_relay_enabled
  webhook_relay_url     = var.webhook_relay_url
  auth_broker_url       = var.auth_broker_url

  values_overrides = var.values_overrides

  # When provisioning, install only after both node pools are ready, and (if
  # enabled) after nodes can actually read the cache. Empty (count 0) in the
  # reuse / no-cache paths — a no-op dependency either way.
  depends_on = [
    google_container_node_pool.spaces,
    google_container_node_pool.control_plane,
    google_artifact_registry_repository_iam_member.node_reader,
  ]
}

# #29 put a count on module "marshal" (install_marshal). Existing installs hold
# state at module.marshal; without this, plan destroys the namespace, secrets and
# helm release and creates them again at module.marshal[0].
moved {
  from = module.marshal
  to   = module.marshal[0]
}

# ── Guardrails (fail fast at plan) ───────────────────────────────────────────
check "database_url_supplied" {
  assert {
    condition     = var.database_mode != "external" || var.database_url != ""
    error_message = "database_mode=\"external\" requires database_url."
  }
}

check "redis_url_supplied" {
  assert {
    condition     = var.redis_mode != "external" || var.redis_url != ""
    error_message = "redis_mode=\"external\" requires redis_url."
  }
}

check "authorized_networks_supplied" {
  assert {
    condition     = !var.deploy_cluster || var.dns_endpoint_enabled || length(var.master_authorized_networks) > 0
    error_message = "deploy_cluster=true requires master_authorized_networks (at least your admin CIDR) — otherwise you cannot reach the control plane. Set dns_endpoint_enabled=true to reach it over the IAM-gated DNS endpoint instead."
  }
}
