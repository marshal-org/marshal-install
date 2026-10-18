# gcp-gke

Install Marshal on **GKE**. Two postures via `deploy_cluster`:

- **reuse** (`deploy_cluster = false`, default) — install onto an existing GKE
  cluster you already run.
- **provision** (`deploy_cluster = true`) — Terraform creates a **private** GKE
  cluster (private nodes + Cloud NAT + internal ingress), then installs onto it.

All install logic is in [`../modules/marshal-install`](../modules/marshal-install);
this flavor wires the providers to the cluster and supplies GKE-appropriate
defaults.

## Prerequisites

- `terraform ≥ 1.5`, `gcloud`, `kubectl`, `helm ≥ 3.14`.
- Application Default Credentials — `gcloud auth application-default login`.
  Reuse needs `container.clusters.get`; provisioning needs `container.admin` +
  compute network admin on the project.
- A **Postgres 16** the cluster can reach over the VPC (Cloud SQL private IP) —
  Postgres is the durable source of truth (external is recommended). Redis is
  in-cluster by default (see [Datastores](#datastores)).
- Your Marshal onboarding credentials (installation JWT + `dep_` id + `mrpt_`
  pull token) — see **[Credentials](../README.md#credentials-read-this-first)** in
  the top-level README for what they are, where to get them, and a pre-flight
  `helm registry login` / `helm pull` check.

## Install

```bash
cp ../examples/gcp-gke.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
terraform init
terraform apply
terraform output next_steps
```

The providers authenticate to the cluster with a short-lived GCP token from your
ADC — no kubeconfig file is read or written.

## Inputs

Reuse posture requires: `project_id`, `cluster_name`, `location`,
`installation_jwt`, `deployment_id`, `registry_pull_token`, `chart_version`,
`ingress_host`, and (external Postgres) `database_url`. See
[`variables.tf`](variables.tf) for the fully-commented list.

## Datastores (Postgres external, Redis bundled)

Postgres and Redis are configured **independently**:

- **`database_mode = "external"`** (recommended) — supply `database_url` pointing
  at managed **Cloud SQL** (private IP). Postgres holds everything durable
  (sessions, orgs, credentials, manifests, audit), so it wants backups + HA that
  a managed service provides.
- **`redis_mode = "bundled"`** (default) — Redis runs **in-cluster**. Everything
  Marshal keeps in Redis is ephemeral/TTL'd/reconstructible (WS tokens, SSE
  streams, pod addresses, OAuth state, usage buffers) — nothing persistent is
  Redis-only — so paying for managed Memorystore buys durability Marshal doesn't
  need. Set `redis_mode = "external"` + `redis_url` if you already run managed
  Redis and prefer to point at it.

```hcl
database_mode = "external"
database_url  = "postgres://marshal:PW@10.20.0.5:5432/marshal?sslmode=require"
redis_mode    = "bundled"
```

### `redis_mode = "bundled"` on chart ≤0.5.0: image pull fix required

Bitnami retired every version-pinned tag from the free `bitnami/*` Docker Hub
namespace — the bundled Redis (and Postgres) Bitnami subcharts' own default
image refs 404 (`ImagePullBackOff`, "not found") on any chart older than
0.8.0. Confirmed live during a POC install. Fixed in the chart from 0.8.0 on;
until you are on a fixed chart version, override it yourself:

```hcl
values_overrides = [
  <<-EOT
  redis:
    image:
      repository: bitnamilegacy/redis
  EOT
]
```

`bitnamilegacy/*` is Bitnami's own migration path and mirrors the exact same
tags — not an upgrade, just an unblock. If you'd rather sidestep the bundled
Bitnami subcharts entirely, `redis_mode = "external"` (a small Memorystore
instance, or any Redis 7 you already run) avoids this class of problem for
good — worth considering given Redis holds no durable state anyway, so the
only thing "bundled" saves you is the cost of a tiny managed instance.

## Ingress / TLS (internal by default, HTTPS by default)

**`ingress_host` is a required decision on day one, not a Day-2 detail** — the
variable has no default, so `terraform plan` fails without it even if you have
no real DNS yet. You don't need working DNS to apply: pick the hostname you
intend to use (or a placeholder), apply, then point DNS at the internal LB's IP
whenever it's convenient — the Ingress just needs *a* Host value to route on.

Marshal is internal-only, so `internal_ingress = true` (default) uses GKE's
**internal** load balancer (IngressClass `gce-internal`) — reachable only inside
your VPC. Point `ingress_host` DNS at the internal IP.

**HTTPS is on by default** (`tls_mode = "self_signed"`) — Terraform generates a
placeholder cert (Subject `O=Marshal Platform Temp Cert`, so it's unmistakable
in any cert viewer) and manages the k8s Secret for you. Replace it whenever
you're ready with `tls_mode = "inline"` (paste real PEM into tfvars) or
`tls_mode = "secret"` (point `tls_secret_name` at a Secret you manage yourself,
e.g. via cert-manager) — no other config needs to change either way. Set
`tls_mode = "none"` to go back to HTTP-only.

> **Wildcard preview certs are NOT straightforward — read this before relying on a
> real cert for `preview_domain`.** The Ingress needs a cert covering
> `*.${preview_domain}` (every session gets its own preview subdomain), and
> wildcard certs have real constraints the default `tls_mode` docs above gloss
> over:
> - **The self-signed placeholder DOES cover it correctly** — the generated cert's
>   SAN list always includes `*.${preview_domain}` alongside `ingress_host` (see
>   `modules/marshal-install/tls.tf`), so previews work out of the box, just with
>   the same placeholder-cert browser warning as the main host.
> - **GKE-managed certs (`networking.gke.io/managed-certificates`) do NOT support
>   wildcard domains at all** — Google's managed-cert product only issues for exact
>   hostnames. Don't reach for this option if you need the preview domain covered;
>   it will simply never provision for a `*.` entry.
> - **cert-manager needs a DNS-01 solver for a wildcard, not the default HTTP-01** —
>   HTTP-01 can only prove control of one exact hostname per challenge, which is
>   structurally impossible for `*.${preview_domain}` (there's no single backend to
>   serve the challenge response for every possible subdomain). Your cert-manager
>   `ClusterIssuer` needs a DNS-01 solver (e.g. `cloudDNS`/`route53`/`cloudflare`)
>   configured for the preview domain's zone, or the cert request will stay pending
>   forever with no obvious error pointing at "wildcard" as the cause.
> - No `preview_domain` set? None of this applies — the cert only needs to cover
>   `ingress_host`, an exact hostname, which every option above handles natively.

Serving both HTTP and HTTPS on `gce-internal`'s single address requires a
**static IP** — `create_ingress_static_ip = true` (default, whenever
`internal_ingress = true` and `tls_mode != "none"`) reserves one for you
automatically (`Purpose=SHARED_LOADBALANCER_VIP`) and wires the
`kubernetes.io/ingress.regional-static-ip-name` annotation in automatically —
no manual `ingress_annotations` needed for this anymore.

> **Migrating an already-applied HTTP-only install to this default:** the
> existing ephemeral ingress IP can't be promoted to static in-place (a plain
> `gcloud compute addresses create --addresses <existing-ip>` 409s — "already
> in use"). One-time runbook, accepting a brief window of downtime:
> ```bash
> gcloud compute forwarding-rules delete <old-http-forwarding-rule> --project=<p> --region=<r>
> gcloud compute addresses create <name> --project=<p> --region=<r> \
>   --subnet=<subnet> --purpose=SHARED_LOADBALANCER_VIP --addresses=<the-existing-ip>
> terraform import google_compute_address.ingress[0] projects/<p>/regions/<r>/addresses/<name>
> terraform apply
> ```
> Not ready for this yet? Set `tls_mode = "none"` to keep the old HTTP-only
> behavior indefinitely. New installs need none of this — there's nothing
> pre-existing to conflict with.

Set `internal_ingress = false` (uses `ingress_class_name`, default `gce`) only if
you deliberately expose Marshal via an external GCLB. Prefer ingress-nginx /
cert-manager for TLS instead of `tls_mode`? Set `internal_ingress = false`,
`ingress_class_name` to your nginx class, and use `ingress_tls` (the low-level
escape hatch — always wins over `tls_mode`) with a cert-manager issuer
annotation.

## Node pools: control-plane vs. spaces_pools (isolated by default, taint gated)

Session/space workloads run across however many pools `spaces_pools` (a map,
keyed by a short pool-name suffix) defines — one `google_container_node_pool`
per entry, named `<cluster_name>-<key>-pool` and labeled `workload=<key>`.
Default is a single `spaces` entry (`e2-standard-4`, 100GB, autoscaling
1-5/zone) — an install that sets nothing here gets that one pool, same as
before this was generalized. Add more entries for more pools, e.g. a bigger
machine for heavier sessions:

```hcl
spaces_pools = {
  spaces = { machine_type = "e2-standard-8", disk_size_gb = 200, min_node_count = 2, max_node_count = 10 }
  big    = { machine_type = "e2-standard-16", disk_size_gb = 200, min_node_count = 0, max_node_count = 4 }
}
```

Every entry shares `node_sysctls` (default raises `fs.inotify.max_user_watches`
to 1048576 and `max_user_instances` to 8192 — GKE's default, ~8192-12288, is
easy to exhaust with a handful of file-watching containers sharing a node,
and watches are cheap, ~1KB kernel memory each) and `node_pool_max_surge`/
`node_pool_max_unavailable`. Each entry is untainted by default (`taint =
false`) — plain extra capacity any spaces pod can land on by ordinary
scheduling, no chart change required. Set `taint = true` on an entry only if
you're scheduling something onto it some other way (a manual `nodeSelector`/
toleration) — there's no chart-side wiring that tolerates a `spaces_pools`
taint automatically (unlike control-plane's, below).

`control_plane` stays a separate, dedicated pool — never share machine
type/disk/sysctls with `spaces_pools`:

- **`control_plane`** (`control_plane_machine_type`/`control_plane_disk_size_gb`/
  `control_plane_min_node_count`/`control_plane_max_node_count`) — a separate
  pool for the long-lived api/gateway/web/marketplace/redis pods only.
  Default `e2-standard-8` (**not** a smaller machine type — the chart's own
  baseline of 2 replicas each for api/gateway/web/marketplace already sums to
  ~4.4 vCPU of requests before HPA scales out further, which doesn't fit an
  e2-standard-4's ~3.9 vCPU allocatable; confirmed live, pods stuck Pending on
  "Insufficient cpu"). The real, deliberately-smaller distinction from the
  spaces pool is disk — 50GB default vs. 100GB, since control-plane has no
  per-session ephemeral-storage demand.
  > **Regional disk quota** (`SSD_TOTAL_GB`, default 500GB) bites here too if
  > you're already close to it from the spaces pool's own 100GB×N nodes —
  > `control_plane_max_node_count` scaling to 2 needs another
  > `control_plane_disk_size_gb` worth of headroom, and the failure mode is
  > the same silently-stuck-Pending symptom (`gcloud compute
  > instance-groups managed list-errors <mig> --zone=<zone>` shows
  > `QUOTA_EXCEEDED` on `SSD_TOTAL_GB`, not a CPU quota). If you're tight on
  > disk quota, pin `control_plane_max_node_count = 1` rather than raising
  > the machine type further — the fix for insufficient *CPU* is a bigger
  > machine; the fix for insufficient *disk quota* is fewer nodes.
  >
  > **`control_plane_max_node_count = 1` has its own trap**, hit live
  > migrating an already-running install: a machine-type change (or any
  > `node_config` change) cordons + drains the node before replacing it, and
  > drain respects PodDisruptionBudgets. The chart sets `minAvailable: 1` per
  > control-plane component — with only ONE control-plane node, draining it
  > means evicting the LAST remaining replica of every component
  > simultaneously, which the PDB will never allow (`ALLOWED DISRUPTIONS: 0`
  > on `kubectl get pdb -n marshal`). The node sits `Ready,SchedulingDisabled`
  > forever; the GKE operation stays `RUNNING` server-side well past
  > Terraform's own wait timeout (30m) with no forward progress. There's no
  > clean fix with only 1 node available — either scale to
  > `control_plane_max_node_count = 2` first (needs disk quota, see above) so
  > pods have somewhere to go during the drain, or temporarily
  > `kubectl delete pdb -n marshal marshal-api marshal-gateway marshal-marketplace marshal-web`
  > to unblock it (control-plane pods
  > briefly all reschedule at once — fine for a planned maintenance window,
  > not something to do silently) and let the next `helm upgrade`/
  > `terraform apply` recreate them (Helm reconciles them back; nothing here
  > is Terraform-managed).

Both pools exist unconditionally when `deploy_cluster = true`. Whether the
split actually **isolates** anything depends on `taint_control_plane_pool`
(bool, **default `false`**) — a deliberate safety gate. Flipping it to `true`
does BOTH of the following in the same apply (see `main.tf`'s
`control_plane_node_selector`/`control_plane_tolerations` locals, derived from
this one toggle — never set independently):
- Taints the control-plane pool `NoSchedule` (`cluster.tf`).
- Sets the module's `control_plane_node_selector`/`control_plane_tolerations`,
  which flow straight into the chart's `controlPlane.nodeSelector`/
  `tolerations` values — so the taint and its matching toleration always land
  atomically, never as two separately-sequenced changes.

The remaining real precondition: the Marshal chart must already be
running a version with `controlPlane.nodeSelector`/`tolerations` WIRING
(chart **>= 0.9.0**) on the target cluster *before* you flip this — an older
chart version silently ignores those values, so its control-plane pods would
carry no toleration and become unschedulable the instant the taint lands (an
outage). Bump `chart_version` to >= 0.9.0, confirm the cluster is healthy,
*then* flip `taint_control_plane_pool = true`, in that order, on any
already-running cluster.

Space pods need no corresponding change: they carry no toleration, so once
the control-plane pool is tainted they simply can't land there and settle on
the (untainted) spaces pool by elimination. New installs on chart >= 0.9.0
can set `taint_control_plane_pool = true` from day one with no ordering
risk — there's nothing pre-existing to disrupt.

Same regional `SSD_TOTAL_GB` quota constraint applies across every pool in
`spaces_pools` plus `control_plane` — check headroom
(`gcloud compute regions describe <region> --format="value(quotas)"`) before
adding entries or raising `disk_size_gb`/`max_node_count`.

## Provisioning a private cluster (`deploy_cluster = true`)

Terraform creates, all in one apply, then installs onto it:

- **Private nodes** (`enable_private_nodes` — no public node IPs).
- **Locked-down control plane** — private endpoint by default
  (`enable_private_endpoint = true`) with **master authorized networks** (you must
  set `master_authorized_networks` to at least your admin/VPN CIDR, else you lock
  yourself out). Set `enable_private_endpoint = false` for a public-but-authorized
  endpoint if you administer from outside the VPC.
- **Cloud Router + Cloud NAT** (`create_nat`, default on) — REQUIRED so private
  nodes can egress to pull images from `registry.marshal.codes` and reach the
  license/token hosts. Without it the install fails on image pulls.
- **Networking** — `create_network = true` (default) makes a dedicated VPC +
  subnet with secondary ranges for pods/services; or `create_network = false` and
  set `network`/`subnetwork`/`pods_range_name`/`services_range_name` to reuse
  yours.
- **Workload Identity** enabled (keyless GCP/AR auth) — pairs with
  `registry_auth_mode = "workloadIdentity"`.
- **Node pool(s)** — `spaces_pools` (map, default a single `spaces` entry:
  `e2-standard-4`, autoscaling 1-5/zone, 100GB), each entry's `machine_type` /
  autoscaling (`min_node_count`..`max_node_count`, or a fixed `node_count`) /
  `disk_size_gb` / `disk_type`; `release_channel` / `kubernetes_version` apply
  cluster-wide. `disk_size_gb` sizes for **ephemeral-storage**, not just
  capacity — session pods request 10-20GiB ephemeral-storage each, and GKE
  reserves a large chunk of the boot disk for OS/image cache, so a 100GB disk
  fits far fewer concurrent spaces than CPU/memory alone would suggest.
  Before committing to a pool's `machine_type` × `max_node_count` ×
  `disk_size_gb`, check the project's `CPUS_ALL_REGIONS` **and** regional
  `SSD_TOTAL_GB` quotas (summed across every entry in `spaces_pools` plus
  `control_plane`) — both can silently cap out well below what the numbers
  imply, and a rolling update that hits either mid-flight can deadlock a
  zonal PV's node. See https://docs.marshal.codes/sizing for the capacity
  planning, and https://docs.marshal.codes/installing/gke for the quota
  requirements.

```hcl
deploy_cluster             = true
cluster_name               = "marshal"        # name of the NEW cluster
location                   = "europe-west1"
master_authorized_networks = [{ cidr_block = "10.8.0.0/24", display_name = "admin-vpn" }]
database_mode = "external"
database_url  = "postgres://marshal:PW@10.20.0.5:5432/marshal?sslmode=require"
```

Because the control plane is private, run `terraform` (and later `kubectl`) from
inside the VPC — a bastion, VPN, or a peered admin subnet.

### No existing VPN/bastion? Two-phase apply + an IAP-tunneled bastion

This is the single biggest gotcha in the whole `deploy_cluster = true` path, and
it's easy to miss: **only some of these resources need VPC connectivity.**
`google_compute_network`, `google_container_cluster`, and
`google_container_node_pool` are created via the `google` provider talking to
`container.googleapis.com` / `compute.googleapis.com` — reachable from anywhere
with a valid GCP token, no VPN needed. But `module.marshal` (the namespace,
Secrets, and the `helm_release` itself) goes through the `kubernetes`/`helm`
providers, which dial `https://${cluster_endpoint}` **directly** — a raw
connection to the control-plane's own IP. With `enable_private_endpoint = true`
that IP has no public route at all; a GCP token doesn't fix that, it's a pure
networking problem, exactly like the k3s flavor's "fresh node has no reachable
endpoint at first apply" note, just for the opposite reason (private-by-design,
not not-yet-booted).

If you don't already have VPN/bastion access into the target VPC, stand up a
throwaway bastion instead — no VPN required, using
[IAP TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding) for
SSH (needs `roles/iap.tunnelResourceAccessor` and a firewall rule allowing
`35.235.240.0/20` on `tcp:22`):

```bash
# 1. Apply just the network + cluster (works from anywhere):
terraform apply -target=google_compute_network.vpc \
                 -target=google_compute_subnetwork.subnet \
                 -target=google_compute_router.router \
                 -target=google_compute_router_nat.nat
terraform apply -target=google_container_cluster.this \
                 -target='google_container_node_pool.spaces["spaces"]'

# 2. Put master_authorized_networks' CIDR = the subnet the bastion will live in
#    (e.g. the default subnet_cidr, "10.10.0.0/20") — no need to know a real
#    external CIDR at all.

# 3. Bastion, no external IP, in that same subnet:
gcloud compute instances create marshal-bastion \
  --zone=<region>-b --subnet=<subnet> --no-address \
  --scopes=cloud-platform --image-family=debian-12 --image-project=debian-cloud
gcloud compute firewall-rules create allow-iap-ssh \
  --network=<network> --direction=INGRESS --action=ALLOW --rules=tcp:22 \
  --source-ranges=35.235.240.0/20

# 4. Terraform/kubectl/helm on a fresh Debian VM download fine from the public
#    internet (Cloud NAT covers the bastion's subnet too) — no need to fight a
#    sandboxed egress allowlist there the way you might on the machine running
#    step 1.
gcloud compute ssh marshal-bastion --zone=<region>-b --tunnel-through-iap

# 5. On the bastion: same GCS backend (terraform init), same terraform.tfvars
#    (scp it over — never commit it), but this time database_mode = "external"
#    with the real database_url, and `terraform apply` for everything, which
#    now succeeds because the bastion's subnet is in master_authorized_networks.
```

Delete the bastion once you're done (`deletion_protection` doesn't apply to it —
it's not part of this Terraform config, just a manual `gcloud compute instances
delete`).

## Provisioning Cloud SQL yourself

This repo deliberately does **not** create the Postgres instance — `database_url`
is a bring-your-own input (see CLAUDE.md: un-codifiable, customer-owned
resources are documented here, not silently assumed). Exact commands, assuming
`deploy_cluster = true` created the VPC already:

```bash
# Private Services Access — one-time per VPC, needed for Cloud SQL private IP.
gcloud compute addresses create google-managed-services-<vpc> \
  --global --purpose=VPC_PEERING --prefix-length=16 --network=<vpc>
gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --ranges=google-managed-services-<vpc> --network=<vpc>

# Postgres 16, private IP only.
# GOTCHA: the default edition (ENTERPRISE_PLUS) REJECTS db-custom-* tiers —
# pass --edition=ENTERPRISE explicitly (also cheaper, fine for most installs).
gcloud sql instances create <name> \
  --database-version=POSTGRES_16 --edition=ENTERPRISE \
  --tier=db-custom-2-7680 --region=<region> \
  --network=projects/<project>/global/networks/<vpc> --no-assign-ip \
  --availability-type=ZONAL  # or REGIONAL for HA

gcloud sql databases create marshal --instance=<name>
gcloud sql users create marshal --instance=<name> --password=<generated>
# database_url = postgres://marshal:<password>@<private-ip>:5432/marshal?sslmode=require
```

## Registry (pull-through cache) — on by default, required for a real install

`create_registry_cache` defaults to **`true`**. Direct pull from
`registry.marshal.codes` (`registry_auth_mode = "secret"`) still exists and
works, but only set `create_registry_cache = false` for a disposable,
single-session smoke test — never for a real customer install. Direct pull
shares Marshal's registry rate limit across every customer pulling at once;
the cache is what keeps one customer's session churn from throttling
everyone else's.

**One variable — everything else is automatic:**

```hcl
create_registry_cache = true   # default; no need to set explicitly unless disabling for a smoke test
```

This creates an Artifact Registry **remote repository** (`registry_cache.tf`)
mirroring `registry.marshal.codes` — a Secret Manager secret holds your pull
token as the upstream credential, and the install self-wires onto the cache
(`registry` + `registry_auth_mode = "workloadIdentity"` are set for you; you do
**not** also set them by hand). Nodes pull credential-free via their own
identity (Workload Identity / default compute SA) — no in-cluster pull secret.
The `helm` provider still uses the pull token directly for the chart pull
itself (that step doesn't go through the node cache).

If you'd rather manage the cache outside this repo (a shared cache across
multiple installs, for instance — "one cache per organization, not per
deployment"), set `create_registry_cache = false` and set `registry` /
`registry_auth_mode` to point at your own — you're still required to run
*some* pull-through cache, just not necessarily this repo's.

## Object storage (audit + spaces persistence)

The api can use cloud object storage for two **independent** features — audit
persistence (compliance export) and spaces persistence (session pause/resume
snapshots). Both are `gocloud.dev/blob`-based (`gs://`/`s3://`/`azblob://`,
ambient auth), so this works the same way on every cloud this repo eventually
supports, not just GCP.

