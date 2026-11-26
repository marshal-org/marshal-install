---
name: install-marshal
description: Install self-hosted Marshal into your own Kubernetes cluster with Terraform, on AWS (EKS), Google Cloud (GKE) or a single k3s node. Verifies your onboarding values, reads what it can from your cloud before asking, checks the environment, writes your terraform.tfvars with you, runs the apply, verifies the result, and explains what to do when a step fails. Use when installing Marshal, upgrading it to a new chart version, tearing an install down, or when an install has stopped partway and you need to know why.
---

# Install Marshal

This skill is for **you, the person installing Marshal into infrastructure you own**. Your
cluster, your network and your data stay yours: every step says what it will create before
it creates it, and nothing works around a guardrail that stops it.

**Supported chart versions:** 0.40.x and 0.39.x

This text matches the installer release you check out in step 0. If your `chart_version` is
older than the oldest version above, install a supported version instead: ask your Marshal
contact for one, and do not adapt these steps to an older chart. If it is newer, get the
current skill from `https://docs.marshal.codes/mcp`, which always serves the latest release.

The full guides are at **https://docs.marshal.codes/installing/prerequisites**. This skill is
the order to do things in, and what each failure means. It covers **EKS** and **GKE**. Where
the two differ, a section has an **On AWS** and an **On GKE** part; where one is not marked,
it applies to both. The single-node k3s flavor is short enough that its README is the whole
guide.

## How this skill works

One question at a time, in the order below, and **never a question whose answer can be read
or derived**. Before each question, try to answer it from your cloud CLI, your existing
Terraform, or a default that is right for most installs, then say which value was picked and
why. It stops and asks only when a wrong guess would cost you money or an outage.

Things it reads rather than asks:

| Value | Where it comes from |
|---|---|
| Cloud and account | `aws sts get-caller-identity`, `gcloud config get-value project` |
| Region | `aws configure get region`, `gcloud config get-value compute/region` |
| Existing clusters | `aws eks list-clusters --region <region>`, `gcloud container clusters list --project <project>` |
| Network, when reusing one | `aws ec2 describe-vpcs`, `aws ec2 describe-subnets`, `gcloud compute networks list` |
| Hosted DNS zones | `aws route53 list-hosted-zones`, `gcloud dns managed-zones list` |
| Quota in use | the AWS preflight (section 2), `gcloud compute regions describe <region>` |

## 0. Your onboarding values, and the installer checkout

Your Marshal contact sends four values when your deployment is created:

| Value | Looks like | What it is |
|---|---|---|
| `deployment_id` | `dep_ab12cd` | your deployment's identity, and the registry username |
| `installation_jwt` | `eyJhbGc…` | your licence |
| `registry_pull_token` | `mrpt_…` | pulls images and the chart |
| `chart_version` | `0.37.1` | the product version to install |

If any is missing, ask your Marshal contact for it. The registry deliberately refuses to list
versions, so `chart_version` cannot be discovered.

Prove them first. This fails in thirty seconds instead of twenty minutes:

```bash
# Read the token in rather than passing it on the command line: --password puts
# it in shell history, and helm itself warns about it.
read -rs MRPT            # paste the mrpt_ token, then Enter. Nothing is echoed.
printf '%s' "$MRPT" | helm registry login registry.marshal.codes \
  --username <deployment_id> --password-stdin
helm pull oci://registry.marshal.codes/marshal-charts/marshal --version <chart_version>
```

A `401 invalid pull token` means the token is not valid for this registry. There is nothing
to fix locally: go back to your Marshal contact. Check for a copy and paste error first: the
token starts with `mrpt_` and has two dots.

**Check out the installer tag for your chart version.** Each installer release is tagged
`v<chart_version>`, and a correction to the installer for a chart that is already out gets
`v<chart_version>-r1`, `-r2` and so on. Use the newest tag for your chart version:

```bash
git clone https://github.com/marshal-org/marshal-install.git
cd marshal-install
git fetch --tags
git tag -l 'v<chart_version>' 'v<chart_version>-r*' --sort=-v:refname | head -1   # the newest one
git checkout v<chart_version>          # or the -rN tag the line above printed
```

Every command and path below is relative to that checkout. Your own files (`terraform.tfvars`,
`*_override.tf`, state) are gitignored, so switching tags later never touches them.

## 1. Decide the shape of the install

**Which cloud.** Usually already known from the CLI you are signed in to:

| Where | Root | Notes |
|---|---|---|
| AWS | `aws-eks/` | Postgres on RDS, Redis in-cluster |
| Google Cloud | `gcp-gke/` | Postgres on Cloud SQL, Redis in-cluster |
| A single VM, an evaluation | `single-node-k3s/` | everything on one box |

**Who owns the cluster?** List the clusters in the account first. If there is one, ask
whether Marshal goes into it or onto a new one. Reusing a cluster is the lighter path;
provisioning gets you a private cluster, NAT and node pools sized for agent sessions in one
apply.

**Who owns the network?** Only relevant if the installer creates the cluster. A dedicated
VPC, or one you already run?

| Answer | Set |
|---|---|
| Your cluster | `deploy_cluster = false` (the default) |
| New cluster, dedicated network | `deploy_cluster = true` |
| New cluster, your network | `deploy_cluster = true` and `create_network = false` |

**On GKE, how will you reach the cluster?** Set `dns_endpoint_enabled = true`. That gives the
cluster Google's DNS endpoint, which is reachable from anywhere and gated by the
`container.clusters.connect` IAM permission instead of a source IP, so one `terraform apply`
works from your laptop and `master_authorized_networks` may stay empty. Without it the
control plane is private and the apply must run from inside the VPC: a VPN, or a throwaway
IAP bastion you create yourself (the README's "No existing VPN/bastion" section has the
commands). Prefer the DNS endpoint. Fetch the kubeconfig with the `--dns-endpoint` flag
(`terraform output kubeconfig_command` prints the exact command), or kubectl dials the private
IP and times out.

**On AWS, how will you reach the cluster?** Only when the installer creates it, because the
endpoint is private by default. This changes nothing in AWS. It decides which machine you run
the install from, and there is a path that needs only one.

| Your situation | Set | The install |
|---|---|---|
| A route into the VPC already: Twingate, Tailscale, Direct Connect, a transit gateway, a jump host | nothing | One `terraform apply` from your own machine |
| No route in | `cluster_endpoint_public_access = true` and `cluster_endpoint_public_access_cidrs` holding your own address | One `terraform apply`. Leave it CIDR-locked until everything, teardown included, is done. Read the warning below before you narrow it again |
| Policy forbids a public endpoint, even briefly | `create_bastion = true` | The **whole** install runs on the bastion |

