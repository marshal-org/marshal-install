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

  # The SUPERVISOR's KSA gets its own GSA (spaces bucket only), not the shared
  # storage one: the supervisor (in session pods) does the spaces-persistence
  # snapshot/restore blob I/O, and a session pod must not reach the audit
  # bucket. Paired with the WI binding in buckets.tf.
  supervisor_service_account_annotations = var.create_spaces_persistence_bucket ? {
    "iam.gke.io/gcp-service-account" = google_service_account.supervisor_storage[0].email
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

  # With the DNS endpoint on, the IP endpoint is private (or allowlisted), so a
  # kubeconfig from plain get-credentials points kubectl at an address a laptop
  # cannot reach. Same condition the providers use (providers.tf).
  kubeconfig_command = "gcloud container clusters get-credentials ${var.cluster_name} --location ${var.location} --project ${var.project_id}${local.use_dns_endpoint ? " --dns-endpoint" : ""}"

  # Only known when this root reserved the address itself.
  ingress_ip_address = one(google_compute_address.ingress[*].address)

  # GKE-specific paragraphs appended to the module's next_steps. Each one is
  # something a first install ran into without a word of warning.
  gke_next_steps = join("\n\n", [for p in [
    <<-EOT
      The load balancer is NOT ready when the apply finishes. GKE takes 5 to 15
      minutes to program it and pass its health checks (measured: 5 to 10 minutes
      for the address, up to 12.5 for HTTPS), HTTP first and HTTPS a few minutes
      after; until then the URL times out, fails the TLS handshake or answers 502.
      Watch it:
        kubectl get ${local.gateway_mode ? "gateway" : "ingress"} -n ${var.namespace} -w
    EOT
    ,
    local.ingress_ip_address == null ? "" : "Ingress IP: ${local.ingress_ip_address} (${var.internal_ingress ? "internal, reachable inside the VPC only" : "external"}). Point ${var.ingress_host} at it.",
    <<-EOT
      No DNS yet, or working from a laptop outside the VPC: see "Reaching Marshal
      before DNS exists" in gcp-gke/README.md. On chart 0.29 or newer the shortest
      path needs no bastion: kubectl port-forward -n ${var.namespace} svc/web 8080:80
      and browse http://localhost:8080. On older charts the console loads but the
      CLI's space connect fails through a port-forward.
    EOT
    ,
    var.create_spaces_persistence_bucket ? "Space storage: the bucket exists, but stop/resume only keeps a workspace once an owner connects AND enables it, before the first space is created. Settings > Space Storage > provider Google Cloud Storage, bucket ${google_storage_bucket.spaces_persistence[0].name} (location ${google_storage_bucket.spaces_persistence[0].location}), credential fields empty, Save & enable." : <<-EOT
      ⚠ Space storage is OFF (create_spaces_persistence_bucket = false). Until an
        org connects a bucket in Settings > Space Storage, a space keeps its files
        across stop/resume only on a compute size with a persistent disk, and
        cannot be forked or archived. Users who stop a space on any other size
        lose its workspace. See "Object storage" in gcp-gke/README.md.
    EOT
    ,
    var.create_audit_persistence_bucket ? "Audit export: Settings > Auditing > Storage > provider Google Cloud Storage, bucket ${google_storage_bucket.audit_persistence[0].name}, credential fields empty, Save & enable." : "",
    <<-EOT
      Tearing down, in this order (details: "Tearing down" in gcp-gke/README.md):
        1. Delete every space in Marshal.
        2. In terraform.tfvars set ${join(" and ", compact([local.provision ? "deletion_protection = false" : "", local.create_any_storage_bucket ? "force_destroy_buckets = true" : ""]))}; terraform apply.${local.provision || local.create_any_storage_bucket ? "" : " (Nothing to set on this install: skip the apply.)"}
        3. ${!(local.provision && var.create_network) ? "The network and your database stay: this install did not create the VPC, so a Cloud SQL instance on it is yours to keep or delete." : var.database_mode == "external" ? "Delete the Cloud SQL instance, then its Private Services Access peering and range: the destroy cannot remove the VPC while they hold it (the README has the commands)." : "Nothing to delete by hand: the bundled Postgres goes with the cluster."}
        4. terraform destroy (about 15 to 20 minutes).
    EOT
  ] : trimspace(p) if p != ""])

  # The GKE load balancer can serve a Google-managed certificate through a
  # Gateway, which the module's generic advice does not know about.
  gke_tls_next_steps = <<-EOT
    Replace it with tls_mode = "inline" (your certificate and key in tfvars),
    tls_mode = "secret" (a TLS Secret you manage, for example from cert-manager), or
    a Google-managed certificate: ingress_mode = "gateway" and
    create_managed_certificate = true. See "Ingress / TLS" in gcp-gke/README.md.
  EOT
}

module "marshal" {
  source = "../modules/marshal-install"
  count  = var.install_marshal ? 1 : 0

  create_namespace = true
  namespace        = var.namespace
  release_name     = var.release_name

  chart         = var.chart
  chart_version = var.chart_version

  kubeconfig_command = local.kubeconfig_command
  extra_next_steps   = local.gke_next_steps
  tls_next_steps     = local.gke_tls_next_steps

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
  pin_bundled_datastores                 = var.pin_bundled_datastores

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
  #
  # The last three are for DESTROY order, not create order. The chart's
  # Ingress (or Gateway) makes GKE build a load balancer whose forwarding rules
  # hold the static IP and the proxy-only subnet, which Terraform cannot see.
  # With these edges the release (and its namespace, whose delete waits for
  # the Ingress and its GKE finalizer) goes first, then
  # terraform_data.ingress_lb_released waits for the forwarding rules to be
  # gone (ingress_ip.tf), and only then the cluster, the subnet and the IP.
  depends_on = [
    google_container_node_pool.spaces,
    google_container_node_pool.control_plane,
    google_artifact_registry_repository_iam_member.node_reader,
    google_compute_address.ingress,
    google_compute_subnetwork.proxy_only,
    terraform_data.ingress_lb_released,
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

# Warn (not fail) when the control-plane taint is on but chart_version predates
# the chart's controlPlane.nodeSelector/tolerations wiring (0.9.0). A version
# that is not plain MAJOR.MINOR.PATCH (a pre-release, "latest") is not judged.
check "taint_needs_chart_0_9" {
  assert {
    condition = !var.taint_control_plane_pool || try(
      tonumber(split(".", var.chart_version)[0]) * 1000000 +
      tonumber(split(".", var.chart_version)[1]) * 1000 +
      tonumber(split(".", var.chart_version)[2]) >= 9000,
      true
    )
    error_message = "taint_control_plane_pool is true (the default) but chart_version ${var.chart_version} is older than 0.9.0. Those charts ignore the control-plane nodeSelector/tolerations, so the control-plane pods would become unschedulable once the node group is tainted. Upgrade chart_version first, or set taint_control_plane_pool = false."
  }
}
