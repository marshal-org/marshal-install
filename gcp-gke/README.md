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
  If you signed in only with `gcloud auth login`, Terraform's Google providers
  do not see that session; export a token instead
  (`export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)`). The
  token lasts about an hour, so refresh it before a long apply or destroy.
  Reuse needs `container.clusters.get`; provisioning needs `container.admin` +
  compute network admin on the project.
- **Project APIs are enabled for you** (`enable_project_apis`, default `true`),
  each only when a setting that uses it is on: Compute Engine and Kubernetes
  Engine (provisioning, the ingress static IP), Artifact Registry and Secret
  Manager (`create_registry_cache`, on by default), IAM, IAM Credentials and
  Cloud Storage (the storage buckets), Certificate Manager (`create_managed_certificate`). None is
  ever disabled on destroy. On a fresh project this needs
  `serviceusage.services.enable` (e.g. `roles/serviceusage.serviceUsageAdmin`);
  an API that is already on is left alone. If your organization enables APIs
  centrally, set `enable_project_apis = false` and enable them first:
  ```bash
  gcloud services enable compute.googleapis.com container.googleapis.com \
    artifactregistry.googleapis.com secretmanager.googleapis.com \
    iam.googleapis.com iamcredentials.googleapis.com storage.googleapis.com \
    --project <project>
  ```
  The Artifact Registry service agent the registry cache needs is created by
  the same apply (through the `google-beta` provider, which `terraform init`
  downloads), so a fresh project installs in one apply, not three.
