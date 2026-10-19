# aws-eks

Installs Marshal onto EKS, backed by a managed **RDS** Postgres 16 instance
(external, or provisioned for you) + **bundled** (in-cluster) Redis, fronted
by an **ALB**.

Two postures via `deploy_cluster`, mirroring `gcp-gke`:

- `deploy_cluster = false` (default) — reuse an **existing** EKS cluster (BYO).
- `deploy_cluster = true` — provision a new cluster: VPC + two node groups
  (spaces + control-plane, same split as `gcp-gke`) + an OIDC provider for
  IRSA + the EBS CSI driver addon + the metrics-server addon + the AWS Load
  Balancer Controller (Helm-installed with its own IRSA role — see **What
  provisioning sets up** below).

## Prerequisites the REUSE path does NOT set up for you

If you're pointing at a cluster you already run (`deploy_cluster = false`),
these must already exist — the provisioning path below sets all of them up
for you automatically:

1. **The cluster itself**, reachable with your AWS credentials
   (`eks:DescribeCluster`) and with this identity mapped to enough Kubernetes
   RBAC to create namespaces/secrets/a Helm release (via an
   [EKS access entry](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html)
   or the legacy `aws-auth` ConfigMap).
2. **The AWS Load Balancer Controller**, already installed and running. Without
   it, `terraform apply` succeeds but no load balancer is ever created for the
   Ingress.
3. **The EBS CSI driver**, already installed as an EKS addon. Unlike GKE (whose
   PD CSI driver ships enabled by default), EKS does **not** enable this out of
   the box — without it, the bundled Redis PVC never binds.
4. **metrics-server**, already installed as an EKS addon. Also not enabled by
   default on EKS — without it there's no `metrics.k8s.io` APIService, so
   `kubectl top` and any CPU/memory-based HPA have nothing to read from.
5. **A managed Postgres 16 instance (RDS)** reachable from the cluster's VPC,
   unless you also set `create_rds = true` (provisioning path only).

## What provisioning (`deploy_cluster = true`) sets up

- **Networking** — a dedicated VPC (`vpc_cidr`, default `10.60.0.0/16`),
  public + private subnets per AZ (`availability_zones`), one NAT gateway by
  default (`single_nat_gateway = true` — a deliberate cost tradeoff over an
  HA one-per-AZ setup), optionally with both node groups pinned into a single
  AZ (`node_availability_zone`, default unset) to drop cross-AZ transfer
  between nodes, ALB and RDS: the cluster still spans every AZ because EKS
  requires at least two, so this only decides where nodes land, and changing it
  replaces both node groups. Subnets are tagged for the Load Balancer
  Controller's subnet
  auto-discovery (`kubernetes.io/role/elb` / `internal-elb` +
  `kubernetes.io/cluster/<name>=shared` — the AWS-specific analog of GKE's
  proxy-only-subnet requirement; forgetting these tags is the same
  silent-failure shape as GKE's missing `http_load_balancing` addon: the
  Ingress just never gets an address, with zero events).
- **Or your own network** (`create_network = false`): set `vpc_id` +
  `private_subnet_ids` (+ `public_subnet_ids` only for an internet-facing load
  balancer) and nothing above is created; the cluster, both node groups, the
  bastion and RDS all land in subnets you already run. The same three subnet
  tags are added to them by `aws_ec2_tag` (`tag_existing_subnets`, default
  true), one tag at a time so the rest of your tags are untouched, and **only
  where the tag is missing**: a tag your subnet already carries is skipped
  entirely, so this installer never takes ownership of it and a `destroy`
  cannot remove it. `terraform output subnet_tags_left_as_yours` lists the ones
  it skipped, and read it **before** a destroy, because afterwards the state is
  empty and the command prints `No outputs found`.

  Telling the two apart needs a record, so the installer writes **a fourth tag**,
  `marshal.codes/installer-owned-tags`, whose value is the list of keys it
  manages on that subnet. `destroy` removes it along with the tags it describes,
  so a teardown leaves the subnet as it was found. Without that record the filter
  is unstable: it cannot tell "already yours" from "mine, added last apply", so
  apply 2 reads its own tag back as pre-existing and **destroys** it, which
  strips the cluster tag on a routine `chart_version` upgrade. Verified against
  live subnets: three consecutive applies converge (`No changes` on 2 and 3) and
  a destroy leaves a pre-existing `kubernetes.io/role/internal-elb` in place.

  Set `tag_existing_subnets = false` when your own IaC owns those
  tags, and add them yourself. Validated at plan
  time by preconditions in `main.tf`: the subnets have to belong to `vpc_id`
  and cover at least two AZs, because EKS refuses a cluster otherwise. Egress
  is NOT validated here: `data.aws_route_table` given only a `subnet_id` errors
  with "no matching Route Table found" when the subnet has no explicit
  association rather than resolving the VPC's main table (verified live), and
  reimplementing association resolution is more machinery than the check is
  worth. `scripts/preflight-aws.sh` checks egress per subnet instead,
  read-only, before tfvars exist.
