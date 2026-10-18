# modules/marshal-install

The cloud-agnostic guts of a Marshal install. Given a `kubernetes` + `helm`
provider pointed at a cluster (configured by the calling flavor), it:

1. creates the control-plane namespace,
2. creates the license (installation JWT) Secret,
3. creates the datastore DSN Secrets (external mode),
4. `helm install`s the Marshal umbrella chart with values assembled from inputs.

It declares **no** provider blocks — the flavor owns cluster connection + OCI
chart-registry login. Consume it like the flavors do:

```hcl
module "marshal" {
  source = "../modules/marshal-install"

  chart_version       = "0.5.0"
  installation_jwt    = var.installation_jwt
  deployment_id       = var.deployment_id
  registry_pull_token = var.registry_pull_token
  ingress_host        = "marshal.acme.com"

  # Recommended posture: external Postgres (source of truth) + bundled Redis.
  database_mode = "external"
  database_url  = var.database_url
  redis_mode    = "bundled"
}
```

## Input surface

Full, commented list in [`variables.tf`](variables.tf). Grouped:

| Group | Variables |
|---|---|
| Release identity | `release_name`, `namespace`, `create_namespace` |
| Chart | `chart`, `chart_version` |
| Credentials | `installation_jwt`, `deployment_id`, `registry_pull_token` |
| Registry | `image_cache_registry`, `registry`, `registry_auth_mode`, `registry_secret_server` |
| Datastores | `database_mode`, `redis_mode`, `database_url`, `redis_url` |
| Ingress / TLS | `ingress_host`, `ingress_enabled`, `ingress_class_name`, `ingress_annotations`, `ingress_tls`, `preview_domain`, `preview_scheme` |
| Session namespace | `spaces_namespace` |
| License tuning | `license_jwks_url`, `license_refresh_url`, `license_enforce` |
| Marketplace | `marketplace_upstream`, `marketplace_token_exchange_url`, `marketplace_customer_repos` |
| App secrets / KMS | `secrets_provider`, `secrets_existing_secret`, `secrets_external_secrets`, `kms_backend` |
| Web sign-in | `basic_auth_enabled` |
| Escape hatch | `values_overrides` |

Only `installation_jwt`, `chart_version`, and `ingress_host` have no default.

## Outputs

`namespace`, `spaces_namespace`, `release_name`, `chart_version`, `app_url`,
`preview_url_pattern`, `next_steps`.

## Registry postures

The effective image prefix (chart `global.registry`) is `image_cache_registry`
when set, else `registry`. Product images **and** per-session tool images resolve
under it.

- **Shared pull-through cache (recommended, required at scale)** — set
  `image_cache_registry` to the cache you run. It is a **customer-level** resource:
  **one per customer**, set up **once** (a registry mirror / Harbor proxy-cache /
  GCP AR remote repo / ECR pull-through cache) with the pull token in *its* upstream
  config, and **reused by every Marshal install** (prod, staging, …). It is **not**
  provisioned here. Pair with `registry_auth_mode = "workloadIdentity"` (nodes carry
  the identity) or `"none"` (open cache inside your network). Rationale:
  `registry.marshal.codes` is rate-limited, so the many per-session tool-image pulls
  must hit your cache, not our registry.
- **Direct pull** (`registry_auth_mode = "secret"`, default) — leave
  `image_cache_registry` empty; the chart builds a dockerconfigjson from
  `deployment_id` + `registry_pull_token`, replicates it into the sessions namespace,
  and stamps it on all pods. Simplest; good for a single-node eval.

## Datastore modes (Postgres and Redis are independent)

Recommended posture: **external Postgres + bundled Redis**.

- `database_mode` — `external` (default/recommended): supply `database_url`; the
  module stores it as a K8s Secret. Postgres is the source of truth (sessions,
  orgs, credentials, manifests, audit) and needs durability + backups. `bundled`
  is demo/eval only.
- `redis_mode` — `bundled` (default): in-cluster Redis. Everything in Redis is
  ephemeral/TTL'd/reconstructible (WS tokens, SSE streams, pod addresses, OAuth
  state, usage buffers) — nothing persistent is Redis-only — so managed Redis is
  an unnecessary cost. `external`: supply `redis_url` to point at managed Redis.

Secret DSN values never enter Helm release state. Both `bundled` paths use the
chart's in-cluster subcharts. Every chart value written here is cross-checked
against `marshal/infra/helm/marshal/values.yaml`.
