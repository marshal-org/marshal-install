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

## 0. What they need before anything

Four values, issued once per deployment by their Marshal contact:
`deployment_id`, `installation_jwt`, `registry_pull_token`, and the
`chart_version` to install. Prove them first, because nothing below works
without them:

```bash
helm registry login registry.marshal.codes --username <deployment_id> --password '<registry_pull_token>'
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

**How will they reach the cluster?** Only when the installer creates it, because
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

On AWS, run the preflight. It is read-only, takes seconds, and reports every
problem in one pass instead of failing one at a time during an apply:

```bash
scripts/preflight-aws.sh --region <region> \
  --ingress-host <hostname> \
  --deployment-id <dep> --pull-token '<mrpt_...>' --chart-version <ver>
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
| `on-demand vCPU quota` low | A quota increase can take days. Start it immediately. The default shape needs **12 vCPU** (one `m5.xlarge` node plus one `m5.2xlarge` control-plane node). 32 is comfortable; 16 gets tight as soon as a second node scales up. |

A clean preflight proves the environment, not their permissions. Say so.

## 3. Fill in the configuration

```bash
cd aws-eks           # or gcp-gke, or single-node-k3s
cp ../examples/aws-eks.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars   # it will hold the licence JWT and the pull token
```

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

## 4. Apply

**Put the state in S3 before the first apply.** It is their state either way, but
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

On the bastion path, the bastion runs the whole install, so give it the
credentials for that job and delete it when the install is done. Do not run half
the install on one machine and half on another: the two share nothing but the
state, and the hand-off is where installs go wrong.

## 5. Verify, and hand over

```bash
terraform output next_steps

# kubectl has no cluster yet. Without this it talks to localhost:8080 and the
# whole verify step looks like a broken install.
aws eks update-kubeconfig --name <cluster_name> --region <region>

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

Expect every pod `Running` and a line reporting the licence state as
`LICENSED`. Then point them at their hostname. The certificate is a self-signed
placeholder until they supply a real one, so a browser warning at this stage is
expected, not a fault: see the TLS section of their cloud's page.

## 6. Tearing one down

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
  another on the same provider version saw none at all. Either way it is
  harmless. Nothing on the line it names reads an IPv6 attribute: the
  warning comes from the AWS provider's own `aws_vpc` data source, and the line
  number is just where that data source is referenced. Harmless, nothing to
  change, and do not let anyone edit a `.tf` file over it.
- **`RESTARTS 1` on an api pod right after a fresh install.** The container
  exits once during startup and recovers by itself. Seen on clean installs that
  are otherwise perfect, with every pod `Running` and the licence `LICENSED`.
  Tracked in marshal#1466. If it restarts more than once, or never reaches
  `Running`, that is a different problem: read the log with `--previous`.

## When something fails

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

## Rules

- **Never disable a guardrail to make an apply pass.** The preconditions, the
  deletion protection and the final snapshot are all deliberate. If one blocks
  the install, the input is wrong, not the check.
- **Never print or commit their secrets.** The licence token, registry token
  and database password all live in files that stay untracked.
- **Stop and ask when an answer would change what gets created**, especially
  anything that replaces a node group, a database or a network.
- Upgrading is `chart_version` plus `terraform apply`, and rolling back is
  `helm rollback marshal -n marshal`.
