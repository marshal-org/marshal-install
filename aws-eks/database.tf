# Optional RDS Postgres provisioning — gated on deploy_cluster=true AND
# create_rds=true. UNLIKE gcp-gke (which never provisions Cloud SQL —
# "external" there only ever means "supply a DSN"), this flavor CAN also
# create the RDS instance itself: new surface area beyond GCP parity, added
# deliberately for a from-scratch AWS account with nothing pre-existing.
# Small/cheap defaults (variables.tf) — POC sizing, not production sizing.
#
# Mirrors single-node-k3s/datastores.tf's null-safety pattern: try()/one() are
# required because a conditional evaluates BOTH branches, so `random_password.
# postgres[0]` would throw "index 0 out of range" when create_rds=false (count
# = 0) without it.

locals {
  create_rds = local.provision && var.create_rds
}

resource "random_password" "postgres" {
  count   = local.create_rds ? 1 : 0
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "postgres" {
  count      = local.create_rds ? 1 : 0
  name       = "${var.cluster_name}-db-subnet-group"
  subnet_ids = local.private_subnet_ids
  tags       = { Name = "${var.cluster_name}-db-subnet-group" }
}

# Scoped to the cluster's own auto-created cluster security group — the
# correct "the EKS nodes" reference since node groups here use no custom
# launch template / security group of their own.
resource "aws_security_group" "rds" {
  count       = local.create_rds ? 1 : 0
  name        = "${var.cluster_name}-rds-sg"
  description = "Allow Postgres from the EKS cluster nodes"
  vpc_id      = local.vpc_id

  ingress {
    description     = "Postgres from cluster nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id]
  }

  dynamic "ingress" {
    for_each = local.create_rds ? var.rds_extra_ingress_cidrs : []
    content {
      description = "Extra RDS access (rds_extra_ingress_cidrs)"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-rds-sg" }
}

resource "aws_db_instance" "postgres" {
  count      = local.create_rds ? 1 : 0
  identifier = "${var.cluster_name}-postgres"

  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  allocated_storage = var.rds_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true
  multi_az          = var.rds_multi_az

  db_subnet_group_name   = aws_db_subnet_group.postgres[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  publicly_accessible    = false

  db_name  = var.rds_db_name
  username = var.rds_username
  password = random_password.postgres[0].result

  backup_retention_period = var.rds_backup_retention_period
  skip_final_snapshot     = var.rds_skip_final_snapshot
  # Required by the provider whenever a final snapshot is actually taken.
  # Deliberately stable rather than timestamped: a timestamp() here would show
  # a diff on every plan, and a duplicate-name failure on a second destroy is
  # loud and recoverable (delete or rename the old snapshot).
  final_snapshot_identifier = var.rds_skip_final_snapshot ? null : "${var.cluster_name}-postgres-final"
  deletion_protection       = var.rds_deletion_protection
  apply_immediately         = true

  tags = { Name = "${var.cluster_name}-postgres" }
}

locals {
  database_url = local.create_rds ? "postgres://${var.rds_username}:${try(random_password.postgres[0].result, "")}@${try(aws_db_instance.postgres[0].address, "")}:5432/${var.rds_db_name}?sslmode=require" : var.database_url
}
