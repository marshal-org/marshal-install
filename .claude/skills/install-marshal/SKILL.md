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
| `on-demand vCPU quota` low | A quota increase can take days. Start it immediately. |

A clean preflight proves the environment, not their permissions. Say so.

## 3. Fill in the configuration

```bash
cd aws-eks           # or gcp-gke, or single-node-k3s
cp ../examples/aws-eks.tfvars.example terraform.tfvars
```

Work through it **with** them. Confirm the chart version against their
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

**When the cluster endpoint is private**, which is the default on the
provisioning path, the second half of the apply has to run from inside the
network. The installer creates a bastion with no public IP and no inbound
ports, reached through AWS Systems Manager. The two-phase sequence is on
https://docs.marshal.codes/installing/eks under "Installing when the endpoint
is private". Offer the alternatives too: their existing VPN or jump host with
`create_bastion = false`, or a public endpoint locked to their own address
ranges, which is simplest and the weakest of the three.

## 5. Verify, and hand over

```bash
terraform output next_steps
kubectl get pods -n marshal
kubectl logs -n marshal -l app.kubernetes.io/component=api | grep -i license
```

Expect every pod `Running` and a line reporting the licence state as
`LICENSED`. Then point them at their hostname. The certificate is a self-signed
placeholder until they supply a real one, so a browser warning at this stage is
expected, not a fault: see the TLS section of their cloud's page.

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
- **`terraform destroy` fails on the database.** Deletion protection is on by
  design. Set `rds_deletion_protection = false`, apply that, then destroy.
  Doing it in the other order tears down everything else first and then stops.

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
