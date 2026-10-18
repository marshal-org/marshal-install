# Marshal self-hosted installer

Terraform that installs **Marshal** into a Kubernetes cluster you control.

```
modules/marshal-install/   # the shared install logic: namespace, secrets, the umbrella Helm chart
single-node-k3s/           # one node running k3s, optional in-cluster Postgres and Redis
gcp-gke/                   # GKE, reuse an existing cluster or provision one, with Cloud SQL
aws-eks/                   # EKS, reuse an existing cluster or provision one, with RDS
examples/                  # per-flavor *.tfvars.example: copy, fill in about six values, apply
argocd/                    # GitOps path: an ArgoCD Application for the same chart
```

## Guided install

If you use [Claude Code](https://claude.com/claude-code), this repository ships a skill that
walks you through the whole install: it checks your cloud environment first, works through the
configuration with you, runs the apply, and explains what a failure means instead of leaving
you with a stack trace.

```
cd marshal-install
claude            # then: /install-marshal
```

It never changes anything without telling you first, and it will not disable a safety check to
make an apply pass. Everything it does is in this repository and on the pages below, so you can
also just follow those by hand.

## Start here

**The install guides live at [docs.marshal.codes](https://docs.marshal.codes/installing/prerequisites).**
Read the prerequisites page first, then your cloud's page. This repository holds
the code those guides tell you to run, and nothing else.

- Prerequisites, for every cloud: https://docs.marshal.codes/installing/prerequisites
- AWS (EKS): https://docs.marshal.codes/installing/eks
- GCP (GKE): https://docs.marshal.codes/installing/gke
- Single node (k3s): https://docs.marshal.codes/installing/single-node-k3s
- ArgoCD instead of Terraform: https://docs.marshal.codes/installing/argocd
- Configuration reference: https://docs.marshal.codes/configuration

## Check your environment first

Before you write any configuration, run the preflight. It is read-only, it
takes a few seconds, and it reports everything wrong in one pass instead of
failing one problem at a time during `terraform apply`:

```bash
scripts/preflight-aws.sh --region eu-west-1 \
  --vpc-id vpc-0123456789abcdef0 \
  --private-subnets subnet-aaa,subnet-bbb \
  --ingress-host marshal.acme.com
```

It checks the things that actually derail an install: whether those subnets are
really private, whether they have a route out to pull images, whether they
carry the load balancer tags, how many free IP addresses they have (every pod
takes one), AZ coverage, your on-demand vCPU quota, whether the pinned
Kubernetes and Postgres versions exist in your region, and whether your DNS
zone is in Route53. Pass `--help` for every option.

## What you need before you start

Four values, issued once per deployment by your Marshal contact: `deployment_id`,
`installation_jwt`, `registry_pull_token`, and the `chart_version` to install.
Prove they work before running Terraform:

```bash
helm registry login registry.marshal.codes --username <deployment_id> --password '<registry_pull_token>'
helm pull oci://registry.marshal.codes/marshal-charts/marshal --version <chart_version>
```

## Your own configuration

Keep your `terraform.tfvars` and your Terraform state **in your own
repository and your own backend**. They contain your licence token, your
registry token and your database password. Copy the matching
`examples/*.tfvars.example` as a starting point.

## Install, and how to take updates

Clone this repository **at a tag** and treat the clone as disposable. Your own
files are untracked here (`terraform.tfvars`, `*_override.tf` and state are
all gitignored), so switching versions never touches them and never asks you
to merge anything.

```bash
git clone --branch v0.22.0-r3 https://github.com/marshal-org/marshal-install.git
cd marshal-install/aws-eks                      # or gcp-gke, or single-node-k3s

cp ../examples/aws-eks.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars                       # the four values from your onboarding, plus your hostname

terraform init
terraform apply
```

For remote state, add your own `backend_override.tf` with your backend block.
It is gitignored, so it survives every version switch:

```hcl
terraform {
  backend "s3" {
    bucket = "acme-terraform-state"
    key    = "marshal/terraform.tfstate"
    region = "eu-west-1"
  }
}
```

Prefer to keep your variables in your own repository instead of in this clone?
Point Terraform at them: `terraform apply -var-file=/path/to/your/prod.tfvars`.

### Upgrading

```bash
git fetch --tags
git checkout v<new-version>      # your tfvars, your override and your state stay put
terraform init -upgrade
terraform plan                   # review, then apply
```

Each tag is one release of this installer, published for a specific Marshal
chart version, and `git diff v<old> v<new>` shows you exactly what changed
before you apply it. Read the chart's release notes for the version you are
moving to, since an upgrade also runs database migrations.

If you modified files in this repository, you are on a fork: rebase it onto
the new tag rather than merging. Most changes you might want are already
variables, so check `variables.tf` first and tell us if something is missing.

### Referencing a flavour as a Terraform module

Not supported today. Each flavour configures its own `aws`/`google`,
`kubernetes` and `helm` providers from the cluster it is pointed at, which is
what makes a one-command install possible, and a module consumed with
`source = \"git::...\"` cannot cleanly inherit that. Clone at a tag instead.

## This repository is read-only

It is generated from Marshal's internal installer repository on each release,
with a squashed history, so pull requests and issues here are not watched.
For help with an install, use your shared support channel with Marshal, or
mail support@marshal.codes.

## Licence

Apache 2.0, see [`LICENSE`](LICENSE). That covers this installer only, not the
Marshal product it installs. See [`NOTICE`](NOTICE).

---

Generated for Marshal chart version `0.22.0`, published as `v0.22.0-r3`.