Prefer the first, then the second. Both run on one machine, in one pass, with no files moved
between hosts.

The CIDR list is a list of objects, not a list of strings. A bare string is rejected at plan
time with `Invalid value for input variable`:

```hcl
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = [
  { cidr_block = "203.0.113.4/32", display_name = "installer" }
]
```

**On the second path, returning the endpoint to private is a one-way door while you are
outside the VPC. Do it last, or not at all.** Measured on a live install: the apply that makes
the endpoint private succeeds, and from that moment every `terraform` command in this flavour
exits 1 before touching anything:

```
Error: Kubernetes cluster unreachable: ... dial tcp 10.60.0.102:443: i/o timeout
  with helm_release.aws_load_balancer_controller[0]
```

The Kubernetes and Helm providers connect while they configure, which happens during refresh,
before any resource is read or changed. So the apply that would re-open the endpoint cannot
reach the endpoint either. You cannot plan, apply or destroy, and the teardown in section 6
fails at its **first** apply, leaving RDS deletion protection still on in state.

A CIDR-locked public endpoint is not an open endpoint: it is reachable from one address you
control, and access still needs an IAM identity with an EKS access entry plus RBAC. Leaving it
that way until you are finished with the deployment is the right trade. If you have already
locked yourself out, see "Kubernetes cluster unreachable, and no apply can fix it" below.

The endpoint hostname resolves in public DNS even while the cluster is private. It answers
with addresses inside the VPC, so a tunnel has to carry **routing to the private subnets**,
not DNS. In Twingate or Tailscale that means the connector or subnet router runs inside the
VPC and advertises that CIDR. A tunnel that only forwards the hostname will still fail.

**Do you have DNS for the hostname?** `ingress_host` is what people will type to reach
Marshal, for example `marshal.yourcompany.com`. It is required at plan time but only has to be
a name. For a trial without your own DNS, any placeholder (for example
`marshal.trial.internal`) works: you reach the app over
`kubectl port-forward -n marshal svc/web 8080:80` and `http://localhost:8080`, which needs no
DNS and no route to the load balancer (section 5). The `https://<host>` links in the output
work only once that name resolves to the load balancer and your machine can reach it.

**Who installs the chart?** Terraform (simple) or ArgoCD (GitOps). For ArgoCD, read "If ArgoCD
installs the chart" in section 4 before writing anything: that path has traps Terraform does
not.

If you are reusing a cluster, three things must already be in place and each fails
**silently** if missing: the AWS Load Balancer Controller (or an ingress controller on GKE),
the EBS CSI driver on EKS, and a reachable Postgres 16.

## 2. Check the environment before writing any configuration

**On AWS**, run the preflight. It is read-only, takes seconds, and reports every problem in
one pass instead of failing one at a time during an apply. Put the pull token in a file only
you can read, so it never reaches your shell history or the process list:

```bash
MRPT_FILE=$(umask 077; mktemp)                                   # a new file only you can read
read -rs MRPT; printf '%s' "$MRPT" > "$MRPT_FILE"; unset MRPT
scripts/preflight-aws.sh --region <region> \
  --ingress-host <hostname> \
  --deployment-id <dep> --pull-token-file "$MRPT_FILE" --chart-version <ver>
rm -f "$MRPT_FILE"
```

Add `--vpc-id` and `--private-subnets` when you bring your own network. Do not pass
`--cluster-name` unless you are reusing a cluster: the "does not exist" line is correct but
reads like a failure.

**Interpret the output, do not just forward it.** The ones that matter most:

| Result | What it means |
|---|---|
| `routes via an internet gateway, so this subnet is PUBLIC` | These are public subnets, not private ones. Use the private tier. The most common mix-up. |
| `no 0.0.0.0/0 route` | Nodes cannot pull images and the install will fail partway. Add NAT, a transit gateway or a proxy first. |
| `kubernetes.io/role/internal-elb absent` | Let `tag_existing_subnets` add it, which is the default. Without it the Ingress never gets an address **and emits no events**, which is slow to diagnose. If the tag is already there the installer leaves it alone, so a later teardown cannot remove a tag that was yours: it records what it owns in a `marshal.codes/installer-owned-tags` tag on each subnet, removed again at destroy. |
| `only N free IPs` | Every pod takes a real subnet IP, so this caps concurrent sessions. Under about 60, get a bigger subnet now. |
| `AZ coverage: 1 AZ` | EKS will not create a cluster. Add a second subnet. |
| `on-demand vCPU quota` low | A quota increase can take days. Start it immediately. Ask for **72 vCPU**: the default shape needs 16 to create (one `m5.2xlarge` spaces node plus one `m5.2xlarge` control-plane node), 18 with the bastion, 58 once it has scaled out to its default limits, and 8 more during a node group update. Under 16 it FAILs, because the cluster cannot be created at all; between 16 and 71 it warns, because the quota, not `node_max_size`, then caps how many spaces can run. |
| `DENIED, not a version problem` | IAM or an organization policy (an SCP) refused the call, so the check could not even ask. Do not change versions. If it names a service control policy, your AWS organization may restrict regions: nothing installs in this region until your organization admin allows it, or you pick a region the policy allows. |

A clean preflight proves the environment, not your permissions.

**On GKE** there is no preflight script. Check these before the apply, because each one
otherwise fails partway:

