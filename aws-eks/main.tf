# Thin wrapper: hand the shared install module EKS-appropriate defaults.
# Cluster access is wired in providers.tf (reuse OR the cluster provisioned in
# cluster.tf). All real install logic lives in the module.

locals {
  # Internal vs internet-facing ALB is an annotation, not a separate
  # IngressClass (unlike GKE's "gce" vs "gce-internal" split) — the AWS Load
  # Balancer Controller reads alb.ingress.kubernetes.io/scheme off the same
  # "alb" class either way.
  #
  # certificate-arn (local.alb_certificate_arn, alb_tls.tf) is what actually
  # gets ALB to terminate HTTPS
  # — confirmed live that tls_mode="self_signed"'s k8s Secret alone produces
  # an Ingress that LOOKS like it has both 80/443 but only ever gets an
  # HTTP:80 listener; ALB has no mechanism to read a k8s TLS Secret directly.
  # listen-ports is set explicitly alongside it (not left to the controller's
  # own inference) so both listeners are created deterministically.
  effective_ingress_annotations = merge(
    {
      "alb.ingress.kubernetes.io/scheme"      = var.internal_ingress ? "internal" : "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"
    },
    local.alb_certificate_arn != "" ? {
      "alb.ingress.kubernetes.io/certificate-arn" = local.alb_certificate_arn
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      # The AWS Load Balancer Controller's purpose-built redirect mechanism —
      # NOT the generic alb.ingress.kubernetes.io/actions.${name} annotation
      # (tried first, reverted: that one applies whatever Ingress rule you
      # attach it to to every listener the ALB serves, including HTTPS,
      # which redirects HTTPS traffic to itself; this annotation instead
      # only ever touches the HTTP listener's default action — confirmed
      # against kubernetes-sigs/aws-load-balancer-controller's own
      # docs/guide/tasks/ssl_redirect.md). Needs no Ingress path/rule of its
      # own, unlike the actions.* mechanism.
      "alb.ingress.kubernetes.io/ssl-redirect" = "443"
    } : {},
    var.ingress_annotations,
  )

  # Derived from the SAME toggle that taints the control-plane node group
  # (cluster.tf) — never set independently, so the taint and the matching
  # chart toleration always land in the same apply. Only meaningful when
  # provisioning (deploy_cluster=true); in reuse mode there's no node-group
  # management here, so the manual pass-through variables apply instead.
  control_plane_node_selector = var.deploy_cluster ? (
    var.taint_control_plane_pool ? { workload = "control-plane" } : {}
  ) : var.control_plane_node_selector

  control_plane_tolerations = var.deploy_cluster ? (
    var.taint_control_plane_pool ? [
      { key = "workload", operator = "Equal", value = "control-plane", effect = "NoSchedule" }
    ] : []
  ) : var.control_plane_tolerations

  # create_harbor_cache=true self-wires the install onto the cache created in
  # harbor.tf — no need to also hand-set registry/registry_auth_mode. "none"
  # (no pull secret) is safe because the cache project is public/anonymous-
  # read (harbor.tf), reachable only from inside the private VPC. Otherwise,
  # image_cache_registry (a cache the customer already runs — the only
  # pull-through option in the reuse path, where create_harbor_cache isn't
  # wired) wins over the low-level registry/registry_auth_mode fallback.
  effective_registry = var.create_harbor_cache ? local.harbor_registry_endpoint : (
    var.image_cache_registry != "" ? var.image_cache_registry : var.registry
  )
  effective_registry_auth  = var.create_harbor_cache ? "none" : var.registry_auth_mode
  effective_tools_registry = var.create_harbor_cache ? local.harbor_tools_registry_endpoint : var.tools_registry

  # IRSA annotations: var.*_service_account_annotations (manual pass-through,
  # e.g. a BYO role in reuse mode) merged with whatever buckets.tf derives
  # for the audit/spaces persistence buckets (empty when neither bucket is
  # enabled, same gating gcp-gke's Workload Identity annotations use). The
  # bucket-derived entry wins on key collision (rightmost merge() argument),
  # since it's the one this flavor's own resources actually depend on.
  api_service_account_annotations = merge(
    var.api_service_account_annotations,
    local.create_any_storage_bucket ? {
      "eks.amazonaws.com/role-arn" = aws_iam_role.storage[0].arn
    } : {},
  )

  supervisor_service_account_annotations = merge(
    var.supervisor_service_account_annotations,
    var.create_spaces_persistence_bucket ? {
      "eks.amazonaws.com/role-arn" = aws_iam_role.storage[0].arn
    } : {},
  )
}

