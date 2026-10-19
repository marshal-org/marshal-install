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
| No route in | `cluster_endpoint_public_access = true` and `cluster_endpoint_public_access_cidrs` holding their own address | One `terraform apply`, then set it back to private and apply once more |
| Policy forbids a public endpoint, even briefly | `create_bastion = true` | The **whole** install runs on the bastion |

Prefer the first, then the second. Both run on one machine, in one pass, with no
files moved between hosts.

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
| `kubernetes.io/role/internal-elb absent` | Either let `tag_existing_subnets` add it, or they add it. Without it the Ingress never gets an address **and emits no events**, which is slow to diagnose. |
| `only N free IPs` | Every pod takes a real subnet IP, so this caps concurrent sessions. Under about 60, ask for a bigger subnet now. |
| `AZ coverage: 1 AZ` | EKS will not create a cluster. Get a second subnet. |
| `on-demand vCPU quota` low | A quota increase can take days. Start it immediately. The default shape needs **12 vCPU** (one `m5.xlarge` node plus one `m5.2xlarge` control-plane node). 32 is comfortable; 16 gets tight as soon as a second node scales up. |

A clean preflight proves the environment, not their permissions. Say so.

## 3. Fill in the configuration

```bash
cd aws-eks           # or gcp-gke, or single-node-k3s
cp ../examples/aws-eks.tfvars.example terraform.tfvars
```

**Agree `cluster_name` with them before you write it.** Do not invent one, and
do not reach for something like `marshal-test`: it is the name of real
infrastructure in their account, it is stamped into node groups, IAM roles,
security groups and the database's final snapshot, and changing it later means
replacing all of them. Ask what their naming convention is. If this really is a
throwaway, have them say so, because that changes the RDS answers in step 3
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
(gitignored, so it survives a version switch) and `terraform init
-migrate-state`. The state holds their licence token, registry token and
database password, so versioning, encryption and a public access block are not
optional.

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
Run it in the wrong order and the destroy **deadlocks with no error message at
all**, leaving the cluster and the database up and billing.

```bash
# 1. Delete the workload FIRST. This is not tidiness. It removes the Ingress and
#    its finalizer before terraform can revoke the load balancer controller's
#    IAM policy, which is what otherwise deadlocks the destroy. It also lets the
#    EBS CSI driver delete the PVC volumes while it still has permission to.
kubectl delete namespace marshal      # about 15s; the EBS volumes go with it

# 2. Turn off BOTH database guardrails, in terraform.tfvars:
rds_deletion_protection = false
rds_skip_final_snapshot = true        # leave this out to KEEP a final snapshot

# 3. Apply them. Setting them is not enough on its own: `terraform destroy`
#    reads both values out of STATE, not out of your tfvars, so a flag that has
#    never been through an apply has no effect and you get the snapshot anyway.
terraform apply

# 4. Now it can run.
terraform destroy
```

Step 3 is normally a quick in-place database change. On a cluster whose install
failed partway it can also replace a tainted addon, so read the plan instead of
assuming.

**What outlives the destroy**, because Terraform never owned any of it:

- **A final RDS snapshot**, `<cluster_name>-postgres-final`, unless you skipped it
  in step 2. Keep it if the data matters. It also blocks a rebuild under the same
  cluster name, because the snapshot name collides.
- **EBS volumes from PersistentVolumeClaims**, if you skipped step 1.
- **The load balancer, its target groups, and any security group the controller
  created**, if the controller lost its IAM policy before it finished its own
  cleanup. Step 1 prevents this as well.

Find all of it:

```bash
aws ec2 describe-volumes --region <region> \
  --filters Name=tag:KubernetesCluster,Values=<cluster_name> \
  --query 'Volumes[].VolumeId' --output text
aws elbv2 describe-target-groups --region <region> \
  --query 'TargetGroups[?starts_with(TargetGroupName, `k8s-marshal`)].TargetGroupArn' --output text
aws ec2 describe-security-groups --region <region> \
  --filters Name=tag:elbv2.k8s.aws/cluster,Values=<cluster_name> \
  --query 'SecurityGroups[].GroupId' --output text
aws rds describe-db-snapshots --region <region> --snapshot-type manual \
  --query 'DBSnapshots[].DBSnapshotIdentifier' --output text
```

Then remove whatever they return, in this order, because a security group cannot
go while a target group still references it:

```bash
aws elbv2 delete-target-group --target-group-arn <arn>
aws ec2 delete-security-group --group-id <id>
aws ec2 delete-volume --volume-id <id>
aws rds delete-db-snapshot --db-snapshot-identifier <name>
```

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