- **The EKS cluster** — `cluster_endpoint_private_access = true` always;
  `cluster_endpoint_public_access` **defaults to `false`**, matching GKE's
  private-only posture: Marshal runs on your internal network, not exposed to
  the internet. Reach a private-only cluster via the bastion below rather
  than a public endpoint. Set `cluster_endpoint_public_access = true` (with
  `cluster_endpoint_public_access_cidrs` locked to your real admin/CI ranges —
  enforced by an output precondition, which actually halts `plan`; a `check`
  block would only warn) only if you deliberately want a public,
  CIDR-restricted endpoint instead.
- **A bastion** (`create_bastion`, default `false`) — a
  small EC2 instance with **no public IP and no open inbound ports at all**,
  reachable only via AWS Systems Manager Session Manager
  (`aws ssm start-session --target <instance-id>`, IAM-authenticated, no SSH
  key to manage). It is a fallback, not the normal path: the installer opens the
  Kubernetes API endpoint to the VPC's own CIDR (`cluster_private_access_cidrs`),
  so the whole install runs as one `terraform apply` from anywhere that can
  already route into the VPC — a VPN, a zero-trust connector, a jump host. Build
  a bastion only if your policy allows none of those, and then run the whole
  install on it: it has git and NAT egress, so it clones this installer itself
  and nothing is shipped between machines.
- **Two node groups** — `spaces` (session/space workloads, default
  `m5.xlarge`) and `control_plane` (api/gateway/web/marketplace/redis only,
  default `m5.2xlarge` — **not smaller**: the chart's own baseline already
  needs ~4.4 vCPU of requests before any HPA scale-out, a lesson learned the
  hard way on the GCP side with an undersized default). `taint_control_plane_pool`
  (default `false`) taints the control-plane group AND sets the matching chart
  toleration atomically, same toggle shape as `gcp-gke`.
- **metrics-server** (EKS-managed addon, like EBS CSI) — no IRSA role needed,
  it only talks to the in-cluster kubelet API. Backs `kubectl top` and any
  CPU/memory-based HPA.
- **OIDC provider + IRSA** for the EBS CSI driver addon and the AWS Load
  Balancer Controller (Helm-installed from `https://aws.github.io/eks-charts`
  — it is **not** an EKS-managed addon, unlike EBS CSI). The ALB controller's
  IAM policy is a **vendored, pinned copy**
  (`policies/alb_iam_policy.json`, from `kubernetes-sigs/aws-load-balancer-controller`)
  — re-vendor it deliberately whenever the chart version is bumped; a stale
  copy can silently miss newer required actions.