| Check | How, and what it means |
|---|---|
| Signed in, and Terraform can see it | `gcloud auth list`. Terraform's Google providers read Application Default Credentials (`gcloud auth application-default login`), **not** a plain `gcloud auth login`. If you only did the latter, `export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)`. It lasts about an hour, so refresh it before a long apply or destroy. |
| Permissions | `roles/owner` is **not** enough. It does not include `container.clusters.connect`, and installing the chart needs `container.clusterRoles.create`. `roles/container.admin` carries both. |
| Billing is on, and you may enable APIs | `gcloud billing projects describe <project>`. The installer enables the APIs it needs (`enable_project_apis`), which needs `serviceusage.services.enable`; if your organization enables APIs centrally, set it `false` and enable them first (the README lists the command). `sqladmin` and `servicenetworking` are for the Cloud SQL you create yourself, so enable those by hand. |
| Plan-time API | The plan reads the project number, so Cloud Resource Manager must be on before Terraform runs; the apply cannot enable it. On a fresh project, or when the ADC quota project is the new project, the first plan otherwise fails with `Cloud Resource Manager API has not been used in project <project> before or it is disabled`. `gcloud services enable cloudresourcemanager.googleapis.com --project <project>`. |
| Artifact Registry service agent | On a brand-new project it does not exist until something asks for it. The gcp-gke flavor creates it; by hand it is `gcloud beta services identity create --service=artifactregistry.googleapis.com`. Without it the apply fails on an IAM member naming a principal that is not there. |
| CPU quota | On a fresh project the Compute API is off and every `gcloud compute` call fails with `SERVICE_DISABLED`, so enable it first: `gcloud services enable compute.googleapis.com --project <project>` (the apply enables it anyway; this only runs it earlier). Then `gcloud compute project-info describe --project <project> --format=json` for `CPUS_ALL_REGIONS`, and `gcloud compute regions describe <region> --project <project> --format=json` for the regional `CPUS` and `SSD_TOTAL_GB`. Add up the vCPUs of the control-plane pool (default `e2-standard-8`) and the spaces pool (default `e2-standard-8`) at their **starting** node count, times the number of zones for a regional `location`, and compare. A 32 vCPU project cannot go higher by self-service, so start a quota request first if the pools are sized up. |
| Disk quota | The regional `SSD_TOTAL_GB` quota (often 500 GB) counts `pd-balanced` too. The defaults are a 300 GB spaces disk and a 50 GB control-plane disk, one node of each per zone: for a 3-zone region that is 1050 GB, so ask for 1200 GB or more before the apply. A bigger `disk_size_gb` multiplies it. |
| Region and zones | `location` is a region or a zone; a region creates one node per zone for each pool, so node counts and the quota above are per zone, and a regional cluster costs roughly three times a zonal one with the same numbers. A regional create needs capacity in every zone at once: if it fails with `GCE_STOCKOUT` (measured at about 3m50s, twice, in `europe-west1`), use a zonal `location` such as `europe-west1-b`, which came up in 8m22s. Recover from the failed create as in section 4. |

**On both clouds, egress.** The cluster needs outbound 443 to `registry.marshal.codes`,
`keys.marshal.codes`, `tokens.marshal.codes` and `marketplace.marshal.codes`. Nothing inbound
from Marshal is ever needed.

## 3. Fill in the configuration

```bash
cd aws-eks           # or gcp-gke, or single-node-k3s
umask 077                    # every file terraform writes from here on is 0600
cp ../examples/aws-eks.tfvars.example terraform.tfvars    # gcp-gke.tfvars.example on GKE
chmod 600 terraform.tfvars   # it will hold the licence JWT and the pull token
```

Then write the values into `terraform.tfvars` from what sections 0 to 2 established, rather
than handing you a template to fill in: transcription is where errors come from. Leave the
rest at their defaults, and show the file with a line on what each non-obvious value does
before anything is applied.

A local `terraform.tfstate` holds the same secrets plus the database password, and Terraform
creates it, and its `.backup`, with the shell's umask, often `-rw-rw-r--`. Remote state
(section 4) is the answer for anything you keep. On local state, a trial included, keep
`umask 077` in that shell, and if state files already exist run `chmod 600 terraform.tfstate*`.

The questions with no safe default:

- **Postgres:** managed (RDS, Cloud SQL) for anything you keep; in-cluster
  (`database_mode = "bundled"`) is for evaluations and loses its data with the volume.
- **TLS:** a certificate you already have, or one cert-manager gets for you. *Preview URLs*
  for agent sessions need a **wildcard** certificate, which needs ACME DNS-01; HTTP-01 cannot
  issue one.
- **Object storage:** always ask, below.

**On GKE** the values to settle, beyond the shared ones: `project_id`, `location`,
`deploy_cluster = true` for a new cluster, `dns_endpoint_enabled = true` (section 1),
`taint_control_plane_pool` (`true` by default; leave it, because without it a space pod can
land beside the api and control-plane pods can take the spaces nodes' CPU), and
`image_streaming_enabled = true` for faster space starts on fresh nodes. Anything you keep
wants Cloud SQL (Postgres 16, private IP) and `database_mode = "external"`.
`deletion_protection = false` is needed only to destroy later. Keep the control-plane pool's
maximum at 2 or more: with a ceiling of 1 the chart's PodDisruptionBudgets never allow
draining the last replica, so a node change sits `Ready,SchedulingDisabled` forever.

**Cloud SQL on a new cluster is two applies.** Cloud SQL's private IP needs the VPC, and with
`deploy_cluster = true` that VPC is created by the apply. So: first apply with
`install_marshal = false` (it builds the network and cluster, enables the Cloud SQL APIs, and
installs nothing; ignore the ArgoCD steps it prints), then create Cloud SQL on
`<cluster_name>-vpc` with the README's "Provisioning Cloud SQL yourself" commands, then set
`database_url` and `install_marshal = true` and apply again. Never `-target` the VPC instead.
The plan stops if `database_url` is empty while `install_marshal` is true. On your own
cluster or network the VPC exists, so Cloud SQL comes first and the install is one apply.

**Agree `cluster_name` before writing it.** Do not invent one, and do not reach for something
like `marshal-test`: it is the name of real infrastructure in your account, it is stamped into
node groups, IAM roles, security groups and the database's final snapshot, and changing it
later means replacing all of them. Use your naming convention. If this really is a throwaway,
say so, because that changes the RDS answers in section 6 too.

`chart_version` comes from your onboarding, not from the example file. The example carries the
version this installer was published for, which is a reasonable default but not an
instruction.

Your `terraform.tfvars` and your state belong in your own repository and your own backend:
both contain your licence token, registry token and database password. Never paste either
into a chat, a ticket or a commit in this clone.

### Object storage: always ask, and recommend both

Two buckets, each behind its own toggle, and both are off unless you set them. Ask about them
every time, explain the trade, and recommend turning on both:

| Toggle | What it gives you | Without it |
|---|---|---|
| `create_spaces_persistence_bucket = true` | Stop, resume, fork and archive for spaces. A space's files are saved and come back on resume. | No fork or archive, and a space keeps its files across stop and resume only on a compute size with a persistent disk. |
| `create_audit_persistence_bucket = true` | The audit log streamed to a bucket in your own account, as your compliance copy. | Audit events stay inside Marshal only. |

How each bucket is operated, before you decide:

**Which identity uses the bucket.** No keys are created or stored. The installer creates the
storage identities and binds them to Marshal's Kubernetes service accounts:

- **EKS:** two IAM roles bound through IRSA: `<cluster_name>-storage-role` for the api (either
  bucket), and `<cluster_name>-supervisor-storage-role` for the supervisor, with access to the
  spaces bucket only.
- **GKE:** two Google service accounts, bound through Workload Identity:
  `<cluster_name>-storage` for the api (either bucket), and `<cluster_name>-sup-storage` (the
  cluster name cut to 18 characters) for the supervisor, with access to the spaces bucket
  only, because session pods run agent code and must not reach the audit bucket.

Audit uses the **api** service account (`marshal-api` in the `marshal` namespace). Space
storage uses the api **and** the **supervisor** (`marshal-supervisor` in `marshal-spaces`),
because the supervisor does the snapshot reads and writes inside each session pod. The grants
are object-level, on each bucket only.

**Who turns it on.** The bucket is the storage. The feature is switched on in Marshal by an
**owner or admin** after the install, per organization:

- **Settings > Space Storage:** choose the provider and enter the bucket name. On S3 also
  enter the **Region**: the bucket's own region, which for an installer-created bucket is the
  cluster's `region`. A wrong one fails the connection test with `PermanentRedirect` (an S3
  301).
