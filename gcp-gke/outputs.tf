# module.marshal is count-based (absent when install_marshal = false), so read
# it with one() — null on the provision-only path.

output "app_url" {
  description = "Marshal web console + API URL (install path)."
  value       = one(module.marshal[*].app_url)
}

output "ingress_ip" {
  description = "The static IP the Ingress (or Gateway) serves on, when this root reserved it (internal_ingress = true with TLS, the default). Point ingress_host at it; for a trial without DNS, a hosts-file entry is enough (README: Reaching Marshal before DNS exists). null otherwise."
  value       = local.ingress_ip_address
}

output "kubeconfig_command" {
  description = "The command that points kubectl at this cluster. Includes --dns-endpoint when the providers use the DNS endpoint (deploy_cluster and dns_endpoint_enabled)."
  value       = local.kubeconfig_command
}

output "namespace" {
  description = "Control-plane namespace (install path)."
  value       = one(module.marshal[*].namespace)
}

output "spaces_namespace" {
  description = "Session-pod namespace (install path)."
  value       = one(module.marshal[*].spaces_namespace)
}

output "chart_version" {
  description = "Installed product version (install path)."
  value       = one(module.marshal[*].chart_version)
}

output "next_steps" {
  description = "Verify + reach the deployment."

  # A hard stop, not a warning: the module writes database_url into the
  # marshal-db Secret as it is, so an empty one installs an api that cannot
  # start. With deploy_cluster = true the Cloud SQL instance needs the VPC this
  # root creates, so the README's order is a first apply with
  # install_marshal = false, then Cloud SQL, then database_url and
  # install_marshal = true. That first apply is not blocked here.
  precondition {
    condition     = !var.install_marshal || var.database_mode != "external" || var.database_url != ""
    error_message = "database_mode = \"external\" (the default) requires database_url. Installing a new cluster (deploy_cluster = true) and Cloud SQL needs that cluster's VPC first: apply once with install_marshal = false, create Cloud SQL (README: Provisioning Cloud SQL yourself), then set database_url and install_marshal = true and apply again. For an evaluation, database_mode = \"bundled\" runs Postgres in the cluster instead."
  }

  value = var.install_marshal ? one(module.marshal[*].next_steps) : (
    <<-EOT
      PROVISION ONLY — the cluster is up and nothing is installed. ArgoCD owns
      the release.

      First of two applies, for Cloud SQL on this new VPC? Then skip the steps
      below: create Cloud SQL now ("Provisioning Cloud SQL yourself" in
      gcp-gke/README.md), set database_url and install_marshal = true in
      terraform.tfvars, and run terraform apply again.

      1. Get the GKE-derived chart values (do NOT retype them):
           terraform output -raw argocd_derived_values > values-derived.yaml
         These are the values this module would have passed to helm and which no
         human can reliably reproduce: the registry endpoints, the storage GSA
         emails on the api and the supervisor service accounts, and the
         control-plane scheduling that pairs with the node taint.

      2. Seed the Secrets BEFORE the first sync — an empty marshal-license at
         bootstrap has broken the marketplace on a live cell before:
           kubectl create namespace ${var.namespace}
           kubectl create secret generic marshal-app-secrets -n ${var.namespace} \
             --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
             --from-literal=KMS_LOCAL_KEY="$(openssl rand -hex 32)" \
             --from-literal=SETUP_TOKEN="$(openssl rand -hex 24)"
           kubectl create secret generic marshal-license -n ${var.namespace} \
             --from-literal=jwt='<installation_jwt>'
         Back up KMS_LOCAL_KEY. Lose it and every stored credential is
         undecryptable. SETUP_TOKEN is what gates the one-time owner claim.
         ${var.database_mode == "external" ? "Also seed marshal-db (key database-url) with the Postgres DSN." : ""}

      3. The ArgoCD Application MUST set secrets.provider=existing with
         existingSecret=marshal-app-secrets. Helm's lookup() never runs under
         ArgoCD, so "generated" re-randomizes JWT_SECRET and KMS_LOCAL_KEY on
         every single sync.

      4. Prove the derived values actually took: launch a space, stop it, resume
         it. A missing supervisor.serviceAccount.annotations 403s every object
         -storage call at session runtime while the api's own storage connection
         test still passes — so nothing else you can check will tell you.
    EOT
  )
}

