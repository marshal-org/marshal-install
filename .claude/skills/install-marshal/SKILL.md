---
name: install-marshal
description: Install self-hosted Marshal into your own Kubernetes cluster with Terraform, on AWS (EKS), Google Cloud (GKE) or a single k3s node. Checks the environment first, fills in the configuration with you, runs the apply, and explains what to do when a step fails. Use when installing Marshal, upgrading it to a new chart version, or when an install has stopped partway and you need to know why.
---

# Install Marshal

You are helping someone install Marshal into infrastructure **they own**. Treat
their cluster, their network and their data as theirs: explain what a step will
create before creating it, and never work around a guardrail that stops you.

The full guides are at **https://docs.marshal.codes/installing/prerequisites**.
This skill is the order to do things in, and what each failure means.

It covers **EKS** and **GKE**. Where the two differ, the section has an **On AWS**
and an **On GKE** part; where one is not marked, it applies to both. The
single-node k3s flavor is short enough that its README is the whole guide.

## 0. What they need before anything

Four values, issued once per deployment by their Marshal contact:
`deployment_id`, `installation_jwt`, `registry_pull_token`, and the
`chart_version` to install. Prove them first, because nothing below works
without them:

```bash
# Read the token in rather than passing it on the command line: --password puts
# it in shell history, and helm itself warns about it.
read -rs MRPT            # paste the mrpt_ token, then Enter. Nothing is echoed.
printf '%s' "$MRPT" | helm registry login registry.marshal.codes \
  --username <deployment_id> --password-stdin
helm pull oci://registry.marshal.codes/marshal-charts/marshal --version <chart_version>
```

A `401 invalid pull token` means the token is not valid for this registry.
There is nothing to fix locally: go back to their Marshal contact. Check for a
copy and paste error first, the token starts with `mrpt_` and has two dots.

## 1. Decide the shape of the install

Two questions. Ask both before touching any file.

**Who owns the cluster?** An EKS or GKE cluster they already run, or should the
installer create one?

**Who owns the network?** Only relevant if the installer creates the cluster. A
dedicated VPC, or one they already run?

| Answer | Set |
|---|---|
| Their cluster | `deploy_cluster = false` (the default) |
| New cluster, dedicated network | `deploy_cluster = true` |
| New cluster, their network | `deploy_cluster = true` and `create_network = false` |

