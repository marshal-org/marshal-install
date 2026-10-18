# Thin wrapper. Two paths:
#   • deploy_cluster = false (default) — INSTALL: create the namespace + in-cluster
#     (or BYO) datastores, then call the shared module against the kubeconfig.
#   • deploy_cluster = true — PROVISION ONLY: gce.tf stands up a private k3s node;
#     no k8s/install resources here (module count = 0). Install on a later apply
#     with deploy_cluster=false. See outputs.
# All real install logic lives in the shared module.

module "marshal" {
  source = "../modules/marshal-install"
  count  = var.deploy_cluster ? 0 : 1

  # This flavor owns the namespace (it holds the in-cluster datastores).
  create_namespace = false
  namespace        = var.namespace
  release_name     = var.release_name

  # Chart + version.
  chart         = var.chart
  chart_version = var.chart_version

  # Credentials.
  installation_jwt    = var.installation_jwt
  deployment_id       = var.deployment_id
  registry_pull_token = var.registry_pull_token

  # Registry posture.
  image_cache_registry = var.image_cache_registry
  registry             = var.registry
  registry_auth_mode   = var.registry_auth_mode

  # Datastores — both run in-cluster on this single node (or BYO external), so both
  # are "external" DSNs from the module's view. (Redis on k3s is the flavor's own
  # in-cluster instance, which already satisfies the "bundled Redis" recommendation
  # — no managed Redis cost.)
  database_mode = "external"
  redis_mode    = "external"
  database_url  = local.database_url
  redis_url     = local.redis_url

  # Routing.
  ingress_host        = var.ingress_host
  extra_ingress_hosts = var.extra_ingress_hosts
  ingress_class_name  = var.ingress_class_name
  ingress_annotations = var.ingress_annotations
  ingress_tls         = var.ingress_tls
  tls_mode            = var.tls_mode
  tls_cert_pem        = var.tls_cert_pem
  tls_key_pem         = var.tls_key_pem
  tls_secret_name     = var.tls_secret_name
  preview_domain      = var.preview_domain
  preview_scheme      = var.preview_scheme

  webhook_relay_enabled = var.webhook_relay_enabled
  webhook_relay_url     = var.webhook_relay_url
  auth_broker_url       = var.auth_broker_url

  values_overrides = var.values_overrides

  depends_on = [
    kubernetes_namespace.marshal,
    kubernetes_deployment.postgres,
    kubernetes_service.postgres,
    kubernetes_deployment.redis,
    kubernetes_service.redis,
  ]
}

# ── Guardrails (fail fast at plan) ───────────────────────────────────────────
# In the install path, if the operator turned off in-cluster datastores they must
# supply DSNs. Irrelevant in the provision-only path.
check "datastores_supplied" {
  assert {
    condition     = var.deploy_cluster || var.provision_datastores || (var.database_url != "" && var.redis_url != "")
    error_message = "provision_datastores=false requires both database_url and redis_url."
  }
}

check "provision_inputs_supplied" {
  assert {
    condition     = !var.deploy_cluster || (var.project_id != "" && var.zone != "")
    error_message = "deploy_cluster=true requires project_id and zone."
  }
}
