# The control-plane namespace + (optionally) a minimal in-cluster Postgres 16.
# This flavor owns the namespace (the shared module is called with
# create_namespace=false) so the Postgres resources can live in it.
#
# Redis is NOT deployed here: with provision_datastores=true the chart's bundled
# Redis runs (redis_mode="bundled", see main.tf), on a local-path PVC, with the
# ACL users and password Secret the shared module generates.
#
# The chart's bundled Postgres is intentionally NOT used — this hand-rolled one is
# simpler for a single node. It has no HA/backups: fine for evaluation, not for
# durable production (use provision_datastores=false + a managed datastore).

locals {
  # In-cluster datastores only in the INSTALL path (deploy_cluster = false). In the
  # provision-only path no k8s resources are created here.
  install   = !var.deploy_cluster
  provision = local.install && var.provision_datastores

  # Postgres DSN handed to the install module. When we provision the in-cluster
  # Postgres we build it from the Service name + generated password; otherwise
  # pass through.
  # try(...) is null-safe: a conditional evaluates BOTH branches, so indexing [0]
  # here would blow up ("index 0 out of range") when provision_datastores = false
  # and random_password.postgres has count = 0. The "" fallback also keeps the
  # (unused) template from failing on a null interpolation.
  database_url = local.provision ? "postgres://marshal:${try(random_password.postgres[0].result, "")}@marshal-postgres.${var.namespace}.svc.cluster.local:5432/marshal?sslmode=disable" : var.database_url
}

resource "kubernetes_namespace" "marshal" {
  count = local.install ? 1 : 0
  metadata {
    name   = var.namespace
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

# ── Postgres ─────────────────────────────────────────────────────────────────
resource "random_password" "postgres" {
  count   = local.provision ? 1 : 0
  length  = 24
  special = false
}

resource "kubernetes_secret" "postgres" {
  count = local.provision ? 1 : 0
  metadata {
    name      = "marshal-postgres"
    namespace = kubernetes_namespace.marshal[0].metadata[0].name
  }
  data = {
    POSTGRES_USER     = "marshal"
    POSTGRES_DB       = "marshal"
    POSTGRES_PASSWORD = random_password.postgres[0].result
  }
}

resource "kubernetes_persistent_volume_claim" "postgres" {
  count = local.provision ? 1 : 0
  metadata {
    name      = "marshal-postgres"
    namespace = kubernetes_namespace.marshal[0].metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class != "" ? var.storage_class : null
    resources {
      requests = { storage = var.postgres_storage }
    }
  }
  # local-path binds the PV only once a consumer pod is scheduled.
  wait_until_bound = false
}

resource "kubernetes_deployment" "postgres" {
  count = local.provision ? 1 : 0
  metadata {
    name      = "marshal-postgres"
    namespace = kubernetes_namespace.marshal[0].metadata[0].name
    labels    = { app = "marshal-postgres" }
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = { app = "marshal-postgres" } }
    template {
      metadata { labels = { app = "marshal-postgres" } }
      spec {
        container {
          name  = "postgres"
          image = var.postgres_image
          port { container_port = 5432 }
          env_from {
            secret_ref { name = kubernetes_secret.postgres[0].metadata[0].name }
          }
          # Keep data out of the volume root so the mount stays clean.
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          readiness_probe {
            exec { command = ["pg_isready", "-U", "marshal", "-d", "marshal"] }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.postgres[0].metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "postgres" {
  count = local.provision ? 1 : 0
  metadata {
    name      = "marshal-postgres"
    namespace = kubernetes_namespace.marshal[0].metadata[0].name
  }
  spec {
    selector = { app = "marshal-postgres" }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}