- **Settings > Auditing:** in the **Storage** card, choose the provider, enter the bucket
  name, and select **Save & enable**.

The bucket name comes from `terraform output spaces_persistence_bucket` /
`audit_persistence_bucket`, without the `s3://` or `gs://` prefix. Leave the credential fields
empty; the identity above signs every request. Each organization added later is connected the
same way, by its own owner or admin.

**When to bring your own bucket instead.**

- **EKS:** the installer creates the buckets when it also creates the cluster
  (`deploy_cluster = true`). On a cluster you already run, leave both toggles out. Create the
  bucket and an IRSA role with object access to it, then set:
  - `api_service_account_annotations = { "eks.amazonaws.com/role-arn" = "<role arn>" }`
  - a **separate** role with access to the spaces bucket only in
    `supervisor_service_account_annotations`. Never the api's role: the supervisor runs in
    session pods, next to agent code.

  The cluster needs an IAM OIDC provider for this.
- **single-node-k3s:** use any S3, GCS or Azure bucket, and enter its access key or
  service-account JSON in the same Settings pages. That credential must reach the spaces
  bucket and nothing else (GCS: a dedicated service account with `roles/storage.objectAdmin`
  on that bucket only; S3: a policy that names only that bucket). Marshal hands it to the
  supervisor in every session pod. Never use a key with project-wide storage, editor or owner
  rights.

Write the answer into `terraform.tfvars` either way. If you decline, set both to `false` with
a comment, so the next person reading the file sees a decision rather than a gap.

## 4. Apply

**Confirm before the first apply that creates billable resources**, with a rough monthly cost
at the floor: a two-node GKE install with managed Postgres is around $600 a month.

**Credentials must outlast the apply.** On AWS, `aws configure export-credentials` (which some
Terraform provider versions need, see the README) hands out a snapshot that can expire in
**about 15 minutes**, and a first apply takes longer. When it expires mid-apply you get
`ExpiredTokenException` and a half-built cluster. Use a profile that refreshes itself instead:
`credential_process = aws configure export-credentials --profile <login-profile> --format
process` in `~/.aws/config`, then `export AWS_PROFILE=<that profile>` for terraform, helm,
kubectl and every aws call, because the kubeconfig runs `aws eks get-token` and reads the same
variable. The README's "AWS credentials for Terraform" has the exact lines. On GKE the same
rule holds for `GOOGLE_OAUTH_ACCESS_TOKEN`: it lasts about an hour.

**On AWS, put the state in S3 before the first apply.** It is your state either way, but a
bucket survives a lost laptop, and it is the only way a second person can run the next
upgrade. Terraform cannot create its own backend, so the bucket is made first, by hand:

```bash
aws s3api create-bucket --bucket <name>-tfstate --region <region> \
  --create-bucket-configuration LocationConstraint=<region>
aws s3api put-bucket-versioning --bucket <name>-tfstate \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket <name>-tfstate \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Name it so it contains `tfstate`. The bastion's IAM role grants S3 only on
`arn:aws:s3:::*tfstate*`, so another name works from your machine and fails on the bastion,
which is a confusing way to find out. Then add `backend_override.tf` (gitignored, so it
survives a version switch) and run `terraform init`. Use `terraform init -migrate-state`
**only** if you already ran an apply against local state; on a first install there is nothing
to migrate and plain `init` is correct. The state holds your licence token, registry token and
database password, so versioning, encryption and a public access block are not optional.

**On GKE** the same holds with a GCS bucket in your project (versioning on, uniform
bucket-level access on), configured in `backend_override.tf`.

Only then apply:

```bash
terraform init
terraform plan      # read it before applying
terraform apply
```

The plan stops early on a bad input rather than failing twenty minutes in. If a precondition
fires, the message says what to change; it is a real requirement, not a warning to route
around.

One apply does the whole install: the cloud resources and the Kubernetes ones, in dependency
order. Do not split it, and **never narrow it with `-target`**. `-target` pulls in a
resource's dependencies but not its dependents, so targeting one resource quietly skips the
policy attachments that hang off it.

**If the apply reaches the Kubernetes resources and cannot connect**, the machine has no route
to the private endpoint. The cloud half is already created and in the state, so nothing is
lost and nothing needs recreating. Get a route, or set `cluster_endpoint_public_access = true`
with your own address, and run the same `terraform apply` again. It carries on from where it
stopped.

**If an apply is interrupted for any other reason** (expired credentials, a closed laptop, a
timeout), do not just run it again. **Run `terraform plan` first and read it.** A cluster
whose create had not finished waiting is *tainted* in state, and the next apply destroys and
rebuilds it: about 8 minutes on EKS, and everything already on it. If the cluster is healthy
(`aws eks describe-cluster --name <cluster_name> --query cluster.status` says `ACTIVE`, or the
GKE cluster is `RUNNING`), `terraform untaint 'aws_eks_cluster.this[0]'` (GKE:
`google_container_cluster.this[0]`) takes it out of the plan, and the apply then carries on
from where it stopped.

**A GKE cluster whose create failed** (`ERROR`, or `GCE_STOCKOUT` in the apply) cannot be
replaced by the next apply: the destroy half of the replacement stops on `Cannot destroy
cluster because deletion_protection is set to true`, because a tainted resource is destroyed
with the values in state, and setting `deletion_protection = false` in tfvars does not change
state. Delete it with `gcloud container clusters delete <cluster_name> --location <location>
--project <project>` and apply again; the refresh sees it gone and creates a new one. Change
`location` first if the cause was a stockout.

On the bastion path, the bastion runs the whole install, so give it the credentials for that
job and delete it when the install is done. Do not run half the install on one machine and
half on another: the two share nothing but the state, and the hand-off is where installs go
wrong.

### If ArgoCD installs the chart

Set `install_marshal = false` so Terraform builds the cluster and installs nothing.

**`deployment_id` and `registry_pull_token` must still be real** even though nothing is
installed: the registry cache uses them as upstream credentials. Only `installation_jwt` can
be a placeholder here.

**Do not retype the chart values.** Terraform computes every cloud-derived one even when it
installs nothing:

```bash
terraform output -raw argocd_derived_values > values-derived.yaml
```

That covers the registry endpoints, the storage service account on **both** the api and the
supervisor, the ingress class, the control-plane scheduling, and bundled Redis's own
scheduling. Re-run it after any apply that changes the project, cluster name, cache repo,
buckets or the node taint.

Seed these Secrets **before the first sync**, and set `secrets.provider: existing`:

```bash
kubectl create namespace marshal
kubectl create secret generic marshal-app-secrets -n marshal \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=KMS_LOCAL_KEY="$(openssl rand -hex 32)" \
  --from-literal=SETUP_TOKEN="$(openssl rand -hex 24)"