- A **Postgres 16** the cluster can reach over the VPC (Cloud SQL private IP) —
  Postgres is the durable source of truth (external is recommended). Redis is
  in-cluster by default. For an evaluation only, Postgres can run in-cluster
  too (`database_mode = "bundled"`); see [Datastores](#datastores).
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

## Datastores

Default posture: Postgres external, Redis bundled.

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

### Evaluations: `database_mode = "bundled"`

For a trial or a proof of concept you can skip Cloud SQL entirely and run
Postgres in the cluster too:

```hcl
database_mode = "bundled"   # in-cluster Postgres (Bitnami subchart), no database_url
redis_mode    = "bundled"   # the default
```

That is one apply with nothing to provision first. Use it **only for an
evaluation**: the bundled Postgres is a single pod on a persistent disk, with
a fixed demo password, no backups and no HA, and it holds everything durable
(orgs, credentials, audit). Moving an evaluation onto Cloud SQL later is a
database migration (`pg_dump` / `pg_restore`), not a variable change. Any
install you intend to keep starts on `database_mode = "external"`.

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

### The load balancer takes 5-15 minutes after the apply

`terraform apply` finishes when the pods are ready, not when the load balancer
is. GKE then needs **5 to 15 minutes** to program the load balancer for the
Ingress (or Gateway) and pass its health checks; until then the URL times out,
fails the TLS handshake or answers 502. HTTP comes up first and HTTPS a few
minutes later. Two fresh installs measured a day apart: the Ingress got its
address 5m14s and about 10 minutes after it was created, and answered on HTTPS
at 8m11s and about 12.5 minutes. This is normal on every new install and after
switching `ingress_mode`. Watch for it:

```bash
kubectl get ingress -n marshal -w        # ingress_mode = "gateway": kubectl get gateway -n marshal -w
```

The address column fills in first; give it a minute or two more after that for
the backends to turn healthy.

### Reaching Marshal before DNS exists (trials)

A trial often starts with an `ingress_host` nobody can resolve yet, and with
the default internal load balancer, from a laptop outside the VPC. Three
working paths:

**Quickest, chart 0.29 or newer: a port-forward, no bastion.** With
`dns_endpoint_enabled = true` (see
[Skipping the bastion](#skipping-the-bastion-dns_endpoint_enabled--true)) your
laptop can reach the control plane, so it can port-forward to the web Service,
which serves the console and the API on one port:

```bash
gcloud container clusters get-credentials <cluster> --location <loc> --project <project> --dns-endpoint
kubectl port-forward -n marshal svc/web 8080:80 &
# Claim the owner account at http://localhost:8080/setup#token=<TOKEN>, then:
marshal login --server http://localhost:8080
```

There is no certificate warning and no `--insecure`, because the traffic is plain
HTTP over the tunnel. This path does not exercise the load balancer, so it is the
right way to trial the product but not to prove the ingress; use A or B for that.

The next two keep the real hostname, so cookies, OAuth redirects and the CLI's
space connect all see the host they expect:

**A. From outside the VPC, through an IAP bastion (keeps the load balancer
internal).** Use the throwaway bastion from
[the bastion section](#no-existing-vpnbastion-two-phase-apply--an-iap-tunneled-bastion)
below (it only needs to be in the cluster's VPC), and open a SOCKS proxy
through it. The hostname is resolved on the bastion, so the hosts entry goes
there:

```bash
IP=$(terraform output -raw ingress_ip)     # the internal load balancer address
HOST=marshal.acme.com                      # your ingress_host
gcloud compute ssh marshal-bastion --zone <zone> --tunnel-through-iap -- \
  "echo '$IP $HOST' | sudo tee -a /etc/hosts"
gcloud compute ssh marshal-bastion --zone <zone> --tunnel-through-iap -- -N -D 1080
```

Then, on the laptop, send the browser and the CLI through it:

```bash
# Browser: a profile that uses the proxy, e.g.
google-chrome --user-data-dir=/tmp/marshal-trial --proxy-server="socks5://localhost:1080" "https://$HOST"
# CLI (Go honours HTTPS_PROXY, including socks5; --insecure only while the
# self-signed placeholder certificate is in place):
export HTTPS_PROXY=socks5://localhost:1080
marshal --insecure ...
```

**B. A throwaway trial with an external load balancer.** Set
`internal_ingress = false` (class `gce`, a public IP) and add a hosts-file
entry on each machine that needs it:

```bash
kubectl get ingress -n marshal    # the ADDRESS column, once the load balancer is up
echo "<address> marshal.acme.com" | sudo tee -a /etc/hosts
```

This puts Marshal on the internet. Use it only for a disposable trial, never
for an install you keep, and switch back to `internal_ingress = true` (which
moves the load balancer and its IP) before real use.

**Charts older than 0.29: a port-forward to the web Service does not work for
the CLI.** The console loads, but the CLI's space connect fails with
`lookup api ... server misbehaving`: the web container's proxy did not pass the
original `Host` header on, so the api built the space's WebSocket URL as
`ws://api:8080`, a name that only resolves inside the cluster. Chart 0.29 passes
it (and `X-Forwarded-Host` / `X-Forwarded-Proto`), which is why the quickest path
above needs 0.29. There is no in-cluster ingress controller to port-forward to on
GKE: the `gce`/`gce-internal` load balancer runs outside the cluster.

### Google-managed certificate: `ingress_mode = "gateway"` (chart ≥ 0.27.0)

A GKE Ingress on an internal load balancer cannot use a Google-managed
certificate. A Gateway can. `ingress_mode = "gateway"` exposes Marshal through a
Gateway API Gateway (class `gateway_class_name`, default `gke-l7-rilb`) instead
of the Ingress, on the same reserved internal IP, with the same host, extra
hosts and preview domain. Google then issues and renews the certificate; nothing
in the cluster rotates it.

```hcl
ingress_mode               = "gateway"
create_managed_certificate = true   # ingress_host + *.preview_domain, DNS-authorized
```

1. `terraform apply`. It turns on the Gateway API on a cluster this flavor
   provisions, and creates the Gateway, the DNS authorizations and the
   certificate. HTTPS serves the `tls_mode` certificate meanwhile.
2. Add each record from `terraform output managed_certificate_dns_records`
   (CNAME) in your DNS.
3. Wait until the certificate is `ACTIVE`
   (`gcloud certificate-manager certificates describe <cluster_name>-marshal-cert --location <region>`),
   then `terraform apply` again. That apply reads the new state and moves the
   HTTPS listener onto the managed certificate; `managed_certificate_state`
   then reads `ACTIVE`.

Notes:

- Needs `internal_ingress = true` and the `certificatemanager.googleapis.com`
  API on the project (`gcloud services enable certificatemanager.googleapis.com`).
- Reused cluster (`deploy_cluster = false`): turn the Gateway API on yourself
  first: `gcloud container clusters update <name> --location <loc> --gateway-api=standard`.
- Already have a Certificate Manager certificate? List it in
  `gateway_certificate_names` (same project and region) instead of, or as well
  as, `create_managed_certificate`.
- `extra_ingress_hosts` (e.g. a MagicDNS name) are routed but not on the managed
  certificate.
- Switching an existing install from `ingress` to `gateway` moves the load
  balancer: expect up to about four minutes without traffic, on the same IP and
  DNS name. Plan it in a quiet window.

## Node pools: control-plane vs. spaces_pools (isolated by default, taint gated)

Session/space workloads run across however many pools `spaces_pools` (a map,
keyed by a short pool-name suffix) defines — one `google_container_node_pool`
per entry, named `<cluster_name>-<key>-pool` and labeled `workload=<key>`.
Default is a single `spaces` entry (`e2-standard-8`, 300GB, autoscaling
1-5/zone; was `e2-standard-4`, 100GB). Disk is what fills first: the built-in
compute classes request 20 GiB of disk per vCPU and GKE leaves about half of a
boot disk allocatable (300GB gives about 146GiB, 100GB about 46GiB). Keep the
1:4 vCPU:memory shape. At create the defaults need about 48 vCPU and 1050GB of
regional `SSD_TOTAL_GB` (3 zones), so request both quotas first (capacity
planning: https://docs.marshal.codes/sizing). **Upgrading an existing
install:** a changed `machine_type` or `disk_size_gb` replaces the pool, and a
replacement stops every running space on it. Pin your current values before you
upgrade if you did not set them. To move to a different size, **add a new entry**
to `spaces_pools` beside the old one (with quota for both), run
`kubectl cordon -l cloud.google.com/gke-nodepool=<old>`, ask your users to stop and
start their spaces, and remove the old entry only when no space pod is left on it.
To collect logs for a support case, run
`scripts/support-bundle.sh --since 6h --space <name>` (it asks whether to include the audit log; default no). Add more entries for more pools, e.g. a bigger
machine for heavier sessions:

```hcl
spaces_pools = {
  spaces = { machine_type = "e2-standard-8", disk_size_gb = 200, min_node_count = 2, max_node_count = 10 }
  big    = { machine_type = "e2-standard-16", disk_size_gb = 200, min_node_count = 0, max_node_count = 4 }
}
```

An autoscaled pool is created with `min_node_count` nodes per zone (the
control-plane pool with at least 1), so the platform has somewhere to run the
moment the cluster is up: GKE creates an autoscaled pool with no starting size
empty, and its autoscaler only adds nodes for pods that are already Pending.
That starting size matters only at create; changing it later plans nothing, so
existing pools are not replaced.

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

`control_plane` is a separate pool — never share machine type/disk/sysctls with
`spaces_pools` — and it is *dedicated* because `taint_control_plane_pool`
defaults to `true`. With `false` neither pool is tainted, so control-plane
pods can land on the spaces nodes and take their CPU. The default needs chart
0.9.0 or newer (see
[below](#node-pools-control-plane-vs-spaces_pools-isolated-by-default-taint-gated)).

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
(bool, **default `true`**; was `false`). Setting it to `true` does BOTH of the following in the same apply (see `main.tf`'s
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
outage). `terraform plan` warns when `chart_version` is older. On a cluster
still on a chart older than 0.9.0, bump `chart_version` first and confirm the
cluster is healthy; or set `taint_control_plane_pool = false` until you have.
On an install that never set it, the next apply adds the taint and the chart
`nodeSelector` together and the helm upgrade moves the control-plane pods;
pods already on a spaces node are not evicted by the taint itself.

Space pods need no corresponding change: they carry no toleration, so once
the control-plane pool is tainted they simply can't land there and settle on
the (untainted) spaces pool by elimination. New installs on chart >= 0.9.0
can set `taint_control_plane_pool = true` from day one with no ordering
risk — there's nothing pre-existing to disrupt.

Same regional `SSD_TOTAL_GB` quota constraint applies across every pool in
`spaces_pools` plus `control_plane` — check headroom
(`gcloud compute regions describe <region> --format="value(quotas)"`) before
adding entries or raising `disk_size_gb`/`max_node_count`.

### Faster space start on fresh nodes (`image_streaming_enabled`, `max_parallel_image_pulls`)

A node the autoscaler just added has never pulled a space's tool images, so the
first space on it waits for every image to download before it starts. Two
opt-in settings shorten that, on every pool this flavor creates (space pools and
the control-plane pool). Both are off by default; an install that sets neither
plans no change.

- `image_streaming_enabled = true` turns on GKE image streaming: containers
  start before their images have fully downloaded. It also enables the
  `containerfilesystem.googleapis.com` API, which the flavor never disables
  again. Needs GKE 1.30.1-gke.1329000 or later and the default `COS_CONTAINERD`
  node image. A custom `node_service_account` also needs
  `roles/serviceusage.serviceUsageConsumer` on the project (the dedicated node
  SA gets it automatically), and a VPC Service
  Controls perimeter must include the API.
- `max_parallel_image_pulls` (2 to 5) sets how many images a node pulls at
  once. Unset, GKE's own default applies (2 or 3). The kubelet pulls one pod's
  images one after another regardless, so this helps when several spaces start
  on the same new node together, not a single space's start.

Measured on a fresh node (GKE 1.36, a pod mounting 12 tool images, about
4.9 GB): about 180 s with streaming off and about 30 s with it on, once each
image has been streamed once in the region. The first start after a new image
version is published is close to the streaming-off time, because GKE's
streaming cache fills on first use.

On a running install, either change makes GKE replace the nodes of every pool it
touches, without waiting for a maintenance window, and the spaces on those nodes
restart. Apply it at a quiet time. Setting `image_streaming_enabled` back to
`false` does not turn streaming off on existing pools (GKE keeps the live
value); to turn it off, run:

```bash
gcloud container node-pools update <pool> --cluster <cluster> \
  --location <location> --no-enable-image-streaming
```

Neither setting does anything on a cluster this flavor does not provision
(`deploy_cluster = false`).

### Spot space pools (test and development clusters)

Set `spot = true` on a `spaces_pools` entry to run it on Spot VMs: much cheaper,
but GKE can reclaim a node at any time and the spaces on it restart. Set it when
the pool is first created: marking an existing pool `spot` replaces the pool.
The control-plane pool never uses Spot.

### Node service account (`create_node_service_account`, on by default)

The nodes run as a dedicated service account, `<cluster_name>-nodes`, not the
project's default Compute Engine SA. The default SA usually holds
`roles/editor`, so a container that escaped to a node could take over the
project. The dedicated SA can do only what a node needs:

| Grant | Scope | Why |
|---|---|---|
| `roles/container.defaultNodeServiceAccount` | project | logs, metrics, node metadata |
| `roles/artifactregistry.reader` | the registry cache repository only | image pulls (`create_registry_cache`) |
| `roles/serviceusage.serviceUsageConsumer` | project | only with `image_streaming_enabled` |

Pods never use the node SA: every pool runs `GKE_METADATA`, so pods get
Workload Identity. No Marshal workload uses `hostNetwork` (which would bypass
the GKE metadata server).

Precedence: `node_service_account = "<email>"` wins and is used as it is (you
grant its roles; the cache read is granted for you). Otherwise
`create_node_service_account = true` (default) creates the dedicated SA. Set it
to `false` for the old behavior (the Compute default SA).

Per pool, `service_account` in a `spaces_pools` entry (and
`control_plane_service_account` for the control-plane pool) overrides the
module-wide choice: `null` (default) follows it, `"default"` means the Compute
default SA, and any other value is an SA email you manage.

#### Upgrading an existing install

> **Pin your pools before you upgrade.** GKE cannot change a pool's service
> account in place. Without pins, the first plan after this upgrade REPLACES
> EVERY NODE POOL at once (all nodes deleted, every running space killed).
> Check the plan: a `node_config[0].service_account` change marked
> `forces replacement` means a pool is not pinned.

Pools created before this setting existed run as the Compute default SA. Add
`service_account = "default"` to every existing `spaces_pools` entry and set
`control_plane_service_account = "default"`. The plan then creates only the SA
and its grants, and changes no pool. (Or set
`create_node_service_account = false` to change nothing at all.)

Then move the pools one by one:

1. Add a new `spaces_pools` entry without `service_account`, the same shape as
   the pool it replaces. Set `workload` to the old pool's label value, so
   anything that selects on `workload=<value>` places pods on both.
   Example: key `spaces-sa` with `workload = "spaces"`.
2. Apply. Check that the new nodes are `Ready`, pull images, and send logs.
3. `kubectl cordon` the old pool's nodes. Spaces move to the new pool as they
   restart (space pods are bare pods, so nothing moves them for you).
4. When the old pool is empty, remove its entry and apply.
5. The control-plane pool is a single resource, so moving it means a
   replacement: drop `control_plane_service_account` in a short maintenance
   window. The platform pods restart on the new node.

Once no pool runs as the Compute default SA, the module also removes that SA's
read grant on the registry cache.

## Provisioning a private cluster (`deploy_cluster = true`)

Terraform creates, all in one apply, then installs onto it:

- **Private nodes** (`enable_private_nodes` — no public node IPs).
- **Locked-down control plane** — private endpoint by default
  (`enable_private_endpoint = true`) with **master authorized networks** (you must
  set `master_authorized_networks` to at least your admin/VPN CIDR, else you lock
  yourself out; with `dns_endpoint_enabled = true` it may stay empty, see
  [Skipping the bastion](#skipping-the-bastion-dns_endpoint_enabled--true)). Set `enable_private_endpoint = false` for a public-but-authorized
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
  `e2-standard-8`, autoscaling 1-5/zone, 300GB), each entry's `machine_type` /
  autoscaling (`min_node_count`..`max_node_count`, or a fixed `node_count`) /
  `disk_size_gb` / `disk_type`; `release_channel` / `kubernetes_version` apply
  cluster-wide. `disk_size_gb` sizes for **ephemeral-storage**, not just
  capacity — session pods request 10-20GiB ephemeral-storage each, and GKE
  reserves about half of the boot disk for OS/image cache, so disk, not CPU or
  memory, sets how many spaces fit on a node.
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
#    The IAM bindings too, as a project owner, so the bastion never needs an
#    IAM-admin role:
terraform apply -target=google_project_iam_member.nodes_default_node_sa \
                 -target=google_project_iam_member.nodes_service_usage \
                 -target=google_service_account_iam_member.storage_workload_identity \
                 -target=google_service_account_iam_member.storage_workload_identity_supervisor

# 2. Put master_authorized_networks' CIDR = the subnet the bastion will live in
#    (e.g. the default subnet_cidr, "10.10.0.0/20") — no need to know a real
#    external CIDR at all.

# 3. Bastion, no external IP, in that same subnet, with its OWN service account.
#    Never run it as the Compute default SA, and never add roles to that SA: it
#    is shared by every VM in the project, and admin roles on it are a
#    high-severity finding in cloud security scanners.
gcloud iam service-accounts create marshal-bastion --project=<project>
SA=marshal-bastion@<project>.iam.gserviceaccount.com
for r in compute.networkAdmin container.admin storage.admin artifactregistry.admin \
         secretmanager.admin certificatemanager.editor serviceusage.serviceUsageAdmin \
         iam.securityReviewer iam.serviceAccountViewer logging.logWriter; do
  gcloud projects add-iam-policy-binding <project> --member=serviceAccount:$SA \
    --role=roles/$r --condition=None
done
# actAs on the node SA, so the bastion can update node pools:
gcloud iam service-accounts add-iam-policy-binding <cluster>-nodes@<project>.iam.gserviceaccount.com \
  --member=serviceAccount:$SA --role=roles/iam.serviceAccountUser
gcloud compute instances create marshal-bastion \
  --zone=<region>-b --subnet=<subnet> --no-address \
  --service-account=$SA --scopes=cloud-platform \
  --image-family=debian-12 --image-project=debian-cloud
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

The bastion SA can read IAM policies (`iam.securityReviewer`, so plans refresh)
but not change them. A later change that adds an IAM binding (a new service
account, a new Workload Identity binding) gets a 403 from the bastion: apply
that one resource as a project owner from your own machine, or create the
binding by hand and `terraform import` it.

**Moving an existing bastion off the Compute default SA:** create the SA and
grants above, then `gcloud compute instances stop marshal-bastion`,
`gcloud compute instances set-service-account marshal-bastion
--service-account=$SA --scopes=cloud-platform`, and `start`. Run `terraform
plan` from the bastion (expect no resource changes), then remove every project
role from `<number>-compute@developer.gserviceaccount.com`. The cluster does not
use that SA when `create_node_service_account = true`.

Delete the bastion once you're done (`deletion_protection` doesn't apply to it:
it's not part of this Terraform config, just a manual `gcloud compute instances
delete`). Delete its service account with it.

### Skipping the bastion: `dns_endpoint_enabled = true`

The bastion above exists only because the `kubernetes`/`helm` providers dial the
control-plane IP directly. With `deploy_cluster = true`, `dns_endpoint_enabled = true`
gives the cluster its Google-managed DNS endpoint *and* points the `kubernetes`/`helm`
providers at it (publicly trusted certificate, so no cluster CA is passed; the same
access token authenticates). The DNS endpoint is reachable from anywhere and gated by the
`container.clusters.connect` IAM permission instead of by source IP — so a
one-phase apply works from a laptop, and `master_authorized_networks` may stay
empty (the plan-time check accepts that combination). Only the provisioned
cluster path (`deploy_cluster = true`) switches the providers; a BYO cluster
(`deploy_cluster = false`) is still reached over its IP endpoint.

This is the trade one of our own internal clusters already makes: an IP allowlist
has to be re-applied every time the operator's address changes, and it drifts
open because nobody prunes it. The flag deliberately leaves the IP endpoint
switched ON — turning it off makes GKE derive `enable_private_endpoint = true`
on the cluster, which every later plan then wants to strip back to `null`.

Fetch a kubeconfig for it with `--dns-endpoint`, or kubectl gets the private
IP endpoint and times out from outside the VPC. `terraform output next_steps`
and `terraform output kubeconfig_command` already include it whenever
`deploy_cluster` and `dns_endpoint_enabled` are both on:

```bash
gcloud container clusters get-credentials <cluster> --location <loc> --project <project> --dns-endpoint
kubectl get pods -n marshal     # works from a laptop; IAM (container.clusters.connect) gates it
```

What the DNS endpoint does and does not cover:

- It is the **control plane** only: `terraform`, `kubectl`, `helm` and
  `kubectl port-forward` work from anywhere. It does **not** make the Marshal
  app reachable: the Ingress is still an internal load balancer. See
  [Reaching Marshal before DNS exists](#reaching-marshal-before-dns-exists-trials).
- The caller needs the `container.clusters.connect` IAM permission on the
  cluster, plus Kubernetes RBAC as usual.
- `master_authorized_networks` does not apply to the DNS endpoint, only to the
  IP endpoint, which stays on.

## Provision only — when ArgoCD owns the release (`install_marshal = false`)

Default is `true`: this apply installs the chart, as it always has. Set it to
`false` and Terraform builds the cluster, node pools, registry cache, buckets and
static IP but installs nothing, leaving the release to ArgoCD (the GitOps path in
`../argocd/`). No `kubernetes`/`helm` provider call is made at all, so the
connectivity problem above disappears with it.

`deployment_id` and `registry_pull_token` must still be **real** in this mode —
`registry_cache.tf` uses them as the upstream credentials. Only
`installation_jwt` can be a placeholder, since nothing but the install consumes
it.

**Do not retype the chart values.** Terraform computes every GKE-derived value
whether or not it installs, and these are the ones a human cannot reliably
reproduce — a pull-through-cache endpoint, the storage service-account emails, the
scheduling that pairs with the pool taint:

```bash
terraform output -raw argocd_derived_values > values-derived.yaml
```

That emits `global.registry`, `toolsRegistryBase`, `registryAuth.mode`,
`ingress.className`/`annotations`, `api.serviceAccount.annotations`,
`supervisor.serviceAccount.annotations`, `controlPlane.nodeSelector`/
`tolerations`, and — when Redis is bundled — `redis.master.nodeSelector`/
`tolerations`, which `controlPlane.*` does not cover. Re-render it after any
apply that changes the project, cluster name, cache repo, buckets or the taint
toggle. Everything else in the Application is a value you already chose in
`terraform.tfvars`.

Two failure modes to know about this path:

- **`secrets.provider` must be `existing`**, with `existingSecret` naming a
  Secret you created yourself holding `JWT_SECRET`, `KMS_LOCAL_KEY` and
  `SETUP_TOKEN`. Helm's `lookup()` never runs under ArgoCD, so `generated`
  re-randomizes the first two on every sync — new JWT secret, and every stored
  credential undecryptable. Seed `marshal-license` before the first sync too; a
  blank one at bootstrap has broken the marketplace on a live cell.
- **A wrong `supervisor.serviceAccount.annotations` is silent.** The supervisor
  does the spaces-persistence blob I/O inside session pods, so a bad or missing
  annotation 403s every object-storage call at session runtime while the api's
  own storage connection test still passes. The only check that exercises it is
  to launch a space, stop it, and resume it.

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
identity (the node service account, see "Node service account") — no
in-cluster pull secret.
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
`<project>-<cluster>-spaces-persistence`) and grants access through
**Workload Identity** (no downloaded key). There are two GSAs:

| GSA | Created when | Roles | Bound to KSA |
|---|---|---|---|
| `<cluster>-storage` | either bucket is on | `roles/storage.objectAdmin` on each enabled bucket | `<namespace>/<release>-api` |
| `<cluster>-sup-storage` (cluster name cut to 18 chars) | spaces bucket is on | `roles/storage.objectAdmin` on the **spaces bucket only** | `<release>-spaces/<release>-supervisor` |

The api uses both buckets. The supervisor (inside each session pod) reads and
writes snapshots at runtime, so it needs its own identity. It gets a separate
GSA because session pods run agent code: they must not reach the audit bucket.
`terraform output audit_persistence_bucket` / `spaces_persistence_bucket`
prints the `gs://` URLs (`null` for whichever one you left off), and
`terraform output supervisor_storage_service_account` prints the supervisor
GSA's email.

**When the org blocks `setIamPolicy`.** The Workload Identity bindings call
`setIamPolicy` on the GSA. If an org policy or missing rights make the apply
fail with a 403 on `storage_workload_identity_supervisor`, an admin with rights
on the service account applies the binding by hand:

```bash
gcloud iam service-accounts add-iam-policy-binding <supervisor_storage_service_account> \
  --project <project> \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:<project>.svc.id.goog[<release>-spaces/<release>-supervisor]"
```

Then import it, so the next apply does not call `setIamPolicy` again:

```bash
terraform import 'google_service_account_iam_member.storage_workload_identity_supervisor[0]' \
  "projects/<project>/serviceAccounts/<supervisor_storage_service_account> roles/iam.workloadIdentityUser serviceAccount:<project>.svc.id.goog[<release>-spaces/<release>-supervisor]"
```
 The same applies to the api binding
(`storage_workload_identity`, member `...svc.id.goog[<namespace>/<release>-api]`
on the `<cluster>-storage` GSA).

**Upgrading an existing install.** The next apply creates the supervisor GSA
and its spaces-bucket grant, and replaces the supervisor's Workload Identity
binding (it moves from the shared storage GSA to the new one). The api's
binding and the storage GSA's grants do not change. The supervisor KSA's
`iam.gke.io/gcp-service-account` annotation changes to the new email. Stop
and resume a space afterwards to prove it.

Turn on both unless there is a reason not to: without the spaces bucket,
spaces cannot be forked or archived and keep their files across stop/resume
only on a compute size with a persistent disk, and without the audit bucket
the audit log is never exported.

**Creating a bucket doesn't turn its feature on by itself.** After install an
owner or admin of each org connects it in **Settings > Space Storage** and
**Settings > Auditing** (Storage card → **Save & enable**): provider Google
Cloud Storage, the bucket name without `gs://`, and empty credential fields,
since Workload Identity authenticates. Then stop and resume a space: the
Settings connection test runs in the api pod, so only a real session proves the
supervisor's binding.

Leave both `false` (default) to bring your own buckets — the org admin then
enters the bucket's credentials in the same Settings pages instead of relying
on Workload Identity.

> **⚠ With the spaces bucket off, stop/resume can lose a space's workspace.**
> Until an org connects space storage, a space keeps its files across
> stop/resume only on a compute size with a persistent disk; on any other size,
> stopping it discards the workspace. `terraform output next_steps` repeats this
> warning while `create_spaces_persistence_bucket = false`. For anything beyond
> a smoke test, turn the bucket on and connect it in **Settings > Space
> Storage** before anyone relies on stop/resume.
>
> It stays off by default on purpose: a bucket by itself does not turn the
> feature on (an org admin still connects it), switching the default would
> create a bucket, a service account and new Workload Identity bindings on every
> existing install's next apply and restart its api and supervisor pods, and
> `force_destroy = false` makes a bucket with snapshots in it block
> `terraform destroy` until you empty it.

## After the install: owner, first space, storage

Three one-time steps, in this order, take a finished apply to a working space. They
take a few minutes.

1. **Claim the owner account.** Read the setup token (Terraform never reads it, so
   it is not in state), then open `/setup#token=<TOKEN>` on your app URL
   (a `kubectl port-forward -n marshal svc/web 8080:80` on chart 0.29 or newer, or your ingress host):

   ```bash
   kubectl get secret marshal-app-secrets -n marshal -o jsonpath='{.data.SETUP_TOKEN}' | base64 -d
   ```

   Without a browser, make the same call the page makes. Read the password
   without echoing it (it must not contain a `"` or a `\`); add `-k` while the
   certificate is the placeholder:

   ```bash
   read -rs PW
   curl -s -X POST http://localhost:8080/api/auth/setup -H 'Content-Type: application/json' \
     -d "{\"token\":\"<TOKEN>\",\"email\":\"you@example.com\",\"password\":\"$PW\",\"org_name\":\"Your Org\"}"
   ```

   A `201` returns a session and the owner exists; the CLI then works with
   `marshal login --server <url> --password` (plain `marshal login` opens a browser, which hangs on a machine without one). A second attempt returns `409`.
2. **Connect the spaces bucket** (if you created one), before the first space.
   The bucket is the storage; Marshal only uses it once an owner or admin connects it in *Settings > Space
   Storage* and selecting *Save & enable* (provider GCS, the bucket name from `terraform output spaces_persistence_bucket` without the `gs://`, credential fields empty). Until then, and for any space created earlier, a space that is stopped on a compute
   size without a persistent disk **loses its workspace**, and cannot be forked
   or archived. Connect the audit bucket in *Settings > Auditing* the same way.
3. **Publish a first stack.** A new install has no stacks or manifests, so *New
   space* has nothing to offer and `marshal spaces new` stops with
   `a manifest is required to create a space`. As the owner: Marketplace, install
   a stack such as `default-engineering` and **publish** it (it installs
   unpublished), then *New space* > *Create a manifest* from it. The page with
   screenshots is [Publish your first stack](https://docs.marshal.codes/getting-started/owner).

## If an apply is interrupted

Expired credentials, a closed laptop or a timeout can stop an apply partway. The
resources created so far are in state, so run `terraform plan` before you apply
again and read it: a cluster or node pool whose create did not finish is
**tainted**, and the next apply destroys and recreates it (several minutes, and
anything on it). If the cluster is up and healthy, take it out of the plan with
`terraform untaint google_container_cluster.this[0]` (the name is in the plan)
and apply again. Refresh `GOOGLE_OAUTH_ACCESS_TOKEN` first if you use one.

## Day-2 upgrade

Bump `chart_version` and `terraform apply`. Roll back with
`helm rollback marshal -n marshal`.

**Upgrading this flavor's code from a version without
`create_node_service_account`:** pin every existing node pool to
`service_account = "default"` (and `control_plane_service_account = "default"`)
first, or the plan replaces all node pools at once. See "Node service account"
above.

**Upgrading this flavor's code from a version without the supervisor's own
GSA:** the plan adds `<cluster>-sup-storage`, its bucket grant, and replaces
`storage_workload_identity_supervisor`. The applier needs
`iam.serviceAccounts.setIamPolicy` and `storage.buckets.setIamPolicy`. If it
gets a 403, have a project owner add that one binding and `terraform import`
it. If an org entered bucket credentials in **Settings > Space Storage**, clear
them so sync uses Workload Identity, then delete the key. Prove it by stopping
and resuming a space: the supervisor logs `persist: kopia repository ready`.

### After an upgrade that carries security fixes

The chart upgrades the platform. Packages, stacks and spaces are org data, and
they move separately:

1. **Before the apply, pause deputy schedules** and triggers that would
   launch runs. Scheduled runs start as soon as the api is back, on the
   versions they had before.
2. **Upgrade the installed packages** (**Marketplace**, as an owner or admin).
   Auto-update is off by default, so an install keeps the versions it has.
3. **Move every stack and manifest to the new versions.** On each stack, run
   **Check upgrades**: it publishes a new version and moves the manifests
   on the previous one. Manifests on older stack versions are upgraded from
   the manifest page. A version pinned in a manifest's patch (for example
   `/modules/integration/docker`) is kept on upgrade, so bump the pin too.
4. **Restart existing spaces.** A space keeps the package versions it was
   created with, also across stop and resume. List running spaces with their
   owners, and ask each owner to recreate theirs.
5. **Check the result in a new space:** sidecar and tool images have the new
   digests, and pull through `marshal-cache`.

If you back up space rows or manifests while doing this, treat the backup as a
secret (space manifests carry per-space keys) and delete it the same day.

## Tearing down (`terraform destroy`)

A disposable cluster needs `deletion_protection = false` applied **before**
the destroy (the destroy reads it from state, not from tfvars).

`terraform destroy` is one run. The load balancer GKE built for the chart's
Ingress (or Gateway) is not in Terraform's state, but its forwarding rules hold
the static IP and the proxy-only subnet, and GKE deletes them only while the
cluster still exists. So the destroy goes in this order: the release and its
namespace (the namespace delete waits, up to 15 minutes, for the Ingress and its
GKE finalizer); then `terraform_data.ingress_lb_released`, which polls
`gcloud compute forwarding-rules list` until no rule holds the static IP (up to
10 minutes, printing what it is waiting for); and only then the cluster, the
subnet and the IP. Expect those two steps to take a few minutes. The wait needs
`gcloud` on the machine running the destroy; without it, it says so and carries
on.

If a destroy still stops on `resourceInUseByAnotherResource` for the address
or the proxy-only subnet (no `gcloud`, an install without the static IP
(`tls_mode = "none"`), or a cluster that was already gone before the destroy, so
nothing could clean the load balancer up), delete what GKE left behind and run
the destroy again:

```bash
# Forwarding rules GKE created for the Ingress (k8s2-*) or the Gateway (gkegw1-*):
gcloud compute forwarding-rules list --project <project> --filter="name~^(k8s2-|gkegw1-)"
gcloud compute forwarding-rules delete <name> --region <region> --project <project>
# then the target proxies, URL maps and backend services with the same prefix, if any are left
terraform destroy
```

Buckets created with `create_*_persistence_bucket` are not force-destroyed:
empty them first, or the destroy stops on them.

A destroy that finishes prints `Warning: Helm uninstall returned an information
message ... [Secret] marshal-app-secrets kept due to the resource policy`. That
is expected: the chart keeps its secrets object on uninstall, and the cluster is
deleted a few steps later, so nothing is left behind.
