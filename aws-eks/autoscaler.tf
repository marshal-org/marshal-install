# Kubernetes Cluster Autoscaler for the EKS managed node groups.
#
# GKE node pools autoscale natively; EKS managed node groups do not. Without
# this, a node group sits at its desired size forever and spaces beyond what one
# node holds stay Pending ("Insufficient cpu" / "Insufficient ephemeral-storage")
# while node_max_size is only a ceiling nothing ever approaches. The Marshal API
# already watches for the autoscaler's "TriggeredScaleUp" event on a Pending
# space (provisioner/watcher.go), so the platform side expects one to exist.
#
# Scale-DOWN safety for running spaces comes from how a space pod is built, not
# from a flag here: a space is a bare pod (no controller) with emptyDir volumes,
# and the autoscaler's defaults refuse to remove a node that holds either. So a
# node with a running space is never a scale-down candidate; once the space is
# stopped the pod is gone and the empty node can go. Do NOT set
# skip-nodes-with-local-storage=false or skip-nodes-with-custom-controller-pods
# =false in extra args: that is exactly what would let it evict a live space.
#
# Gated on deploy_cluster = true and enable_cluster_autoscaler. Customers who
# run Karpenter or their own autoscaler set enable_cluster_autoscaler = false.

data "aws_iam_policy_document" "cluster_autoscaler_assume_role" {
  count = local.provision && var.enable_cluster_autoscaler ? 1 : 0
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
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  count = local.provision && var.enable_cluster_autoscaler ? 1 : 0

  # Read-only discovery. These actions do not support resource-level limits.
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  # Changing capacity is limited to this cluster's own node groups: only ASGs
  # carrying the owned tag that the node groups below propagate to their ASG.
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  count  = local.provision && var.enable_cluster_autoscaler ? 1 : 0
  name   = "${var.cluster_name}-cluster-autoscaler-policy"
  policy = data.aws_iam_policy_document.cluster_autoscaler[0].json
}

resource "aws_iam_role" "cluster_autoscaler" {
  count              = local.provision && var.enable_cluster_autoscaler ? 1 : 0
  name               = "${var.cluster_name}-cluster-autoscaler-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume_role[0].json
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  count      = local.provision && var.enable_cluster_autoscaler ? 1 : 0
  role       = aws_iam_role.cluster_autoscaler[0].name
  policy_arn = aws_iam_policy.cluster_autoscaler[0].arn
}

resource "helm_release" "cluster_autoscaler" {
  count      = local.provision && var.enable_cluster_autoscaler ? 1 : 0
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"

  set {
    name  = "cloudProvider"
    value = "aws"
  }
  set {
    name  = "awsRegion"
    value = var.region
  }
  # Discovers node groups by the two tags set on aws_eks_node_group.* in
  # cluster.tf; no node group names to keep in sync.
  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "rbac.serviceAccount.create"
    value = "true"
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.cluster_autoscaler[0].arn
  }
  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }
  set {
    name  = "extraArgs.expander"
    value = "least-waste"
  }
  set {
    name  = "extraArgs.scale-down-unneeded-time"
    value = var.cluster_autoscaler_scale_down_unneeded_time
  }
  # Runs on the control-plane group when it is tainted, like the rest of the
  # platform, and never on a spaces node it would otherwise be blocking.
  dynamic "set" {
    for_each = var.taint_control_plane_pool ? { "nodeSelector.workload" = "control-plane" } : {}
    content {
      name  = set.key
      value = set.value
    }
  }
  dynamic "set" {
    for_each = var.taint_control_plane_pool ? { "tolerations[0].key" = "workload", "tolerations[0].operator" = "Equal", "tolerations[0].value" = "control-plane", "tolerations[0].effect" = "NoSchedule" } : {}
    content {
      name  = set.key
      value = set.value
    }
  }

  depends_on = [
    aws_eks_node_group.spaces,
    aws_eks_node_group.spaces_extra,
    aws_eks_node_group.control_plane,
    aws_iam_role_policy_attachment.cluster_autoscaler,
    aws_route_table_association.public,
    aws_route_table_association.private,
    aws_nat_gateway.this,
    # Destroyed after this release so the autoscaler is gone before the
    # network it needs; same reasoning as the load balancer controller.
    aws_security_group_rule.cluster_private_access,
  ]
}