kubectl create secret generic marshal-license -n marshal --from-literal=jwt='<installation_jwt>'
```

All three keys. **Back up `KMS_LOCAL_KEY`**: lose it and every credential stored in Marshal
becomes unreadable. `argocd/README.md` has the full flow.

## 5. Verify, and hand over

```bash
terraform output next_steps

# kubectl has no cluster yet. Without this it talks to localhost:8080 and the
# whole verify step looks like a broken install.
aws eks update-kubeconfig --name <cluster_name> --region <region>   # GKE: the command in `terraform output kubeconfig_command`

kubectl get pods -n marshal
kubectl logs -n marshal -l app.kubernetes.io/component=api --tail=-1 | grep -i "license state"
```

That licence line includes your `deployment_id` as a JSON field, so it lands in the terminal
and in any scrollback you share. It is an identifier rather than a credential, but it is one
of the four onboarding values, so trim it before pasting the output into a ticket.

**`--tail=-1` is not optional.** With a label selector `kubectl logs` returns only the last 10
lines per pod, and the licence line sits near the top of a long log. Without it the command
prints nothing on a correctly licensed install, which reads as a licensing failure.

**On GKE the load balancer is not ready when the apply finishes.** Expect 5 to 15 minutes
before the Ingress has an address and HTTPS answers (measured: 5 to 10 minutes for the
address, up to 12.5 for HTTPS). Until then the URL times out, fails the TLS handshake or
returns 502 while every pod is healthy. Watch `kubectl get ingress -n marshal -w` rather than
concluding anything is wrong.

Expect every pod `Running` and a line reporting the licence state as `LICENSED`. Then run the
`install-health-check` skill: `python3 scripts/health-check.py` prints PASS, WARN or FAIL for
each part of the install.

The certificate is a self-signed placeholder until you supply a real one, so a browser warning
at this stage is expected, not a fault: see the TLS section of your cloud's page. Create the
DNS record for your hostname **after** the Ingress is serving and holds its certificate: a
name that resolves early serves the wrong certificate.

If you took the buckets, have the owner connect them in **Settings > Space Storage** and
**Settings > Auditing** (see [Object storage](#object-storage-always-ask-and-recommend-both)),
then launch a space, stop it, and resume it. That round trip is the only check that exercises
the supervisor's identity: the connection test in Settings runs in the api pod, so it passes
even when the supervisor cannot reach the bucket.

### Claim the owner account

Last step of every install, run here rather than left for later:

```bash
# Secret name: <release_name>-app-secrets (or secrets_existing_secret). Key: SETUP_TOKEN.
# The exact command is in `terraform output next_steps`.
kubectl get secret <release>-app-secrets -n <namespace> -o jsonpath='{.data.SETUP_TOKEN}' | base64 -d
```

Then print ONE full link, with the token filled in, so you click it and only add your email
and password:

```
<app_url>/setup#token=<SETUP_TOKEN>
```

`<app_url>` is the URL you can actually reach. On aws-eks the ALB is internal by default, and
so is the GKE load balancer, so from outside the VPC that is `http://localhost:8080` over
`kubectl port-forward -n <namespace> svc/web 8080:80` (the CLI also connects through it), not
the ingress host. On GKE this needs the DNS endpoint, so your laptop can reach the control
plane.

The token is in the URL fragment (after `#`), which the browser never sends to the server. If
the token field on the page is empty, open `<app_url>/setup` and paste the token by hand.
Never put the token in a Terraform output, a file, a ticket or a commit: it is a credential
until the owner exists. If the secret has no `SETUP_TOKEN` key (external secrets without a
setup-token ref), the page says setup is off and the owner account cannot be claimed until
you add one. If the page says "already set up", someone claimed it already: stop and find out
who.

