# single-node-k3s

Install Marshal onto a single node running **k3s**. The simplest deployment.
Two postures via `deploy_cluster`:

- **reuse** (`deploy_cluster = false`, default) — install onto a k3s node you
  already run (the primary path — the customer typically already has a GCP VM
  running k3s). Deploys an in-cluster Postgres + Redis and the umbrella chart in
  one `terraform apply`.
- **provision** (`deploy_cluster = true`) — Terraform stands up a **private** GCE
  VM (no public IP + Cloud NAT) running k3s. This provisions **infrastructure
  only**; you then install in a second step (see
  [Provisioning a private node](#provisioning-a-private-node)).

All install logic is in [`../modules/marshal-install`](../modules/marshal-install);
this flavor just supplies k3s-appropriate defaults + datastores.

## Prerequisites

- A Linux node running **k3s ≥ 1.27** (BYO — e.g. a GCP VM). k3s ships Traefik
  ingress + the `local-path` StorageClass, which is all this flavor needs.
- `terraform ≥ 1.5`, `kubectl`, `helm ≥ 3.14` on your workstation.
- A **kubeconfig** for the node (see below).
- Your Marshal onboarding credentials (installation JWT + `dep_` id + `mrpt_`
  pull token) — see **[Credentials](../README.md#credentials-read-this-first)** in
  the top-level README for what they are, where to get them, and a `helm registry
  login` / `helm pull` check to prove they work before you `terraform apply`.

### Standing up k3s (if you don't have it yet)

On the node:

```bash
curl -sfL https://get.k3s.io | sh -
# Relax image-pull throttling for large tool images (optional but recommended):
#   add --kubelet-arg=registry-qps=0 --kubelet-arg=serialize-image-pulls=false
```

### Get a kubeconfig

The admin kubeconfig on the node is `/etc/rancher/k3s/k3s.yaml`. Copy it to your
workstation and rewrite the `server:` address from `127.0.0.1` to the node's
reachable IP:

```bash
scp node:/etc/rancher/k3s/k3s.yaml ~/.kube/marshal-k3s.yaml
sed -i '' 's#https://127.0.0.1:6443#https://<NODE-IP>:6443#' ~/.kube/marshal-k3s.yaml
export KUBECONFIG=~/.kube/marshal-k3s.yaml   # or set kubeconfig_path in tfvars
```

## Install

```bash
cp ../examples/single-node-k3s.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # fill the REQUIRED block (~6 values)

terraform init
terraform apply
terraform output next_steps       # verify commands + app URL
```

## Inputs

Required: `installation_jwt`, `deployment_id`, `registry_pull_token`,
`chart_version`, `ingress_host`. Everything else has a default — see
[`variables.tf`](variables.tf) for the fully-commented list.

### Datastores

By default this flavor deploys a minimal in-cluster `postgres:16` (with a
`local-path` PVC) + `redis:7` and wires their DSNs into Marshal — so a single node
is self-contained. This is fine for evaluation / small installs but Postgres has
**no HA or backups**. For durable data, set `provision_datastores = false` and
pass a managed `database_url` (and, if you run managed Redis, `redis_url`).

> Redis in-cluster is the recommended posture everywhere — Marshal's Redis holds
> only ephemeral/reconstructible state, so it never needs a managed backend.
> Postgres is the durable source of truth and is what you'd move to managed.

> The chart's own bundled Bitnami subcharts are deliberately **not** used — their
> Docker Hub tags were withdrawn upstream — so this flavor rolls its own pair.

### DNS / TLS

- **No real domain?** Use [sslip.io](https://sslip.io): set
  `ingress_host = "marshal.<NODE-IP-WITH-DASHES>.sslip.io"` (e.g.
  `marshal.203-0-113-5.sslip.io`). Leave `ingress_tls = []` for HTTP.
- **Real TLS** — install cert-manager + a `ClusterIssuer`, then set
  `ingress_annotations = { "cert-manager.io/cluster-issuer" = "letsencrypt" }`
  and `ingress_tls = [{ hosts = ["marshal.acme.com"], secretName = "marshal-tls" }]`.
  Point the host's DNS A record at the node IP.

### Registry

Default is **direct pull** from `registry.marshal.codes` using your pull token
(`registry_auth_mode = "secret"`). If you run an in-network mirror, point
`registry` at it and set `registry_auth_mode = "none"` (or `workloadIdentity`).

## Provisioning a private node

Set `deploy_cluster = true` (+ `project_id`, `zone`, `admin_source_ranges`) to
have Terraform create a **private** GCE VM (no public IP) with **Cloud NAT** for
egress and k3s installed via startup script. Because a brand-new private node has
no reachable kubeconfig at apply time, this is a **two-step** flow:

```bash
# 1. Stand up the private node (infra only).
terraform apply -var deploy_cluster=true -var project_id=acme-prod \
  -var zone=europe-west1-b -var 'admin_source_ranges=["10.8.0.0/24"]' <creds…>

# 2. Fetch its kubeconfig over IAP, then install onto it.
gcloud compute ssh marshal-k3s --zone europe-west1-b --tunnel-through-iap \
  --command 'sudo cat /etc/rancher/k3s/k3s.yaml' > k3s.yaml
#   rewrite https://127.0.0.1:6443 -> the node's internal IP
terraform apply -var deploy_cluster=false -var kubeconfig_path=./k3s.yaml <creds…>
```

`terraform output next_steps` prints these exact commands after step 1. Run
`terraform` from inside the VPC (bastion / VPN / IAP tunnel) — the node's k3s API
(6443) is private and firewalled to `admin_source_ranges`.


### Public node (`public_ip = true`)

For a node that must serve the app straight from its own address (a demo or
evaluation cell, no load balancer), set `public_ip = true`. Terraform then
reserves a **static** external IP for the VM and opens tcp/80+443 to
`public_http_source_ranges` (default: everyone). SSH and the k3s API stay on IAP
+ `admin_source_ranges`. With a public IP the node has its own egress, so set
`create_nat = false` when you reuse a network that has no NAT.

`terraform output k3s_external_ip` prints the address for the DNS A record. A
static IP keeps billing while the VM is stopped (about $7/month), which is the
price of DNS that survives a stop/start.

`node_service_account_email` gives the VM a dedicated identity instead of the
project's default compute SA (cloud-platform scope; grant the SA only what it
needs).

## Day-2 upgrade

Bump `chart_version` in `terraform.tfvars` and `terraform apply`. Roll back with
`helm rollback marshal -n marshal`.
