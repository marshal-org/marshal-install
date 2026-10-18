# Bastion — the only way to reach a private-only cluster (the default,
# cluster_endpoint_public_access=false): no public API endpoint means
# terraform/kubectl/helm must run from INSIDE the VPC. This bastion has no
# public IP and no open inbound ports at all — reachable only via AWS Systems
# Manager Session Manager (outbound-initiated, IAM-authenticated), the
# AWS-native equivalent of gcp-gke's IAP-tunneled bastion. Gated on
# deploy_cluster=true && create_bastion (default FALSE: only when there is no
# other path into the VPC, and then it is the machine you install FROM).
#
# Apply workflow once this exists: ship a `deploy` checkout to the bastion
# (e.g. via S3 — the bastion has NAT egress) and run terraform ON it, the same
# pattern the GCP flavor's installs use. The bastion is deliberately NOT given
# a GitHub credential, so ship the checkout rather than cloning it there.
# Session Manager gives an interactive shell (`aws ssm start-session --target <instance-id>`) with no
# SSH key to manage.

locals {
  # The length check is not defensive programming: with create_network=false and
  # no private_subnet_ids, main.tf's precondition already stops the plan with the
  # actionable message. Without this, the bastion ALSO fails on an empty index,
  # and the first error a reader sees reads like a bug in the installer rather
  # than a missing input.
  create_bastion = local.provision && var.create_bastion && length(local.private_subnet_ids) > 0
}

data "aws_ami" "al2023" {
  count       = local.create_bastion ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  # "al2023-ami-2023.*", NOT "al2023-ami-*": the looser pattern also matches
  # al2023-ami-MINIMAL-*, and with most_recent=true that is usually what wins.
  # The minimal image does not ship amazon-ssm-agent, so the bastion never
  # registers with Systems Manager, `aws ssm start-session` fails with
  # TargetNotConnected, and since the bastion has no public IP and no SSH key
  # there is then NO way into the VPC at all. Confirmed live: the filter picked
  # al2023-ami-minimal-2023.12.20261016.0 and SSM listed zero instances while
  # the instance was running, had its profile attached, and had NAT egress.
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_iam_role" "bastion" {
  count = local.create_bastion ? 1 : 0
  name  = "${var.cluster_name}-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# The bastion IS the intended place to run the REST of this apply from (once
# the cluster is private-only, this session can't reach the k8s API itself)
# — so its role needs to be able to actually do that: broad Describe/Get/List
# (ReadOnlyAccess) across EC2/EKS/IAM/RDS for `terraform refresh` on
# everything already in state, plus a scoped S3 policy for the state bucket
# (ReadOnlyAccess excludes s3:PutObject, needed for state writes/locking).
#
# The policy is chosen by var.bastion_install_permissions, because the two jobs
# a bastion gets used for need different grants. When the bastion runs the WHOLE
# install (the default, and the only sequence we document, since splitting an
# install across two machines is where installs go wrong) it has to CREATE the
# cluster, the IAM roles, the OIDC provider, the addons and the database, and
# read-only cannot. When it only finishes the Kubernetes half of an install
# started elsewhere, read-only plus the scoped policies below is enough.
#
# AdministratorAccess was once attached here and caused a genuinely confusing
# live failure: the instance stopped itself mid-apply.
# Root cause (confirmed via CloudTrail, not assumed): terraform running ON
# the bastion detected THIS FILE's own user_data heredoc had drifted from
# what was baked in at the bastion's actual boot (from earlier edits), and
# tried to reconcile it — but AWS's ModifyInstanceAttribute API requires
# STOPPING an instance to change its user_data, so terraform (holding
# AdministratorAccess at the time) stopped the very instance it was running
# on. Not external security governance, as first suspected — entirely
# self-inflicted, and fixed at the source via `lifecycle { ignore_changes =
# [user_data] }` on aws_instance.bastion below (user_data is boot-time-only
# anyway; changing it post-boot without an accompanying reboot wouldn't even
# take effect). That root cause is fixed, which is what makes the broad policy
# safe to offer again; set bastion_install_permissions = false to get the old
# read-only role back. Explicit EKS cluster-admin is separate
# (access_config.bootstrap_cluster_creator_admin_permissions only grants
# admin to the IDENTITY THAT CREATED the cluster — the bastion's own role
# gets none of that automatically and needs its own access entry, below).
resource "aws_iam_role_policy_attachment" "bastion_readonly" {
  count = local.create_bastion ? 1 : 0
  role  = aws_iam_role.bastion[0].name
  policy_arn = var.bastion_install_permissions ? (
    "arn:aws:iam::aws:policy/AdministratorAccess"
  ) : "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "bastion_state_bucket" {
  count = local.create_bastion ? 1 : 0
  name  = "${var.cluster_name}-bastion-state-bucket"
  role  = aws_iam_role.bastion[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = ["arn:aws:s3:::*tfstate*", "arn:aws:s3:::*tfstate*/*"]
    }]
  })
}

# ReadOnlyAccess doesn't cover this write action — needed because
# data.tls_certificate.eks does a LIVE fetch of the OIDC issuer's cert on
# every run, so a routine cert rotation upstream shows up as real thumbprint
# drift terraform legitimately needs to reconcile (confirmed live: a plain
# `terraform apply` from the bastion tried this and got AccessDenied).
# Scoped to only this cluster's own OIDC provider, not IAM account-wide.
resource "aws_iam_role_policy" "bastion_oidc_thumbprint" {
  count = local.create_bastion ? 1 : 0
  name  = "${var.cluster_name}-bastion-oidc-thumbprint"
  role  = aws_iam_role.bastion[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["iam:UpdateOpenIDConnectProviderThumbprint"]
      Resource = [aws_iam_openid_connect_provider.eks[0].arn]
    }]
  })
}