module "marshal" {
  source = "../modules/marshal-install"

  create_namespace = true
  namespace        = var.namespace
  release_name     = var.release_name

  chart         = var.chart
  chart_version = var.chart_version

  installation_jwt    = var.installation_jwt
  deployment_id       = var.deployment_id
  registry_pull_token = var.registry_pull_token

  registry           = local.effective_registry
  registry_auth_mode = local.effective_registry_auth
  tools_registry     = local.effective_tools_registry

  control_plane_node_selector = local.control_plane_node_selector
  control_plane_tolerations   = local.control_plane_tolerations

  api_service_account_annotations        = local.api_service_account_annotations
  supervisor_service_account_annotations = local.supervisor_service_account_annotations

  # Postgres + Redis toggled independently. database_url comes from the
  # provisioned RDS instance when create_rds=true (database.tf), otherwise
  # passes through the supplied DSN unchanged.
  database_mode = var.database_mode
  redis_mode    = var.redis_mode
  database_url  = local.database_url
  redis_url     = var.redis_url

  ingress_host        = var.ingress_host
  extra_ingress_hosts = var.extra_ingress_hosts
  ingress_class_name  = var.ingress_class_name
  ingress_annotations = local.effective_ingress_annotations
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

  # Only install once the cluster is actually usable: both node groups ready,
  # the EBS CSI addon in place (bundled Redis's PVC needs it), the ALB
  # controller running (the Ingress needs it to get an address), and — when
  # enabled — Harbor itself up (the registry effective_registry now points
  # at). Empty (count 0) in the reuse path / when Harbor is disabled — a
  # no-op dependency either way.
  depends_on = [
    aws_eks_node_group.spaces,
    aws_eks_node_group.control_plane,
    aws_eks_addon.ebs_csi,
    kubernetes_storage_class.gp3,
    aws_acm_certificate.alb,
    aws_acm_certificate.requested,
    aws_acm_certificate_validation.requested,
    helm_release.aws_load_balancer_controller,
    # Destroyed AFTER this resource, which is the point: it is the rule that
    # lets this host reach the API at all. Without the edge, terraform removed
    # it first and then could not delete what was left, failing the destroy
    # with `dial tcp <endpoint>:443: i/o timeout`.
    aws_security_group_rule.cluster_private_access,
    helm_release.harbor,
    harbor_project.cache,
  ]
}

# ── Guardrails (fail fast at plan) ───────────────────────────────────────────
# NOT `check` blocks: confirmed live (terraform 1.15) that a failed `check`
# assertion is always a Warning, never an Error — `terraform plan` exits 0
# regardless, so it can't actually stop a bad apply. A `module` block's own
# `lifecycle { precondition {} }` isn't an option either — confirmed live
# that "lifecycle" is a reserved/unsupported block name on a module call
# ("Reserved block type name in module block"), even on 1.15. An output
# value's `precondition` is the one mechanism confirmed live to produce a
# real Error and a non-zero exit — that's what these are.
output "_database_url_supplied" {
  value = null
  precondition {
    condition     = var.create_rds || var.database_mode != "external" || var.database_url != ""
    error_message = "database_mode=\"external\" requires database_url, unless create_rds=true provisions it for you."
  }
}

