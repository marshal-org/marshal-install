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
#
# The rules are standalone resources, not inline blocks, on purpose: an inline
# rule that names the cluster's security group makes the security group, and so
# the database that uses it, wait for the cluster to exist. The cluster takes
# about eight minutes and the database about ten, so inline rules serialise the
# two. With standalone rules the group and the database are created alongside the
# cluster and only the one rule waits for it.
#
# name_prefix plus create_before_destroy is what lets an install made with the
# older inline rules upgrade in place: the new group (with its rules) is created
# first, the database is moved onto it, and only then is the old group removed.
# A same-named group could not coexist with the old one, and rules added to the
# old group would collide with the inline ones already on it.
resource "aws_security_group" "rds" {
  count       = local.create_rds ? 1 : 0
  name_prefix = "${var.cluster_name}-rds-"
  description = "Allow Postgres from the EKS cluster nodes"
  vpc_id      = local.vpc_id

  tags = { Name = "${var.cluster_name}-rds-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_cluster" {
  count = local.create_rds ? 1 : 0

  security_group_id            = aws_security_group.rds[0].id
  description                  = "Postgres from cluster nodes"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_extra" {
  for_each = local.create_rds ? toset(var.rds_extra_ingress_cidrs) : toset([])

  security_group_id = aws_security_group.rds[0].id
  description       = "Extra RDS access (rds_extra_ingress_cidrs)"
  ip_protocol       = "-1"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "rds_all" {
  count = local.create_rds ? 1 : 0

  security_group_id = aws_security_group.rds[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
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
