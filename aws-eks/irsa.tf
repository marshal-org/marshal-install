# OIDC provider (IRSA's prerequisite) + the two cluster-level addons EKS does
# NOT give you for free the way GKE does: the EBS CSI driver (needed for the
# chart's bundled Redis PVC to bind at all) and the AWS Load Balancer
# Controller (needed for the Ingress to get an address at all). ALL gated on
# deploy_cluster=true — the reuse path assumes these already exist on the
# BYO cluster (see README.md's Prerequisites section).
#
# The OIDC provider is created UNCONDITIONALLY whenever provisioning — no
# duplicate-registration risk here, since the cluster itself is always
# brand-new in this path (a BYO/reuse cluster that already has one wired is a
# different, later problem this flavor doesn't need to solve yet).

data "tls_certificate" "eks" {
  count = local.provision ? 1 : 0
  url   = aws_eks_cluster.this[0].identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  count           = local.provision ? 1 : 0
  url             = aws_eks_cluster.this[0].identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks[0].certificates[0].sha1_fingerprint]
}

locals {
  oidc_provider_arn = local.provision ? aws_iam_openid_connect_provider.eks[0].arn : null
  oidc_provider_url = local.provision ? replace(aws_iam_openid_connect_provider.eks[0].url, "https://", "") : null
}

# ── EBS CSI driver (EKS-managed addon) ────────────────────────────────────────
# EKS does NOT enable this by default (unlike GKE's PD CSI driver) — without
# it, the chart's bundled (default) in-cluster Redis PVC never binds and the
# install stalls waiting for that pod to become Ready.

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  count = local.provision ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  count              = local.provision ? 1 : 0
  name               = "${var.cluster_name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role[0].json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = local.provision ? 1 : 0
  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  count                       = local.provision ? 1 : 0
  cluster_name                = aws_eks_cluster.this[0].name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi[0].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.spaces, aws_eks_node_group.control_plane]
}

# Installing the EBS CSI driver addon is NOT enough by itself — confirmed
# live: the bundled Redis PVC sat Pending forever with "no persistent
# volumes available for this claim and no storage class is set", which
# cascaded into marshal-api CrashLoopBackOff (api can't reach a Redis that
# never comes up). Unlike GKE, which ships a default StorageClass backed by
# its PD CSI driver out of the box, EKS creates none automatically even with
# the addon installed — an explicit default StorageClass is required.
resource "kubernetes_storage_class" "gp3" {
  count = local.provision ? 1 : 0

  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type = "gp3"
  }

  depends_on = [
    aws_eks_addon.ebs_csi,
    # Destroyed AFTER this resource, which is the point: it is the rule that
    # lets this host reach the API at all. Without the edge, terraform removed
    # it first and then could not delete what was left, failing the destroy
    # with `dial tcp <endpoint>:443: i/o timeout`.
    aws_security_group_rule.cluster_private_access,
  ]
}

# ── metrics-server (EKS-managed addon) ────────────────────────────────────────
# EKS does NOT enable this by default either — without it there's no
# metrics.k8s.io APIService at all, so `kubectl top` and any HPA on
# CPU/memory silently have nothing to read from. Confirmed live on a cluster
# that ran for weeks with only AWS's own unrelated eks-extension-metrics-api
# present, which does not back metrics.k8s.io. No IRSA role needed, unlike EBS CSI
# or the ALB controller, it only calls the in-cluster kubelet API, never AWS's.
resource "aws_eks_addon" "metrics_server" {
  count                       = local.provision ? 1 : 0
  cluster_name                = aws_eks_cluster.this[0].name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.spaces, aws_eks_node_group.control_plane]
}

# ── AWS Load Balancer Controller (NOT an EKS-managed addon — must be Helm-
#    installed) ────────────────────────────────────────────────────────────────
# The IAM policy JSON is VENDORED (aws-eks/policies/alb_iam_policy.json,
# copied by hand from kubernetes-sigs/aws-load-balancer-controller's
# docs/install/iam_policy.json at a pinned release tag) rather than fetched
# live mid-apply — that would be an uncontrolled network + supply-chain
# dependency inside `terraform apply`. Re-vendor deliberately whenever the
# chart version below is bumped; a stale copy can silently miss newer required
# actions rather than fail loudly.

resource "aws_iam_policy" "alb_controller" {
  count  = local.provision ? 1 : 0
  name   = "${var.cluster_name}-alb-controller-policy"
  policy = file("${path.module}/policies/alb_iam_policy.json")
}

data "aws_iam_policy_document" "alb_controller_assume_role" {
  count = local.provision ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  count              = local.provision ? 1 : 0
  name               = "${var.cluster_name}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role[0].json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  count      = local.provision ? 1 : 0
  role       = aws_iam_role.alb_controller[0].name
  policy_arn = aws_iam_policy.alb_controller[0].arn
}

resource "helm_release" "aws_load_balancer_controller" {
  count      = local.provision ? 1 : 0
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = local.vpc_id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller[0].arn
  }
  set {
    name  = "replicaCount"
    value = "1" # POC — chart's own default is 2; halve for cost.
  }

  # The last three are about DESTROY order, not create order.
  #
  # terraform destroy deadlocked without them. Terraform removed
  # aws_route_table.public and its associations early, which took away the NAT
  # gateway's own path to the internet. The controller then could not refresh
  # its IRSA credentials:
  #
  #   AssumeRoleWithWebIdentity ... Post "https://sts.eu-north-1.amazonaws.com/":
  #   dial tcp: i/o timeout
  #
  # so it never removed the ingress.k8s.aws/resources finalizer from the
  # Ingress, so `helm uninstall marshal` blocked on a namespace that would
  # never empty. Ten minutes in, the only way out was to clear the finalizer by
  # hand, which orphans the ALB and its target groups in AWS because the
  # controller is the only thing that deletes them.
  #
  # Naming the egress resources here makes Terraform destroy every Kubernetes
  # object before the network that Kubernetes needs in order to be cleaned up.
  # module.marshal already depends on this release, so the order becomes
  # marshal release, then this controller, then the routes and NAT.
  depends_on = [
    aws_eks_node_group.spaces,
    aws_eks_node_group.control_plane,
    aws_iam_openid_connect_provider.eks,
    aws_route_table_association.public,
    aws_route_table_association.private,
    aws_nat_gateway.this,
    # Destroyed AFTER this resource, which is the point: it is the rule that
    # lets this host reach the API at all. Without the edge, terraform removed
    # it first and then could not delete what was left, failing the destroy
    # with `dial tcp <endpoint>:443: i/o timeout`.
    aws_security_group_rule.cluster_private_access,
  ]
}