If there is no browser at all, the owner claim is one call. Read the password without echoing
it (it must not contain `"` or `\`); add `-k` while the certificate is the placeholder:

```bash
read -rs PW
curl -s -X POST <app_url>/api/auth/setup -H 'Content-Type: application/json' \
  -d "{\"token\":\"<SETUP_TOKEN>\",\"email\":\"<email>\",\"password\":\"$PW\",\"org_name\":\"<org>\"}"
```

`201` means the owner exists; `409` means someone already claimed it. Change that first
password once you are in.

With no browser, `marshal login` hangs waiting for one. Use `marshal login --server <url>
--password` (or `--device`).

### Make the first space possible

Do these with the owner account, in this order, before you call the install finished.

1. **Connect the spaces bucket first, if there is one:** *Settings > Space Storage*, then
   *Save & enable*. On S3, set **Region** to the bucket's region (the cluster's `region`). Via
   the API, `PUT /api/org/space-storage` with
   `{"provider":"s3","bucket":"<bucket>","region":"<region>","path_prefix":"space-volumes"}`
   (`"provider":"gcs"` and no region on GKE), then `PATCH /api/org/space-storage/enabled`
   with `{"enabled":true}`; the PUT alone leaves it disabled. **A space created before this
   still loses its workspace when stopped**, even after you connect the bucket, so connect it
   before anyone creates one.
2. **Add your credentials.** Your AI credential (an Anthropic key) and a git credential. A
   launch fails with `policy_violation` until every integration in a manifest has a
   credential. For GitHub, use a **fine-grained personal access token**; "Sign in with GitHub"
   needs an admin to install the Marshal GitHub App on your organization first.
3. **Build the first stack and manifests.** A new install has **no stacks and no manifests**,
   so *New space* has nothing to offer and `marshal spaces new` stops with `a manifest is
   required to create a space`. The fastest good result is the Marshal plugin's
   `suggest-stack` skill: it reads your repositories, works out the toolchains, tools and
   credentials your agents need, and builds a tailored stack and a manifest per repo over the
   API.
   - **The plain default, for the generic starter:** **Marketplace > Stacks** > **Install
     stack** on `default-engineering` (installs its packages and creates a draft), then
     *Stacks* > open the draft > **Publish v1**. A stack installs unpublished and is invisible
     to manifests until published. The docs'
     [Publish your first stack](https://docs.marshal.codes/getting-started/owner#publish-your-first-stack)
     is the same flow, and the API calls are on https://docs.marshal.codes/day-2 ("Set up from
     a terminal").
4. **New space > Create a manifest** from the published stack, then launch the space.
   `suggest-stack` creates the manifests for you in step 3; otherwise make one here.

Then launch a space, stop it, resume it, and confirm a file written before the stop is still
there (the workspace is `/home/agent`).

## Upgrading an existing install: decide every new capability

An upgrade can add capabilities, or change a default, that your existing install never chose.
Applying it blindly can restart things or replace a node group. So do this **before**
`terraform plan`, every time:

1. **Find the two versions.** The installer version you run (`git describe --tags` in the
   checkout you applied from, or the `chart_version` in `terraform.tfvars`) and the version
   you are upgrading to. Check out the newest tag for the new chart version, as in section 0
   (`git fetch --tags`, then `git checkout v<new chart_version>` or its newest `-rN`); your
   `terraform.tfvars` stays put. Use the skill text from that tag, or the latest from
   `https://docs.marshal.codes/mcp`.
2. **Read `capabilities.yaml`** at the repo root. Every entry whose `since` is newer than your
   version, and that lists your flavor, is a decision for you. (`since: unreleased` entries
   apply to everyone on a pre-release checkout.)
3. **Skip the ones you already decided.** If the entry's variable is already set in your
   `terraform.tfvars`, report "you set this to X, no change" and move on.
4. **Ask about the rest, one at a time**, in plain words. For each, say:
   - what it is and what the **default** is now (and `previous`, for a changed default);
   - what the default would do to **your** install (`effect_on_existing`), and whether it is
     **disruptive** (stops spaces or replaces a resource), saying so first;
   - what is recommended (`recommend`), and any prerequisite (`needs`);
   - the choices: **enable**, **disable**, or **keep what I have** (for a changed default,
     that means writing the old value into `terraform.tfvars`).
   Entries with `when: before` are asked before the plan. Entries with `when: after` are
   offered after the upgrade has been applied and verified.
5. **Write the answer into `terraform.tfvars` explicitly**, whichever way you go, using the
   entry's `enable` / `disable` text. An explicit value means the next upgrade will not ask
   again and the default can never move under you.
6. **Only then plan**, after `terraform init -upgrade` (the lock file is not in the
   repository, so a plain `init` keeps the old provider versions and can refuse the new tag's
   constraints). Read the plan against the answers: a disruptive entry you chose to keep must
   show no replacement. If the plan replaces a node group or pool you did not choose to
   change, stop and fix the tfvars.
7. After the apply and the checks in section 5, go back to the `when: after` entries and
   decide them.

**Bundled datastores and the control-plane taint.** On an install upgraded from a version
where `taint_control_plane_pool` was off, with `redis_mode` or `database_mode = "bundled"` and
no `node_availability_zone`, write `pin_bundled_datastores = false` with the taint. Check
first: `kubectl get pod -n marshal marshal-redis-master-0 marshal-postgresql-0 -o wide` and
`kubectl get nodes -l workload=control-plane`. If they already run on a control-plane node (an
install that ran the taint before), keep the default `true`: `false` would move them off it
into the same Pending state. With `false` they stay put only until their next reschedule,
which then needs an untainted node in the volume's zone. Otherwise the apply moves Redis (or
Postgres) to the control-plane node, whose zone often differs from its volume's, and the pod
stays Pending with `didn't match PersistentVolume's node affinity`: Redis down, the api
crash-looping on `connect to redis ... connection refused`, the helm upgrade waiting out its
timeout. Measured on an EKS 0.29.0 upgrade: about 5 minutes of API outage. If it already
happened with Redis: its data is rebuildable, so
`kubectl -n marshal delete pvc redis-data-marshal-redis-master-0` and delete the
`marshal-redis-master-0` pod; it starts fresh in the right zone. Never do that to a bundled
Postgres: set `pin_bundled_datastores = false` and apply instead, which puts it back next to
its volume.

**Quota.** The recommendation is 72 vCPU on AWS. An install sized for less upgrades fine, but
the autoscaler's default maximums then exceed the quota; ask for the increase.

**Spaces on the control-plane node.** With the taint off, spaces could start on the
control-plane node too. When moving spaces to a new node group, `kubectl get pods -n
marshal-spaces -o wide` shows where each runs; ask the owners of those on a control-plane node
to stop and resume as well. The `add-node-pool` skill has the full move.

Never skip an entry because its default looks harmless. Ask, then record the answer.

## 6. Tearing one down

One procedure on both clouds, in this order. `terraform destroy` on its own does not do it,
and the order is not optional: on AWS the wrong order **deadlocks with no error message at
all**, leaving the cluster and the database up and billing.

If you reached an EKS cluster through a CIDR-locked public endpoint, **check it is still open
before you start**. The whole teardown runs terraform and `kubectl` against the API, and step
3 is the first thing that fails if it is private and you are outside the VPC.

```bash
# 1. Delete every space in Marshal FIRST. A running space keeps saving its
#    workspace to the spaces bucket in the background and would refill a bucket
#    the destroy is emptying. (Each owner's spaces: marshal spaces list, then
#    marshal spaces delete <id> --yes.)

# 2. Turn the guardrails off, in terraform.tfvars. Each is read from STATE by the
#    destroy, so a value that has not been through an apply has no effect.
force_destroy_buckets   = true        # both clouds, when the buckets are on: empties them
# AWS, with create_rds:
rds_deletion_protection = false
rds_skip_final_snapshot = true        # leave this out to KEEP a final snapshot
# GKE, a cluster the installer created:
deletion_protection     = false

# 3. Apply them.
terraform apply

# 4. AWS only: NOW delete the workload, and not before. This takes the Ingress
#    and its finalizer away before terraform can revoke the load balancer
#    controller's IAM policy, which is what otherwise deadlocks the destroy, and
#    it lets the EBS CSI driver delete the PVC volumes while it still has
#    permission to. The chart owns two namespaces: the release namespace and
#    "<release>-spaces", where session pods live. Deleting only the first leaves
#    the second behind, which matters on the reuse path (deploy_cluster = false)
#    where the cluster outlives the destroy.
kubectl delete namespace marshal marshal-spaces   # about a minute; EBS volumes go too
#    GKE only, with Cloud SQL on a VPC the installer created: delete the
#    instance, the servicenetworking peering and the PSA range (the README's
#    "Tearing down" has the three commands). The destroy cannot delete the VPC
#    while they hold it, and they bill until removed.

# 5. Then destroy.
terraform destroy
```