# ── The provision-only contract ───────────────────────────────────────────────
#
# Terraform knows every one of these values whether or not it installs the
# chart: they are plain locals in main.tf, computed from the cluster, the
# registry cache and the buckets this root creates. The install path passes them
# to helm. The provision-only path has to hand them to whoever does install, and
# that handover is the whole risk of running ArgoCD here — most of these are
# derived identifiers (an AR endpoint, a service-account email) that look
# plausible when wrong, and one of them fails only at session runtime.
#
# So: emit them. Render this into the ArgoCD Application's values instead of
# copying strings out of a runbook, and re-render after any apply that changes
# the cluster name, project, cache repo, buckets or the taint toggle.
output "argocd_derived_values" {
  description = "GKE-derived chart values as YAML, for the ArgoCD Application when install_marshal = false. Everything else in that Application is a value you already chose in tfvars; these are the ones terraform computed."
  value = yamlencode(merge(
    {
      global            = { registry = local.effective_registry }
      registryAuth      = { mode = local.effective_registry_auth }
      toolsRegistryBase = local.effective_tools_registry
      # A conditional's two arms must share one type, and {} is not the type
      # of the gateway block, so each optional piece is a zero- or one-element
      # list, expanded into merge().
      ingress = merge(concat(
        [{
          className   = local.effective_ingress_class
          annotations = local.effective_ingress_annotations
        }],
        local.gateway_mode ? [{
          mode = "gateway"
          gateway = merge(concat(
            [{ className = var.gateway_class_name }],
            length(local.gateway_addresses) > 0 ? [{ addresses = local.gateway_addresses }] : [],
            length(local.gateway_cert_names) > 0 ? [{ certManagerCerts = local.gateway_cert_names }] : [],
          )...)
        }] : [],
      )...)
    },
    # Only when a bucket exists — an annotation naming a GSA that was never
    # created is worse than none at all.
    local.create_any_storage_bucket ? {
      api = { serviceAccount = { annotations = local.api_service_account_annotations } }
    } : {},
    var.create_spaces_persistence_bucket ? {
      supervisor = { serviceAccount = { annotations = local.supervisor_service_account_annotations } }
    } : {},
    # Paired with the pool taint in cluster.tf. The chart applies controlPlane.*
    # to api/gateway/web/marketplace only — the bundled Bitnami subcharts are
    # not covered, so Redis needs its own native fields or it schedules onto a
    # spaces node next to the agent sessions.
    var.taint_control_plane_pool ? {
      controlPlane = {
        nodeSelector = local.control_plane_node_selector
        tolerations  = local.control_plane_tolerations
      }
    } : {},
    var.redis_mode == "bundled" && var.taint_control_plane_pool && var.pin_bundled_datastores ? {
      redis = {
        master = {
          nodeSelector = local.control_plane_node_selector
          tolerations  = local.control_plane_tolerations
        }
      }
    } : {},
  ))
}

output "managed_certificate_dns_records" {
  description = "create_managed_certificate = true: the CNAME records that let Google issue the managed certificate. Add each one in your DNS, wait for managed_certificate_state = ACTIVE, then apply again to serve HTTPS with it. Empty otherwise."
  value = [for a in google_certificate_manager_dns_authorization.managed : {
    name = a.dns_resource_record[0].name
    type = a.dns_resource_record[0].type
    data = a.dns_resource_record[0].data
  }]
}

output "managed_certificate_state" {
  description = "create_managed_certificate = true: the managed certificate's state. ACTIVE means it is issued; the next apply serves HTTPS with it. null otherwise."
  value       = local.managed_cert_state
}
