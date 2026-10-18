# ── Object storage buckets (optional) ────────────────────────────────────────
# Mirrors gcp-gke/buckets.tf's design exactly — two INDEPENDENT buckets the
# api can use, per apps/api/internal/audit/cloud.go (audit persistence —
# WAL-flushed compliance export) and .../spacestorage (spaces persistence —
# session pause/resume snapshots) — both consume storage via gocloud.dev/blob
# (s3://) with ambient auth, so on EKS that's IRSA, mirroring how
# registry_auth_mode=workloadIdentity already works generically for GKE/EKS
# image pulls.
#
# Off by default, toggled separately — you may want one feature without the
# other. Creating a bucket doesn't itself turn the feature on; an org admin
# still wires the actual bucket URL via the API afterward (audit: per-org
# config; spaces: PUT /api/org/space-storage — see the chart's NOTES.txt).
# This just provisions the storage + access so that Day-2 step has somewhere
# to point at.

variable "create_audit_persistence_bucket" {
  description = "Create the audit-persistence S3 bucket (compliance export) + bind it to the api's KSA via IRSA. false (default) creates nothing — bring your own bucket/credentials instead."
  type        = bool
  default     = false
}

variable "create_spaces_persistence_bucket" {
  description = "Create the spaces-persistence S3 bucket (session pause/resume snapshots) + bind it to the api's KSA via IRSA. false (default) creates nothing — bring your own bucket/credentials instead."
  type        = bool
  default     = false
}

locals {
  create_any_storage_bucket = var.create_audit_persistence_bucket || var.create_spaces_persistence_bucket
  create_storage            = local.provision && local.create_any_storage_bucket

  # S3 bucket names are globally unique across ALL of AWS — cluster_name +
  # account_id keeps collisions extremely unlikely without an operator having
  # to pick names themselves, same reasoning as gcp-gke's project_id+cluster_
  # name naming and this flavor's own harbor cache bucket (harbor.tf).
  #
  # one()+try() rather than [0] because a LOCAL is evaluated whenever anything
  # in the graph references it, even when the only referencing resources have
  # count = 0. Both toggles default to false, so a plain [0] made
  # `terraform plan` fail on this line for every install that leaves the
  # documented defaults alone. (harbor.tf gets away with [0] because its index
  # sits in a counted resource's own attribute, which is never evaluated when
  # that count is 0.) Empty is harmless: the names are only ever read by
  # resources that exist exactly when the data source does.
  storage_account_id             = try(one(data.aws_caller_identity.storage[*]).account_id, "")
  audit_persistence_bucket_name  = "${var.cluster_name}-audit-persistence-${local.storage_account_id}"
  spaces_persistence_bucket_name = "${var.cluster_name}-spaces-persistence-${local.storage_account_id}"

  # Subjects allowed to assume the shared storage role: the api's KSA
  # whenever EITHER bucket is on, the supervisor's KSA only for the spaces
  # bucket specifically — same asymmetry gcp-gke's buckets.tf documents (the
  # supervisor does the runtime snapshot/restore blob I/O in session pods,
  # separate namespace from the api; it never touches the audit bucket).
  # spaces_namespace mirrors modules/marshal-install's own default
  # derivation ("<release_name>-spaces") since this flavor doesn't override
  # var.spaces_namespace.
  storage_irsa_subjects = concat(
    local.create_any_storage_bucket ? ["system:serviceaccount:${var.namespace}:${var.release_name}-api"] : [],
    var.create_spaces_persistence_bucket ? ["system:serviceaccount:${var.release_name}-spaces:${var.release_name}-supervisor"] : [],
  )
}

data "aws_caller_identity" "storage" {
  count = local.create_storage ? 1 : 0
}

# ── S3 buckets ────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "audit_persistence" {
  count         = local.provision && var.create_audit_persistence_bucket ? 1 : 0
  bucket        = local.audit_persistence_bucket_name
  force_destroy = false # real compliance data — never disposable, unlike harbor's cache bucket.

  tags = { Name = local.audit_persistence_bucket_name }
}

resource "aws_s3_bucket_versioning" "audit_persistence" {
  count  = local.provision && var.create_audit_persistence_bucket ? 1 : 0
  bucket = aws_s3_bucket.audit_persistence[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket" "spaces_persistence" {
  count         = local.provision && var.create_spaces_persistence_bucket ? 1 : 0
  bucket        = local.spaces_persistence_bucket_name
  force_destroy = false

  tags = { Name = local.spaces_persistence_bucket_name }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit_persistence" {
  count  = local.provision && var.create_audit_persistence_bucket ? 1 : 0
  bucket = aws_s3_bucket.audit_persistence[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "spaces_persistence" {
  count  = local.provision && var.create_spaces_persistence_bucket ? 1 : 0
  bucket = aws_s3_bucket.spaces_persistence[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit_persistence" {
  count                   = local.provision && var.create_audit_persistence_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.audit_persistence[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "spaces_persistence" {
  count                   = local.provision && var.create_spaces_persistence_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.spaces_persistence[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── IRSA — one shared role for both buckets (same pattern as gcp-gke's one
#    shared GSA), object-level access only, scoped per-bucket ──────────────
data "aws_iam_policy_document" "storage_assume_role" {
  count = local.create_storage ? 1 : 0
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
      values   = local.storage_irsa_subjects
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "storage" {
  count              = local.create_storage ? 1 : 0
  name               = "${var.cluster_name}-storage-role"
  assume_role_policy = data.aws_iam_policy_document.storage_assume_role[0].json
}

data "aws_iam_policy_document" "storage_s3" {
  count = local.create_storage ? 1 : 0

  dynamic "statement" {
    for_each = var.create_audit_persistence_bucket ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.audit_persistence[0].arn]
    }
  }
  dynamic "statement" {
    for_each = var.create_audit_persistence_bucket ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${aws_s3_bucket.audit_persistence[0].arn}/*"]
    }
  }
  dynamic "statement" {
    for_each = var.create_spaces_persistence_bucket ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.spaces_persistence[0].arn]
    }
  }
  dynamic "statement" {
    for_each = var.create_spaces_persistence_bucket ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${aws_s3_bucket.spaces_persistence[0].arn}/*"]
    }
  }
}

resource "aws_iam_role_policy" "storage_s3" {
  count  = local.create_storage ? 1 : 0
  name   = "${var.cluster_name}-storage-s3"
  role   = aws_iam_role.storage[0].id
  policy = data.aws_iam_policy_document.storage_s3[0].json
}

output "audit_persistence_bucket" {
  description = "s3:// URL for the audit-persistence bucket, once you're ready to wire it via the per-org audit API config."
  value       = var.create_audit_persistence_bucket ? "s3://${aws_s3_bucket.audit_persistence[0].bucket}" : null
}

output "spaces_persistence_bucket" {
  description = "s3:// URL for the spaces-persistence bucket — wire via PUT /api/org/space-storage (provider=s3)."
  value       = var.create_spaces_persistence_bucket ? "s3://${aws_s3_bucket.spaces_persistence[0].bucket}" : null
}