output "_redis_url_supplied" {
  value = null
  precondition {
    condition     = var.redis_mode != "external" || var.redis_url != ""
    error_message = "redis_mode=\"external\" requires redis_url."
  }
}

output "_create_rds_requires_provisioning" {
  value = null
  precondition {
    condition     = !var.create_rds || var.deploy_cluster
    error_message = "create_rds=true requires deploy_cluster=true — RDS provisioning is only wired into the private-VPC path this flavor builds."
  }
}

output "_acm_sources_are_exclusive" {
  value = null
  precondition {
    condition     = !(var.acm_certificate_arn != "" && var.acm_request_certificate)
    error_message = "Set either acm_certificate_arn (a cert you already own) or acm_request_certificate=true (we request one), not both."
  }
}

output "_acm_certificate_arn_is_in_region" {
  value = null
  precondition {
    condition     = var.acm_certificate_arn == "" || can(regex("^arn:aws[a-z-]*:acm:${var.region}:", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must live in ${var.region}. An ALB can only use a certificate from its own region, and attaching a foreign-region ARN fails at the controller with no Ingress event."
  }
}

output "_acm_validation_zone_needs_a_request" {
  value = null
  precondition {
    condition     = var.acm_validation_route53_zone_id == "" || var.acm_request_certificate
    error_message = "acm_validation_route53_zone_id only applies to a certificate this flavor requests. Set acm_request_certificate=true, or drop the zone ID."
  }
}

output "_node_availability_zone_is_in_the_cluster" {
  value = null
  precondition {
    condition = var.node_availability_zone == "" || !var.deploy_cluster || contains(
      var.create_network ? var.availability_zones : [for sn in local.private_subnets : sn.az],
      var.node_availability_zone
    )
    error_message = "node_availability_zone must be an AZ the cluster actually has a private subnet in (availability_zones when this flavor creates the network, otherwise the AZs of your private_subnet_ids). Otherwise both node groups are created with an empty subnet list."
  }
}

# ── Reusing a network you brought (create_network = false) ───────────────────
# All of these are plan-time stops rather than check blocks, for the reason
# documented above: a check block only warns. Each one is a silent failure if
# it gets through, which is the test for belonging here.

output "_reuse_network_needs_a_vpc_and_subnets" {
  value = null
  precondition {
    condition     = !var.deploy_cluster || var.create_network || (var.vpc_id != "" && length(var.private_subnet_ids) > 0)
    error_message = "create_network=false means you are bringing the network, so vpc_id and private_subnet_ids are required. Set both, or leave create_network=true and let this flavor build a dedicated VPC."
  }
}

output "_network_inputs_match_the_posture" {
  value = null
  precondition {
    condition     = !var.create_network || (var.vpc_id == "" && length(var.private_subnet_ids) == 0 && length(var.public_subnet_ids) == 0)
    error_message = "vpc_id/private_subnet_ids/public_subnet_ids only apply when create_network=false. With create_network=true they are ignored, so an apply would build a new VPC and quietly leave your subnets unused. Set create_network=false, or remove them."
  }
}

output "_reused_subnets_belong_to_the_vpc" {
  value = null
  precondition {
    condition = alltrue([
      for sn in concat(values(data.aws_subnet.reused_private), values(data.aws_subnet.reused_public)) :
      sn.vpc_id == var.vpc_id
    ])
    error_message = "Every subnet in private_subnet_ids and public_subnet_ids must belong to vpc_id. A subnet from another VPC fails at cluster creation with an error that does not name the subnet."
  }
}

output "_reused_subnets_span_two_azs" {
  value = null
  precondition {
    condition     = !var.deploy_cluster || var.create_network || length(distinct([for sn in data.aws_subnet.reused_private : sn.availability_zone])) >= 2
    error_message = "EKS requires subnets in at least two availability zones and refuses to create a cluster otherwise. private_subnet_ids covers fewer than two AZs. This holds even when node_availability_zone pins the nodes into one of them."
  }
}