**On GKE, how will they reach the cluster?** Set `dns_endpoint_enabled = true`.
That gives the cluster Google's DNS endpoint, which is reachable from anywhere and
gated by the `container.clusters.connect` IAM permission instead of a source IP,
so one `terraform apply` works from their laptop and `master_authorized_networks`
may stay empty. Without it the control plane is private and the apply must run
from inside the VPC: a VPN, or a throwaway IAP bastion you create yourself (the
README's "No existing VPN/bastion" section has the commands). Prefer the DNS endpoint. Fetch the
kubeconfig with the `--dns-endpoint` flag (`terraform output kubeconfig_command`
prints the exact command), or kubectl dials the private IP and times out.

**On AWS, how will they reach the cluster?** Only when the installer creates it, because
the endpoint is private by default. This changes nothing in AWS. It decides which
machine you run the install from, and there is a path that needs only one.

| Their situation | Set | The install |
|---|---|---|
| A route into the VPC already: Twingate, Tailscale, Direct Connect, a transit gateway, a jump host | nothing | One `terraform apply` from their own machine |
| No route in | `cluster_endpoint_public_access = true` and `cluster_endpoint_public_access_cidrs` holding their own address | One `terraform apply`. Leave it CIDR-locked until everything, teardown included, is done. Read the warning below before you narrow it again |
| Policy forbids a public endpoint, even briefly | `create_bastion = true` | The **whole** install runs on the bastion |

Prefer the first, then the second. Both run on one machine, in one pass, with no
files moved between hosts.

The CIDR list is a list of objects, not a list of strings. A bare string is
rejected at plan time with `Invalid value for input variable`:

```hcl
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = [
  { cidr_block = "203.0.113.4/32", display_name = "operator" }
]
```

**On the second path, returning the endpoint to private is a one-way door while
you are outside the VPC. Do it last, or not at all.** Measured on a live install:
the apply that makes the endpoint private succeeds, and from that moment every
`terraform` command in this flavour exits 1 before touching anything:

```
Error: Kubernetes cluster unreachable: ... dial tcp 10.60.0.102:443: i/o timeout
  with helm_release.aws_load_balancer_controller[0]
```

The Kubernetes and Helm providers connect while they configure, which happens
during refresh, before any resource is read or changed. So the apply that would
re-open the endpoint cannot reach the endpoint either. You cannot plan, apply or
destroy, and the teardown in section 6 fails at its **first** apply, leaving RDS
deletion protection still on in state.

A CIDR-locked public endpoint is not an open endpoint: it is reachable from one
address you control, and access still needs an IAM identity with an EKS access
entry plus RBAC. Leaving it that way until the deployment is finished with is the
right trade. If you have already locked yourself out, see "Kubernetes cluster
unreachable, and no apply can fix it" below.

The endpoint hostname resolves in public DNS even while the cluster is private.
It answers with addresses inside the VPC, so a tunnel has to carry **routing to
the private subnets**, not DNS. In Twingate or Tailscale that means the connector
or subnet router runs inside the VPC and advertises that CIDR. A tunnel that only
forwards the hostname will still fail.

If they are reusing a cluster, three things must already be in place and each
fails **silently** if missing: the AWS Load Balancer Controller (or an ingress
controller on GKE), the EBS CSI driver on EKS, and a reachable Postgres 16.

## 2. Check the environment before writing any configuration

**On AWS**, run the preflight. It is read-only, takes seconds, and reports every
problem in one pass instead of failing one at a time during an apply. Put the
pull token in a file only you can read, so it never reaches your shell history
or the process list:

```bash
umask 077; read -rs MRPT; printf '%s' "$MRPT" > /tmp/mrpt && unset MRPT
scripts/preflight-aws.sh --region <region> \
  --ingress-host <hostname> \
  --deployment-id <dep> --pull-token-file /tmp/mrpt --chart-version <ver>
rm /tmp/mrpt
```

Add `--vpc-id` and `--private-subnets` when they are bringing their own
network. Do not pass `--cluster-name` unless they are reusing a cluster: the
"does not exist" line is correct but reads like a failure.

**Interpret the output, do not just forward it.** The ones that matter most:

| Result | What it means |
|---|---|
| `routes via an internet gateway, so this subnet is PUBLIC` | They gave you public subnets believing they were private. Ask for the private tier. The most common mix-up. |
| `no 0.0.0.0/0 route` | Nodes cannot pull images and the install will fail partway. They need NAT, a transit gateway or a proxy first. |
| `kubernetes.io/role/internal-elb absent` | Let `tag_existing_subnets` add it, which is the default. Without it the Ingress never gets an address **and emits no events**, which is slow to diagnose. If the tag is already there the installer leaves it alone, so a later teardown cannot remove a tag that was theirs: it records what it owns in a `marshal.codes/installer-owned-tags` tag on each subnet, removed again at destroy. |
| `only N free IPs` | Every pod takes a real subnet IP, so this caps concurrent sessions. Under about 60, ask for a bigger subnet now. |
| `AZ coverage: 1 AZ` | EKS will not create a cluster. Get a second subnet. |
| `on-demand vCPU quota` low | A quota increase can take days. Start it immediately. Ask for **72 vCPU**: the default shape needs 16 to create (one `m5.2xlarge` spaces node plus one `m5.2xlarge` control-plane node), 18 with the bastion, 58 once it has scaled out to its default limits, and 8 more during a node group update. Under 16 it FAILs, because the cluster cannot be created at all; between 16 and 71 it warns, because the quota, not `node_max_size`, then caps how many spaces can run. |
| `DENIED, not a version problem` | IAM or an organization policy (an SCP) refused the call, so the check could not even ask. Do not change versions. If it names a service control policy, the account's organization may restrict regions: nothing installs in this region until their AWS organization admin allows it, or they pick a region the policy allows. |

A clean preflight proves the environment, not their permissions. Say so.

**On GKE** there is no preflight script; check these by hand before the apply,
because each one otherwise fails partway:

| Check | How, and what it means |
|---|---|
| Signed in, and Terraform can see it | `gcloud auth list`. Terraform's Google providers read Application Default Credentials (`gcloud auth application-default login`), **not** a plain `gcloud auth login`. If they only did the latter, `export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)`. It lasts about an hour, so refresh it before a long apply or destroy. |
| Billing is on, and they may enable APIs | `gcloud billing projects describe <project>`. The installer enables the APIs it needs (`enable_project_apis`), which needs `serviceusage.services.enable`; if their organization enables APIs centrally, set it `false` and enable them first (the README lists the command). |
| CPU quota | `gcloud compute project-info describe --project <project> --format=json` and read the `CPUS_ALL_REGIONS` and regional `CPUS` limits. Add up the vCPUs of the control-plane pool (default `e2-standard-8`) and the spaces pool (default `e2-standard-8`) at their **starting** node count, times the number of zones for a regional `location`, and compare. A 32 vCPU project cannot go higher by self-service, so start a quota request first if the pools are sized up. |
| Disk quota | The regional `SSD_TOTAL_GB` quota (often 500 GB) counts `pd-balanced` too. The defaults are a 300 GB spaces disk and a 50 GB control-plane disk, one node of each per zone: for a 3-zone region that is 1050 GB, so ask for 1200 GB or more before the apply. A bigger `disk_size_gb` multiplies it. |
| Region and zones | `location` is a region or a zone; a region creates one node per zone for each pool, so the quota above is per zone count. |

## 3. Fill in the configuration

```bash
cd aws-eks           # or gcp-gke, or single-node-k3s
cp ../examples/aws-eks.tfvars.example terraform.tfvars    # gcp-gke.tfvars.example on GKE
chmod 600 terraform.tfvars   # it will hold the licence JWT and the pull token
```

**On GKE** the values to settle with them, beyond the shared ones: `project_id`,
`location`, `deploy_cluster = true` for a new cluster, `dns_endpoint_enabled = true`
(above), `taint_control_plane_pool` (now `true` by default; leave it, because without it a
space pod can land beside the api and control-plane pods can take the spaces
nodes' CPU), and
`image_streaming_enabled = true` for faster space starts on fresh nodes. For an
evaluation `database_mode = "bundled"` runs Postgres in the cluster; anything
they keep wants Cloud SQL (Postgres 16, private IP) and `database_mode =
"external"`. `deletion_protection = false` is needed only to destroy later.

**Agree `cluster_name` with them before you write it.** Do not invent one, and
do not reach for something like `marshal-test`: it is the name of real
infrastructure in their account, it is stamped into node groups, IAM roles,
security groups and the database's final snapshot, and changing it later means
replacing all of them. Ask what their naming convention is. If this really is a
throwaway, have them say so, because that changes the RDS answers in section 6
too.

`chart_version` comes from their onboarding, not from the example file. The
example carries the version this installer was published for, which is a
reasonable default but not an instruction.

Work through the rest **with** them. Confirm the chart version against their
onboarding rather than the example's placeholder. Their `terraform.tfvars` and
their state belong in their own repository and their own backend: both contain
their licence token, registry token and database password. Never paste either
into a chat, a ticket or a commit in this clone.

### Object storage: always ask, and recommend both

Two buckets, each behind its own toggle, and both are off unless you set them.
Ask about them every time, explain the trade, and recommend turning on both:

| Toggle | What it gives them | Without it |
|---|---|---|
| `create_spaces_persistence_bucket = true` | Stop, resume, fork and archive for spaces. A space's files are saved and come back on resume. | No fork or archive, and a space keeps its files across stop and resume only on a compute size with a persistent disk. |
| `create_audit_persistence_bucket = true` | The audit log streamed to a bucket in their own account, as their compliance copy. | Audit events stay inside Marshal only. |

Before they decide, tell them how each bucket is operated:

**Which identity uses the bucket.** No keys are created or stored. The installer
creates one storage identity and binds it to Marshal's Kubernetes service
accounts:

- **EKS:** an IAM role `<cluster_name>-storage-role`, bound through IRSA.
- **GKE:** a Google service account `<cluster_name>-storage`, bound through
  Workload Identity.

Audit uses the **api** service account (`marshal-api` in the `marshal`
namespace). Space storage uses the api **and** the **supervisor**
(`marshal-supervisor` in `marshal-spaces`), because the supervisor does the
snapshot reads and writes inside each session pod. The grants are object-level,
on that bucket only.

**Who turns it on.** The bucket is the storage. The feature is switched on in
Marshal by an **owner or admin** after the install, per organization:

- **Settings > Space Storage:** choose the provider and enter the bucket name.
- **Settings > Auditing:** in the **Storage** card, choose the provider, enter
  the bucket name, and select **Save & enable**.

The bucket name comes from `terraform output spaces_persistence_bucket` /
`audit_persistence_bucket`, without the `s3://` or `gs://` prefix. Leave the
credential fields empty; the identity above signs every request. Each
organization added later is connected the same way, by its own owner or admin.

**When to bring their own bucket instead.**

- **EKS:** the installer creates the buckets when it also creates the cluster
  (`deploy_cluster = true`). On a cluster they already run, leave both toggles
  out. They create the bucket and an IRSA role with object access to it, then
  set:
  - `api_service_account_annotations = { "eks.amazonaws.com/role-arn" = "<role arn>" }`
  - the same in `supervisor_service_account_annotations` for space storage.

  The cluster needs an IAM OIDC provider for this.
- **single-node-k3s:** use any S3, GCS or Azure bucket, and enter its access key
  or service-account JSON in the same Settings pages.

Write their answer into `terraform.tfvars` either way. If they decline, set both
to `false` with a comment, so the next person reading the file sees a decision
rather than a gap.

## 4. Apply

**Credentials must outlast the apply.** On AWS, `aws configure export-credentials`
(which some Terraform provider versions need, see the README) hands out a snapshot
that can expire in **about 15 minutes**, and a first apply takes longer. When it
expires mid-apply you get `ExpiredTokenException` and a half-built cluster. Use a
profile that refreshes itself instead: `credential_process = aws configure
export-credentials --profile <login-profile> --format process` in
`~/.aws/config`, then `export AWS_PROFILE=<that profile>` for terraform, helm,
kubectl and every aws call, because the kubeconfig runs `aws eks get-token` and
reads the same variable. The README's "AWS credentials for Terraform" has the
exact lines. On GKE the same rule holds for `GOOGLE_OAUTH_ACCESS_TOKEN`: it lasts
about an hour.

**On AWS, put the state in S3 before the first apply.** It is their state either way, but
a bucket survives a lost laptop, and it is the only way a second person can run
the next upgrade. Terraform cannot create its own backend, so the bucket is made
first, by hand:

```bash
aws s3api create-bucket --bucket <name>-tfstate --region <region> \
  --create-bucket-configuration LocationConstraint=<region>
aws s3api put-bucket-versioning --bucket <name>-tfstate \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket <name>-tfstate \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Name it so it contains `tfstate`. The bastion's IAM role grants S3 only on
`arn:aws:s3:::*tfstate*`, so another name works from their machine and fails on
the bastion, which is a confusing way to find out. Then add `backend_override.tf`
(gitignored, so it survives a version switch) and run `terraform init`. Use
`terraform init -migrate-state` **only** if you already ran an apply against
local state; on a first install there is nothing to migrate and plain `init`
is correct. The state holds their licence token, registry token and
database password, so versioning, encryption and a public access block are not
optional.

**On GKE** the same holds with a GCS bucket in their project (versioning on,
uniform bucket-level access on), configured in `backend_override.tf`.

Only then apply:

```bash
terraform init
terraform plan      # read it with them before applying
terraform apply
```

The plan stops early on a bad input rather than failing twenty minutes in. If a
precondition fires, the message says what to change; it is a real requirement,
not a warning to route around.

One apply does the whole install: the AWS resources and the Kubernetes ones, in
dependency order. Do not split it, and **never narrow it with `-target`**.
`-target` pulls in a resource's dependencies but not its dependents, so
targeting one resource quietly skips the policy attachments that hang off it.

**If the apply reaches the Kubernetes resources and cannot connect**, the machine
has no route to the private endpoint. The AWS half is already created and in the
state, so nothing is lost and nothing needs recreating. Get a route, or set
`cluster_endpoint_public_access = true` with their own address, and run the same
`terraform apply` again. It carries on from where it stopped.

**If an apply is interrupted for any other reason** (expired credentials, a closed
laptop, a timeout), do not just run it again. **Run `terraform plan` first and
read it.** A cluster whose create had not finished waiting is *tainted* in state,
and the next apply destroys and rebuilds it: about 8 minutes on EKS, and
everything already on it. If the cluster is healthy
(`aws eks describe-cluster --name <cluster_name> --query cluster.status` says
`ACTIVE`, or the GKE cluster is `RUNNING`), `terraform untaint
'aws_eks_cluster.this[0]'` (GKE: `google_container_cluster.this[0]`) takes it out of
the plan, and the apply then carries on from where it stopped.

On the bastion path, the bastion runs the whole install, so give it the
credentials for that job and delete it when the install is done. Do not run half
the install on one machine and half on another: the two share nothing but the
state, and the hand-off is where installs go wrong.

## 5. Verify, and hand over

```bash
terraform output next_steps

# kubectl has no cluster yet. Without this it talks to localhost:8080 and the
# whole verify step looks like a broken install.
aws eks update-kubeconfig --name <cluster_name> --region <region>   # GKE: the command in `terraform output kubeconfig_command`

kubectl get pods -n marshal
kubectl logs -n marshal -l app.kubernetes.io/component=api --tail=-1 | grep -i "license state"
```

That licence line includes their `deployment_id` as a JSON field, so it lands in
the terminal and in any scrollback they share. It is an identifier rather than a
credential, but it is one of the four onboarding values, so do not paste the
output into a ticket without trimming it.

**`--tail=-1` is not optional.** With a label selector `kubectl logs` returns only the
last 10 lines per pod, and the licence line sits near the top of a long log. Without it
the command prints nothing on a correctly licensed install. That reads as a licensing
failure and is the likeliest reason a customer calls you after a successful install.

**On GKE the load balancer is not ready when the apply finishes.** Expect 5 to 15
minutes before the Ingress has an address and HTTPS answers (measured: 5 to 10
minutes for the address, up to 12.5 for HTTPS). Until then the URL times out,
fails the TLS handshake or returns 502 while every pod is healthy. Watch
`kubectl get ingress -n marshal -w` rather than concluding anything is wrong.

Expect every pod `Running` and a line reporting the licence state as
`LICENSED`. Then point them at their hostname. The certificate is a self-signed
placeholder until they supply a real one, so a browser warning at this stage is
expected, not a fault: see the TLS section of their cloud's page.

If they took the buckets, have the owner connect them in **Settings > Space
Storage** and **Settings > Auditing** (see
[Object storage](#object-storage-always-ask-and-recommend-both)), then launch a
space, stop it, and resume it. That round trip is the only check that exercises
the supervisor's identity: the connection test in Settings runs in the api pod,
so it passes even when the supervisor cannot reach the bucket.

### Claim the owner account

Last step of every install. Run it yourself, do not leave it to them:

```bash
# Secret name: <release_name>-app-secrets (or secrets_existing_secret). Key: SETUP_TOKEN.
# The exact command is in `terraform output next_steps`.
kubectl get secret <release>-app-secrets -n <namespace> -o jsonpath='{.data.SETUP_TOKEN}' | base64 -d
```

Then print ONE full link, with the token filled in, so they click it and only add
their email and password:

```
<app_url>/setup#token=<SETUP_TOKEN>
```

`<app_url>` is the URL they can actually reach. On aws-eks the ALB is internal by
default, and so is the GKE load balancer, so from outside the VPC that is
`http://localhost:8080` over `kubectl port-forward -n <namespace> svc/web 8080:80`
(chart 0.29 or newer; the CLI also connects through it), not the ingress host.
On GKE this needs the DNS endpoint, so the laptop can reach the control plane.

The token is in the URL fragment (after `#`), which the browser never sends to
the server. The `/setup` page reads it from chart 0.26 on. Add one fallback line:
if the token field is empty, open `<app_url>/setup` and paste the token by hand
(charts older than 0.26). Never put the token in a Terraform
output, a file, a ticket or a commit: it is a credential until the owner exists.
If the secret has no `SETUP_TOKEN` key (external secrets without a setup-token
ref), the page says setup is off: tell them, and do not invent one. If the page
says "already set up", someone claimed it already: stop and ask them.

### Make the first space possible

Do these with the owner, in this order, before you call the install finished.

1. **Connect the spaces bucket first, if there is one:** *Settings > Space
   Storage*, then *Save & enable* (via the API, `PUT /api/org/space-storage` and
   then `PATCH /api/org/space-storage/enabled` with `{"enabled":true}`; the PUT
   alone leaves it disabled). **A space created before this still loses its
   workspace when stopped**, even after you connect the bucket, so connect it
   before anyone creates one.
2. **Marketplace:** install a stack, for example `default-engineering`, and
   **publish** it. A new install has **no stacks and no manifests**, so *New
   space* has nothing to offer and `marshal spaces new` stops with `a manifest is
   required to create a space`; the CLI cannot create either one yet. A stack
   installs unpublished and is invisible to manifests until published.
3. **New space > Create a manifest**, from that stack, then launch the space.

Then launch a space, stop it, resume it, and confirm a file written before the
stop is still there (the workspace is `/home/agent`).

With no browser, `marshal login` hangs waiting for one. Use `marshal login
--server <url> --password` (or `--device`).

If there is no browser at all, the owner claim is one call. Read the password
without echoing it (it must not contain `"` or `\`); add `-k` while the certificate is
the placeholder:

```bash
read -rs PW
curl -s -X POST <app_url>/api/auth/setup -H 'Content-Type: application/json' \
  -d "{\"token\":\"<SETUP_TOKEN>\",\"email\":\"<email>\",\"password\":\"$PW\",\"org_name\":\"<org>\"}"
```

`201` means the owner exists; `409` means someone already claimed it.

## Upgrading an existing install: ask about every new capability

An upgrade can add capabilities, or change a default, that your existing install
never chose. Applying it blindly can restart things or replace a node group. So do
this **before** `terraform plan`, every time:

1. **Find the two versions.** The installer version you run (`git describe --tags`
   in the checkout you applied from, or the `chart_version` in `terraform.tfvars`)
   and the tag you are upgrading to. Check out the new tag; keep your
   `terraform.tfvars`.
2. **Read `capabilities.yaml`** at the repo root. Every entry whose `since` is newer
   than your version, and that lists your flavor, is a decision for you. (`since:
   unreleased` entries apply to everyone on a pre-release checkout.)
3. **Skip the ones you already decided.** If the entry's variable is already set in
   your `terraform.tfvars`, report "you set this to X, no change" and move on.
4. **Ask about the rest, one at a time**, in plain words. For each, say:
   - what it is and what the **default** is now (and `previous`, for a changed default);
   - what the default would do to **your** install (`effect_on_existing`), and
     whether it is **disruptive** (stops spaces or replaces a resource), saying so first;
   - what you recommend (`recommend`), and any prerequisite (`needs`);
   - the choices: **enable**, **disable**, or **keep what I have** (for a changed
     default, that means writing the old value into `terraform.tfvars`).
   Entries with `when: before` are asked before the plan. Entries with `when: after`
   are offered after the upgrade has been applied and verified.
5. **Write the answer into `terraform.tfvars` explicitly**, whichever way they go,
   using the entry's `enable` / `disable` text. An explicit value means the next
   upgrade will not ask again and the default can never move under you.
6. **Only then plan.** Read the plan against the answers: a disruptive entry the
   customer chose to keep must show no replacement. If the plan replaces a node group
   or pool they did not choose to change, stop and fix the tfvars.
7. After the apply and the checks in section 5, go back to the `when: after` entries
   and ask about them.

Never answer these for the customer, and never skip an entry because its default
looks harmless. Ask, then record the answer.

## 6. Tearing one down

**On GKE it is simpler:** set `deletion_protection = false` in `terraform.tfvars`
and `terraform apply` it (the destroy reads it from state), empty the storage
buckets (`create_*_persistence_bucket` buckets are not force-destroyed), delete
the spaces in Marshal, then run one `terraform destroy`. It deletes the release
and its namespace first, waits for GKE to release the load balancer's forwarding
rules, and only then removes the cluster, subnet and static IP; expect about 15
minutes. It prints `Warning: Helm uninstall returned an information message ...
marshal-app-secrets kept due to the resource policy`; that is expected. If it stops
on `resourceInUseByAnotherResource`, delete the leftover `k8s2-*` / `gkegw1-*`
forwarding rules and run it again (the README's "Tearing down" has the commands).
The rest of this section is the AWS procedure.

`terraform destroy` on its own does not do it, and the order is not optional.
Get it wrong and the destroy **deadlocks with no error message at all**, leaving
the cluster and the database up and billing.

If they reached the cluster through a CIDR-locked public endpoint, **check it is
still open before you start**. The whole teardown runs terraform and `kubectl`
against the API, and step 2 is the first thing that fails if it is private and
you are outside the VPC.

```bash
# 1. Turn off BOTH database guardrails, in terraform.tfvars:
rds_deletion_protection = false
rds_skip_final_snapshot = true        # leave this out to KEEP a final snapshot

# 2. Apply them. Setting them is not enough on its own: `terraform destroy`
#    reads both values out of STATE, not out of your tfvars, so a flag that has
#    never been through an apply has no effect and you get the snapshot anyway.
terraform apply

# 3. NOW delete the workload, and not before. This takes the Ingress and its
#    finalizer away before terraform can revoke the load balancer controller's
#    IAM policy, which is what otherwise deadlocks the destroy, and it lets the
#    EBS CSI driver delete the PVC volumes while it still has permission to.
# The chart owns two: the release namespace and "<release>-spaces", where
#    session pods live. Deleting only the first leaves the second behind, which
#    does not matter when step 4 destroys the cluster, and does matter on the
#    reuse path (deploy_cluster = false) where the cluster outlives the destroy.
kubectl delete namespace marshal marshal-spaces   # about a minute; EBS volumes go too

# 4. Then destroy.
terraform destroy
```

**Do not move step 3 to the front.** Terraform owns the Helm release, so once
the namespace is gone the apply in step 2 sees the release as deleted and
**reinstalls the entire product**. Measured on a real teardown: `Plan: 5 to add,
1 to change`, which put back the load balancer, three target groups, two
controller-created security groups and the Redis volume roughly two minutes
before the destroy ran. Flags first, apply, then the namespace.

Step 2 is normally a quick in-place database change. On a cluster whose install
failed partway it can also replace a tainted addon, so read the plan instead of
assuming.

**What outlives the destroy**, because Terraform never owned any of it:

- **A final RDS snapshot**, `<cluster_name>-postgres-final`, unless you skipped
  it in step 1. Keep it if the data matters. It also blocks a rebuild under the
  same cluster name, because the snapshot name collides.
- **EBS volumes from PersistentVolumeClaims**, if you skipped step 3.
- **The load balancer, its target groups, and any security group the controller
  created**, if the controller lost its IAM policy before it finished its own
  cleanup. Step 3 prevents this as well.

Subnet tags your subnets already carried are **not** in that list and are not at
risk: the installer skips any tag that was already there, so a destroy leaves it
alone. `terraform output subnet_tags_left_as_yours` lists them, but run it
**before** step 4: once the destroy has finished the state is empty and the same
command prints `Warning: No outputs found` and still exits 0.

Find anything that did survive. **Every one of these is filtered by
`<cluster_name>`, and that matters**: if they have more than one Marshal install
in the account, an unfiltered search returns the other one's resources too, and
the next block deletes whatever the search returned. Target group names differ
only by a random suffix, so you cannot tell them apart by eye.

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

Then remove what they return, in this order, because a security group cannot go
while a target group still references it. **Read each id back against the
cluster name before you delete it.** These four commands are irreversible and
they do not check whose resource it is:

```bash
aws elbv2 delete-target-group --target-group-arn <arn>
aws ec2 delete-security-group --group-id <id>
aws ec2 delete-volume --volume-id <id>
aws rds delete-db-snapshot --db-snapshot-identifier <name>
```

## Warnings that are not problems

- **`ipv6_association_id is deprecated` / `ipv6_cidr_block is deprecated`,
  blamed on `cluster_private_access.tf`.** May appear on a plan or an apply, and
  may not: one live run saw three per plan and apply and none on the destroy,
  another on the same provider version saw none at all. Nothing on the line it
  names reads an IPv6 attribute: the warning comes from the AWS provider's own
  `aws_vpc` data source, and the line number is just where that data source is
  referenced. Harmless either way, nothing to change, and do not let anyone
  edit a `.tf` file over it.
- **`RESTARTS 1` on an api pod right after a fresh install.** The container
  exits once during startup and recovers by itself. Seen on clean installs that
  are otherwise perfect, with every pod `Running` and the licence `LICENSED`.
  Tracked in marshal#1466. If it restarts more than once, or never reaches
  `Running`, that is a different problem: read the log with `--previous`.

## When something fails

- **`ExpiredTokenException` (AWS) or `invalid_grant` / a 401 from the Google
  providers (GKE) partway through an apply.** The credentials expired, not the
  installer. Refresh them (a self-refreshing profile on AWS, a new
  `GOOGLE_OAUTH_ACCESS_TOKEN` on GKE), then run `terraform plan` and read it
  before applying: a half-created cluster is replaced, not resumed (section 4).
- **GKE: the URL times out or returns 502 for the first 5 to 15 minutes while all
  pods are healthy.** The load balancer is still being programmed. Wait, watching
  `kubectl get ingress -n marshal -w`; nothing needs fixing.
- **`marshal spaces new` says `a manifest is required to create a space`.** A new
  install has no manifests yet. See "Make the first space possible" in section 5.
- **A stopped space comes back empty.** Space Storage is not connected (or the
  space is on a size without a persistent disk). Connect the bucket in *Settings
  > Space Storage*; spaces stopped before that are not recoverable.
- **Pods in `ImagePullBackOff`.** The image host and the pull credential
  disagree, or the token is not valid. Compare the image in
  `kubectl describe pod` with the registry in their configuration.
- **The Ingress never gets an address.** On AWS, the load balancer controller is
  missing, or the subnet tags are. Check the controller exists before anything
  else.
- **`terraform plan` fails inside `provider "helm"`.** The pull token is wrong
  or empty. The provider signs in while it configures itself, so this happens
  before any resource is read and the error names the provider rather than the
  token.
- **The load balancer answers 502 while pods are healthy.** A health check is
  pointing at a path that returns 404. Compare the target group's health check
  path with what the service actually serves.
- **An EKS addon is `CREATE_FAILED` and the apply exits 1.** Read the message: if it
  names a webhook with `no endpoints available`, the addon raced the AWS Load Balancer
  Controller's Service webhook. A plain `terraform apply` again fixes it, and the
  warning Terraform prints about purging the addon's configuration is harmless here,
  because the addon never finished being created and carries no configuration to lose.
- **`terraform destroy` fails on the database.** Deletion protection is on by
  design. Set `rds_deletion_protection = false`, apply that, then destroy.
  Doing it in the other order tears down everything else first and then stops.
- **`Kubernetes cluster unreachable`, and no apply can fix it.** You are outside
  the VPC and the endpoint is private, so the Helm and Kubernetes providers
  cannot configure, and that happens before terraform reads a single resource.
  Every plan, apply and destroy exits 1. Terraform cannot dig you out, because
  the change that would restore access is behind the connection it cannot make.
  Re-open it with the AWS API directly, which does not go through the endpoint:

  ```bash
  aws eks update-cluster-config --name <cluster_name> --region <region> \
    --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=<your.ip>/32
  aws eks describe-update --name <cluster_name> --region <region> --update-id <id>
  ```

  Wait for the update to report `Successful`, then carry on. Set
  `cluster_endpoint_public_access = true` with the same CIDR in their tfvars too,
  or the next apply will try to close it again. This is the only step in this
  skill that goes around terraform, and it exists because the alternative is an
  install nobody can remove.
- **`terraform destroy` prints `Still destroying...` forever and never errors.**
  It is waiting on `helm_release.marshal`, which is waiting on the Ingress's
  `ingress.k8s.aws/resources` finalizer, which is waiting on a load balancer
  controller that no longer has the IAM policy terraform just revoked. Confirm
  with `helm list -n marshal --all` (`uninstalling`) and a 403 in
  `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`.
  It will not resolve on its own. To get out:
  1. `Ctrl-C` is not enough. Graceful shutdown waits for the in-flight call, and
     the in-flight call is the one that never returns. Kill the terraform process.
  2. That strands a lock. Read the ID out of the `.tflock` object next to your
     state and `terraform force-unlock <id>`.
  3. `terraform apply`. **It will exit 1** on `"marshal" has no deployed
     releases`, because the helm provider will not touch a release stuck in
     `uninstalling`. Let it. It restores the IAM policy before it fails, and that
     is the part you need.
  4. `kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system`.
     Without this the controller is in exponential backoff and can sit silent for
     fifteen minutes or more, with nothing in its log to say so. After the restart
     the finalizer clears in seconds.
  5. Then start section 6 again, from step 1.

  Installers from `v0.23.0-r3` onward do not have this failure: the controller's
  policy attachment is now destroyed after the release rather than beside it.

Full list: https://docs.marshal.codes/troubleshooting

When something is wrong and you cannot see why, collect the evidence before
anything is restarted: `scripts/support-bundle.sh --since 6h --space <name>` writes
the cluster state and the supervisor, agent and control-plane logs into one
redacted folder and `.tar.gz` (add `--all-spaces` for every space). It only reads.
Hand that to Marshal support.

## Rules

- **Never disable a guardrail to make an apply pass.** The preconditions, the
  deletion protection and the final snapshot are all deliberate. If one blocks
  the install, the input is wrong, not the check.
- **Never print or commit their secrets.** The licence token, registry token
  and database password all live in files that stay untracked.
- **Stop and ask when an answer would change what gets created**, especially
  anything that replaces a node group, a database or a network.
- Upgrading is `chart_version` plus `terraform apply`, after you have worked through
  every new capability in `capabilities.yaml` (see "Upgrading an existing install"), and rolling back is
  `helm rollback marshal -n marshal`.