- **RDS** (`create_rds = true`, opt-in) — a small, cheap `db.t4g.micro`
  instance, single-AZ (`rds_multi_az`, default false), 20GB gp3 storage, 1-day
  backup retention. Cheap on purpose: Marshal is a developer tool, so its
  database is not in the customer's own availability path, and Multi-AZ roughly
  doubles the instance bill. What is NOT cheap-by-default is losing it:
  `rds_deletion_protection` is **true** and `rds_skip_final_snapshot` is
  **false**, because this database holds the envelope-encrypted credential
  store and the audit trail, and both knobs cost nothing. The consequence is
  deliberate, and the two behave differently: `terraform destroy` **refuses**
  while `rds_deletion_protection` is true, whereas `rds_skip_final_snapshot`
  refuses nothing and simply leaves a `<cluster_name>-postgres-final` snapshot
  behind. Both must be changed **and applied** before a destroy, because the
  destroy reads them from state rather than from tfvars.
  **This is new surface area beyond `gcp-gke` parity** — `gcp-gke` has never provisioned
  Cloud SQL itself (confirmed: zero `google_sql_*` resources anywhere in that
  flavor's history); `create_rds` was added deliberately for a from-scratch
  AWS account with nothing pre-existing, not because GCP has an equivalent.

## TLS: where the certificate comes from

The ALB terminates TLS with an **ACM certificate and nothing else** (see
`alb_tls.tf`'s header for the live proof). `tls_mode="self_signed"` is NOT
HTTP-only here: this flavor imports the generated placeholder into ACM, so you
get a working HTTPS:443 listener with an untrusted certificate, confirmed on a
live install. Three real-certificate paths, mutually exclusive, both postures:

| Path | Variables | DNS work |
|---|---|---|
| A cert you already own in ACM | `acm_certificate_arn` | none |
| Request one, Route53 validates | `acm_request_certificate` + `acm_validation_route53_zone_id` | automatic |
| Request one, you validate | `acm_request_certificate` | you add one CNAME per host |

- The cert must be in the **same region** as the cluster. A foreign-region ARN
  is refused at plan by an output precondition rather than failing silently at
  the controller.
- `acm_certificate_arn` works on the **reuse** path too, unlike the `tls_mode`
  import path, which is `local.provision`-gated.
- Supplying either ACM variable **suppresses the placeholder import**, so there
  is no orphan self-signed cert sitting in ACM.
- The third path is two applies on purpose: an ALB listener rejects a cert in
  `PENDING_VALIDATION`, so the first apply comes up on HTTP:80 and prints
  `acm_validation_records`; once `acm_certificate_status` reads `ISSUED`, the
  next apply attaches it and adds the HTTPS listener plus the `ssl-redirect`.
  `local.alb_certificate_arn` (alb_tls.tf) is the single place that decides.
- A **public** ACM cert is fine on an internal ALB: DNS validation needs no
  inbound reachability. An internal-only zone needs ACM Private CA or your own
  PEM via `tls_mode="inline"`.

## Registry posture — direct pull by default; Harbor as an opt-in fallback

The cluster pulls straight from `registry.marshal.codes` using `deployment_id`
+ `registry_pull_token` (`registry_auth_mode = "secret"`). **There is no ECR
pull-through cache option, and there cannot be one**: confirmed live against
the real ECR API that `CreatePullThroughCacheRule` only accepts a hardcoded
enum of known upstreams (`ecr`, `ecr-public`, `docker-hub`,
`github-container-registry`, `gitlab-container-registry`,
`azure-container-registry`, `quay`, `k8s`, `chainguard`) — AWS validates the
upstream URL server-side against each type's real hostname, so there is no
parameter combination that lets it mirror a bespoke private registry like
`registry.marshal.codes` (`UnsupportedUpstreamRegistryException` on every
attempt). This is fundamentally different from `gcp-gke`'s
`create_registry_cache`, which uses GCP Artifact Registry's
`REMOTE_REPOSITORY` mode — that mode accepts *any* Docker v2 host, which is
exactly why the GCP flavor can mirror `registry.marshal.codes` directly and
ECR cannot.

### Harbor cache (`create_harbor_cache`, opt-in fallback)

Use this **only when direct-pull's shared rate limit becomes a real problem**
— it's not a default-on replacement, and it adds real operational surface
(an extra in-cluster workload, an S3 bucket, node-level config). When
enabled (`harbor.tf`):

- Harbor is deployed in-cluster (Helm, `https://helm.goharbor.io`), pinned to
  the **control-plane node group** (it's platform infrastructure, not a
  session workload) — lean config: no vulnerability scanner (`trivy.enabled
  = false`), Harbor's own bundled internal Postgres/Redis (not Marshal's
  RDS), blob storage on **S3** (`persistence.imageChartStorage.type = s3`,
  credential-less via IRSA — `harbor_storage_s3_regionendpoint` lets a
  future non-AWS flavor point this at any S3-compatible store instead).
- **The proxy is actually configured**, not just installed: a
  `harbor_registry` (via the `goharbor/harbor` Terraform provider) targets
  `registry.marshal.codes` using Harbor's generic `docker-registry` adapter
  type — verified against Harbor's own supported-upstream-types list that
  this works (unlike ECR, Harbor's proxy-cache isn't limited to a fixed
  vendor enum) — and a `harbor_project` turns it into a public
  (anonymous-read) proxy-cache project. Public is safe here: only reachable
  from inside the private VPC/cluster network in the first place.
- **Nodes reach it via a fixed, self-chosen ClusterIP**
  (`harbor_static_cluster_ip`), not a hostname — image pulls happen via
  containerd on the node's HOST network namespace, which can't resolve
  `*.svc.cluster.local` names (only pods' injected resolv.conf can); a
  ClusterIP sidesteps DNS entirely since kube-proxy's iptables/IPVS rules
  DNAT it regardless of source. Because a raw IP has no valid hostname for a
  certificate to match, Harbor serves plain HTTP internally
  (`expose.tls.enabled = false`), and both node groups get a small custom
  launch template (an EKS `nodeadm` `NodeConfig` snippet, merged
  automatically with the cluster-join config EKS generates) telling
  containerd to treat that one IP as HTTP instead of assuming HTTPS.
- **Configuring the proxy needs one manual step**: the `harbor` Terraform
  provider talks to Harbor's REST API over that same ClusterIP — but a
  ClusterIP is only routable from actual cluster nodes (kube-proxy's rules
  live on each node, not on arbitrary VPC hosts), so the bastion can't reach
  it directly the way node-level containerd can. Rather than stand up a
  second load balancer just for this one-time call, background a port
  forward from the bastion before `terraform apply`:
  ```bash
  kubectl port-forward -n harbor-cache svc/harbor 8080:80 &
  terraform apply
  ```
  The `harbor` provider always points at `http://localhost:8080` — inert
  (never invoked) when `create_harbor_cache = false`.

## Quickstart

```bash
cp ../examples/aws-eks.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform plan   # review
terraform apply
```

Decide where the state lives **before** that first `init`. The default is a local
`terraform.tfstate` file, which holds your licence token, registry pull token and
database password in cleartext and exists only on the machine you ran it from.
For anything you intend to keep, create a versioned, encrypted S3 bucket with a
public access block, point `backend_override.tf` at it, and then `init`. Doing it
afterwards means `terraform init -migrate-state` instead.

`terraform output next_steps` prints the verify commands and the app URL.

## Optional storage buckets

Two independent, off-by-default toggles (`buckets.tf`, mirroring
`gcp-gke/buckets.tf`) — S3 + IRSA for the api/supervisor ServiceAccounts:

```hcl
create_audit_persistence_bucket  = true   # compliance export of the session audit trail
create_spaces_persistence_bucket = true   # session pause/resume snapshots
```

Creating a bucket doesn't itself turn the feature on — wire the bucket via
the API afterward (audit: per-org config; spaces: `PUT
/api/org/space-storage` with `provider=s3`, confirmed against
`apps/api/internal/spacestorage`).

## Design references

- [`../modules/marshal-install`](../modules/marshal-install) — the
  cloud-agnostic install logic this flavor wraps (unchanged for AWS — its
  `registry_auth_mode = "workloadIdentity"` and `*_service_account_annotations`
  variables were already written generically enough to cover EKS IRSA, not
  just GKE Workload Identity).
- [`../gcp-gke`](../gcp-gke) — the flavor this one mirrors as closely as EKS's
  actual API allows.