**Expected durations**, so a long wait is not mistaken for a hang: about **12 minutes** on EKS
(measured: 12m05s, 59 resources; the last node group takes about 8 of them, because its
CoreDNS pods' disruption budget holds the drain until EKS stops waiting), and about **15 to 20
minutes** on GKE. On GKE the destroy deletes the release and its namespace first, waits for
GKE to release the load balancer's forwarding rules, and only then removes the cluster,
subnet, static IP and VPC. It prints `Warning: Helm uninstall returned an information message
... marshal-app-secrets kept due to the resource policy`; that is expected. If it stops on
`resourceInUseByAnotherResource`, delete the leftover `k8s2-*` / `gkegw1-*` forwarding rules
and run it again. If it stops after about 18 minutes on `network ... already being used by
.../addresses/google-managed-services-<vpc>`, step 4's Cloud SQL cleanup was skipped: do it
and destroy again. The rest of this section is AWS detail.

**Do not move step 4 to the front.** Terraform owns the Helm release, so once the namespace is
gone the apply in step 3 sees the release as deleted and **reinstalls the entire product**.
Measured on a real teardown: `Plan: 5 to add, 1 to change`, which put back the load balancer,
three target groups, two controller-created security groups and the Redis volume roughly two
minutes before the destroy ran. Flags first, apply, then the namespace.

Step 3 is normally a quick in-place database change. On a cluster whose install failed partway
it can also replace a tainted addon, so read the plan instead of assuming.

**What outlives the destroy**, because Terraform never owned any of it:

- **A final RDS snapshot**, `<cluster_name>-postgres-final`, unless you skipped it in step 2.
  Keep it if the data matters. It also blocks a rebuild under the same cluster name, because
  the snapshot name collides.
- **EBS volumes from PersistentVolumeClaims**, if you skipped step 4.
- **The load balancer, its target groups, and any security group the controller created**, if
  the controller lost its IAM policy before it finished its own cleanup. Step 4 prevents this
  as well.
- **Two things EKS creates itself, which block the VPC delete.** If the destroy sits on
  `aws_subnet.private` or `aws_vpc.this` for more than a few minutes, look for (1) a leftover
  VPC CNI network interface in the subnet (description `aws-K8S-i-...`, status `available`):
  `aws ec2 delete-network-interface --region <region> --network-interface-id <eni>`; and (2)
  the cluster security group `eks-cluster-sg-<cluster_name>-*`, which EKS made and Terraform
  never owned: `aws ec2 delete-security-group --region <region> --group-id <sg>`. The destroy
  then finishes on its own retry or a re-run.
- **A storage bucket, with its data**, even after `Destroy complete!`. If the refresh at the
  start of the destroy reads a bucket as missing, Terraform drops it from state without a
  message and never deletes it. Check both names after every destroy:
  `aws s3api head-bucket --bucket <cluster_name>-spaces-persistence-<account_id>` (and
  `-audit-persistence-`); remove a survivor with
  `aws s3 rb --force s3://<name> --region <region>`.

Subnet tags your subnets already carried are **not** in that list and are not at risk: the
installer skips any tag that was already there, so a destroy leaves it alone.
`terraform output subnet_tags_left_as_yours` lists them, but run it **before** step 5: once the
destroy has finished the state is empty and the same command prints `Warning: No outputs
found` and still exits 0.

Find anything that did survive. **Every one of these is filtered by `<cluster_name>`, and that
matters**: if you have more than one Marshal install in the account, an unfiltered search
returns the other one's resources too, and the next block deletes whatever the search
returned. Target group names differ only by a random suffix, so you cannot tell them apart by
eye.

```bash
aws ec2 describe-volumes --region <region> \
  --filters Name=tag:KubernetesCluster,Values=<cluster_name> \
  --query 'Volumes[].VolumeId' --output text

# Target groups by TAG, never by name prefix. Measured with two installs in one
# account: a `starts_with(TargetGroupName, "k8s-marshal")` query returned six,
# three of them belonging to a different, healthy cluster.
aws resourcegroupstaggingapi get-resources --region <region> \
  --resource-type-filters elasticloadbalancing:targetgroup \
  --tag-filters Key=elbv2.k8s.aws/cluster,Values=<cluster_name> \
  --query 'ResourceTagMappingList[].ResourceARN' --output text

aws ec2 describe-security-groups --region <region> \
  --filters Name=tag:elbv2.k8s.aws/cluster,Values=<cluster_name> \
  --query 'SecurityGroups[].GroupId' --output text

# Scoped to this cluster's database, not every manual snapshot in the account.
aws rds describe-db-snapshots --region <region> --snapshot-type manual \
  --db-instance-identifier <cluster_name>-postgres \
  --query 'DBSnapshots[].DBSnapshotIdentifier' --output text
```

Then remove what they return, in this order, because a security group cannot go while a
target group still references it. **Read each id back against the cluster name before you
delete it.** These four commands are irreversible and they do not check whose resource it is:

```bash
aws elbv2 delete-target-group --target-group-arn <arn>
aws ec2 delete-security-group --group-id <id>
aws ec2 delete-volume --volume-id <id>
aws rds delete-db-snapshot --db-snapshot-identifier <name>
```

## Warnings that are not problems

- **`ipv6_association_id is deprecated` / `ipv6_cidr_block is deprecated`, blamed on
  `cluster_private_access.tf`.** May appear on a plan or an apply, and may not. Nothing on the
  line it names reads an IPv6 attribute: the warning comes from the AWS provider's own
  `aws_vpc` data source, and the line number is just where that data source is referenced.
  Harmless, nothing to change, and no reason to edit a `.tf` file.
- **`Warning: Deprecated value used` on `providers.tf` line 46 (GKE, a cluster the installer
  creates).** Appears on runs once the cluster exists. Its last line says `The deprecation
  originates from google_container_cluster.this[0].binary_authorization[0].enabled`: line 46
  reads the cluster's endpoint out of the whole cluster object, and that object carries a
  field the Google provider marks deprecated. The installer never sets it. Harmless, nothing
  to change.
- **`RESTARTS 1` on an api pod right after a fresh install.** The container exits once during
  startup and recovers by itself, with every pod `Running` and the licence `LICENSED`. If it
  restarts more than once, or never reaches `Running`, that is a different problem: read the
  log with `--previous`.

## When something fails

- **`ExpiredTokenException` (AWS) or `invalid_grant` / a 401 from the Google providers (GKE)
  partway through an apply.** The credentials expired, not the installer. Refresh them (a
  self-refreshing profile on AWS, a new `GOOGLE_OAUTH_ACCESS_TOKEN` on GKE), then run
  `terraform plan` and read it before applying: a half-created cluster is replaced, not
  resumed (section 4).
- **GKE: the URL times out or returns 502 for the first 5 to 15 minutes while all pods are
  healthy.** The load balancer is still being programmed. Wait, watching
  `kubectl get ingress -n marshal -w`; nothing needs fixing.
- **`marshal spaces new` says `a manifest is required to create a space`.** A new install has
  no manifests yet. See "Make the first space possible" in section 5.
- **A stopped space comes back empty.** Space Storage is not connected (or the space is on a
  size without a persistent disk). Connect the bucket in *Settings > Space Storage*; spaces
  stopped before that are not recoverable.
- **Pods in `ImagePullBackOff`.** The image host and the pull credential disagree, or the
  token is not valid. Compare the image in `kubectl describe pod` with the registry in your
  configuration.
- **The Ingress never gets an address.** On AWS, the load balancer controller is missing, or
  the subnet tags are. Check the controller exists before anything else.
- **`terraform plan` fails inside `provider "helm"`.** The pull token is wrong or empty. The
  provider signs in while it configures itself, so this happens before any resource is read
  and the error names the provider rather than the token.
- **The load balancer answers 502 while pods are healthy.** A health check is pointing at a
  path that returns 404. Compare the target group's health check path with what the service
  actually serves.
- **An EKS addon is `CREATE_FAILED` and the apply exits 1.** Read the message: if it names a
  webhook with `no endpoints available`, the addon raced the AWS Load Balancer Controller's
  Service webhook. A plain `terraform apply` again fixes it, and the warning Terraform prints
  about purging the addon's configuration is harmless here, because the addon never finished
  being created and carries no configuration to lose.
- **After an upgrade, Redis is `Pending` with `didn't match PersistentVolume's node affinity`
  and the api crash-loops on `connect to redis`.** The control-plane taint moved the bundled
  Redis to a node in another zone from its volume. See "Bundled datastores and the
  control-plane taint" under "Upgrading an existing install".
- **`terraform destroy` fails on the database.** Deletion protection is on by design. Set
  `rds_deletion_protection = false`, apply that, then destroy. Doing it in the other order
  tears down everything else first and then stops.
- **`Kubernetes cluster unreachable`, and no apply can fix it.** You are outside the VPC and
  the endpoint is private, so the Helm and Kubernetes providers cannot configure, and that
  happens before terraform reads a single resource. Every plan, apply and destroy exits 1.
  Terraform cannot dig you out, because the change that would restore access is behind the
  connection it cannot make. Re-open it with the AWS API directly, which does not go through
  the endpoint:

  ```bash
  aws eks update-cluster-config --name <cluster_name> --region <region> \
    --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=<your.ip>/32
  aws eks describe-update --name <cluster_name> --region <region> --update-id <id>
  ```

  Wait for the update to report `Successful`, then carry on. Set
  `cluster_endpoint_public_access = true` with the same CIDR in your tfvars too, or the next
  apply will try to close it again. This is the only step in this skill that goes around
  terraform, and it exists because the alternative is an install nobody can remove.
- **`terraform destroy` prints `Still destroying...` forever and never errors.** It is waiting
  on `helm_release.marshal`, which is waiting on the Ingress's `ingress.k8s.aws/resources`
  finalizer, which is waiting on a load balancer controller that no longer has the IAM policy
  terraform just revoked. Confirm with `helm list -n marshal --all` (`uninstalling`) and a 403
  in `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`. It
  will not resolve on its own. To get out:
  1. `Ctrl-C` is not enough. Graceful shutdown waits for the in-flight call, and the
     in-flight call is the one that never returns. Kill the terraform process.
  2. That strands a lock. Read the ID out of the `.tflock` object next to your state and
     `terraform force-unlock <id>`.
  3. `terraform apply`. **It will exit 1** on `"marshal" has no deployed releases`, because
     the helm provider will not touch a release stuck in `uninstalling`. Let it. It restores
     the IAM policy before it fails, and that is the part you need.
  4. `kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system`.
     Without this the controller is in exponential backoff and can sit silent for fifteen
     minutes or more, with nothing in its log to say so. After the restart the finalizer
     clears in seconds.
  5. Then start section 6 again, from step 2.

  Installers from `v0.23.0-r3` onward do not have this failure: the controller's policy
  attachment is now destroyed after the release rather than beside it.

Full list: https://docs.marshal.codes/troubleshooting

When something is wrong and you cannot see why, run the `install-health-check` skill first,
then collect the evidence with the `support-bundle` skill before anything is restarted:
`scripts/support-bundle.sh --since 6h --space <name>` writes the cluster state and the
supervisor, agent and control-plane logs into one redacted folder and `.tar.gz`. It only
reads. Send it to Marshal support with your question.

## Traps that have cost someone a day

- **`secrets.provider: generated` under ArgoCD re-randomises `JWT_SECRET` and `KMS_LOCAL_KEY`
  on every sync.** Helm's `lookup()` does not run there. Always `existing`.
- **A missing `SETUP_TOKEN`** leaves first-run setup switched off, and the owner account can
  never be claimed.
- **`api.extraEnv` is a list, not a map.** A map fails the template with "Cannot concat type
  map as list".
- **A second `api:` block in a values file silently wins** and drops whatever the first one
  set, including the service-account annotation that object storage depends on.
- **A wrong `supervisor.serviceAccount.annotations` fails only at session runtime**, long
  after the install looks healthy.
- **The Workload Identity pool does not exist until the first cluster does**, so any
  `workloadIdentityUser` binding applied before the cluster fails with "Identity Pool does
  not exist", which reads like a typo and is not.

## Rules

- **Never disable a guardrail to make an apply pass.** The preconditions, the deletion
  protection and the final snapshot are all deliberate. If one blocks the install, the input
  is wrong, not the check.
- **Never print or commit your secrets.** The licence token, registry token and database
  password all live in files that stay untracked. On an upgrade, the first plan can show
  `registryAuth.secret.password` in clear text once: it comes from the release record of an
  apply made by an older installer, and the plans after that apply print `(sensitive value)`.
  Do not paste that first plan output anywhere.
- **Stop and ask when an answer would change what gets created**, especially anything that
  replaces a node group, a database or a network.
- Upgrading is a new tag, `chart_version` plus `terraform apply`, after you have decided every
  new capability in `capabilities.yaml` (see "Upgrading an existing install"), and rolling
  back is `helm rollback marshal -n marshal`.