```hcl
create_audit_persistence_bucket  = true
create_spaces_persistence_bucket = true
```

Each toggle is separate — enable one, both, or neither. Whichever you turn on
creates its bucket (`<project>-<cluster>-audit-persistence` /
`<project>-<cluster>-spaces-persistence`), and (the first time either is
enabled) a shared GSA with `roles/storage.objectAdmin` on each enabled bucket,
bound via **Workload Identity** (no downloaded key) to the KSA that actually
does the I/O: the **api** for audit-persistence, and — for spaces-persistence —
the **`<release>-supervisor`** KSA session pods run under, since it's the
supervisor (inside each session pod), not the api, that reads/writes snapshots
at runtime. `terraform output audit_persistence_bucket` /
`spaces_persistence_bucket` prints the `gs://` URLs (`null` for whichever one
you left off).

**Creating a bucket doesn't turn its feature on by itself** — an org admin
still wires the actual URL via the API afterward (audit: per-org config;
spaces: `PUT /api/org/space-storage`, `provider=gcs`, `bucket=<name>`, no
`credentials` needed since Workload Identity handles auth ambiently). This
just provisions the storage + access so that Day-2 step has somewhere to
point at.

Leave both `false` (default) to bring your own buckets — have the org admin
supply explicit credentials via the API instead of relying on Workload
Identity.

## Day-2 upgrade

Bump `chart_version` and `terraform apply`. Roll back with
`helm rollback marshal -n marshal`.