# ReadOnlyAccess doesn't cover ACM writes either — needed for alb_tls.tf's
# imported certificate (aws_acm_certificate.alb). Resource "*" is required
# specifically for acm:ImportCertificate (a brand-new cert has no ARN to
# scope to before it exists) — still ACM-only, nowhere near
# AdministratorAccess-broad.
resource "aws_iam_role_policy" "bastion_acm" {
  count = local.create_bastion ? 1 : 0
  name  = "${var.cluster_name}-bastion-acm"
  role  = aws_iam_role.bastion[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["acm:ImportCertificate", "acm:DeleteCertificate", "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate"]
      Resource = ["*"]
    }]
  })
}

# Confirmed live: the bastion's own security group has unrestricted egress,
# but that's not sufficient — the EKS control plane's private endpoint is
# served from ENIs governed by the cluster's OWN auto-created security group
# (aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id), which by
# default only allows the control plane <-> worker nodes, nothing about an
# arbitrary other instance in the VPC. Without this, kubectl/terraform/helm
# on the bastion get a silent i/o timeout (packets dropped, not refused) —
# looks identical to a DNS or routing problem but is actually a plain missing
# security group rule.
resource "aws_security_group_rule" "cluster_from_bastion" {
  count                    = local.create_bastion ? 1 : 0
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.bastion[0].id
  description              = "Allow the bastion to reach the EKS control plane (kubectl/terraform/helm)"
}

resource "aws_eks_access_entry" "bastion" {
  count         = local.create_bastion ? 1 : 0
  cluster_name  = aws_eks_cluster.this[0].name
  principal_arn = aws_iam_role.bastion[0].arn
}

# Both attributes come from the access ENTRY rather than from the cluster and
# the role, so Terraform has a dependency edge that orders these two. Without
# it they were created concurrently and the association lost the race:
#   ResourceNotFoundException: The requested resource does not exist
# A policy can only attach to an access entry that already exists. The entry
# was created, the association was not, and the bastion ended up with no
# cluster-admin binding at all, which is the one thing it is created for.
resource "aws_eks_access_policy_association" "bastion_admin" {
  count         = local.create_bastion ? 1 : 0
  cluster_name  = aws_eks_access_entry.bastion[0].cluster_name
  principal_arn = aws_eks_access_entry.bastion[0].principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count      = local.create_bastion ? 1 : 0
  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  count = local.create_bastion ? 1 : 0
  name  = "${var.cluster_name}-bastion-profile"
  role  = aws_iam_role.bastion[0].name
}

resource "aws_security_group" "bastion" {
  count       = local.create_bastion ? 1 : 0
  name        = "${var.cluster_name}-bastion-sg"
  description = "Bastion - no inbound rules at all; reachable only via SSM (outbound-initiated)"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-bastion-sg" }
}

resource "aws_instance" "bastion" {
  count                       = local.create_bastion ? 1 : 0
  ami                         = coalesce(var.bastion_ami_id, data.aws_ami.al2023[0].id)
  instance_type               = var.bastion_instance_type
  subnet_id                   = local.private_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.bastion[0].id]
  iam_instance_profile        = aws_iam_instance_profile.bastion[0].name
  associate_public_ip_address = false

  # Lean, minimal toolchain — just enough to run terraform/kubectl/helm from
  # here. SSM agent ships preinstalled on the AL2023 AMI; nothing to add for
  # Session Manager itself. kubectl is fetched via the version-agnostic
  # dl.k8s.io "stable-<minor>" indirection (not a guessed, date-pinned AWS S3
  # path) so it always matches whatever var.kubernetes_version is set to,
  # instead of silently drifting out of sync with the cluster.
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    # Present already on the standard AL2023 AMI. Installed here so that a
    # bastion_ami_id pointing at a minimal or custom image still becomes
    # reachable, instead of leaving no way into the VPC.
    dnf install -y amazon-ssm-agent || true
    systemctl enable --now amazon-ssm-agent || true
    dnf install -y git unzip
    # >= 1.10 required: an S3 backend override that uses S3's native
    # use_lockfile locking, which is not available before 1.10.
    curl -fsSL -o /tmp/terraform.zip https://releases.hashicorp.com/terraform/1.13.3/terraform_1.13.3_linux_amd64.zip
    unzip -o /tmp/terraform.zip -d /usr/local/bin
    KUBECTL_VERSION=$(curl -fsSL "https://dl.k8s.io/release/stable-${var.kubernetes_version}.txt")
    curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  EOT

  # Same race as the node groups (see their depends_on comment): the bastion
  # sits in a private subnet too, and SSM needs working NAT-routed egress to
  # reach ssm.<region>.amazonaws.com — without this it would boot onto the
  # VPC's default (no-NAT-route) main route table and never become reachable.
  depends_on = [aws_route_table_association.private]

  tags = { Name = "${var.cluster_name}-bastion" }

  # user_data only runs at first boot — editing this heredoc later (bumping a
  # tool version, etc.) has no effect on an already-running instance without
  # an explicit reboot anyway. Confirmed live this needs to be ignored: AWS's
  # ModifyInstanceAttribute API requires STOPPING the instance to change
  # user_data, so without this, terraform (running FROM the bastion, per the
  # apply workflow above) would try to stop the very instance it's running
  # on the moment this file's user_data heredoc changes underneath it —
  # taking itself down mid-apply, every time.
  lifecycle {
    ignore_changes = [user_data]
  }
}
