---
name: preflight-install
description: Verify a customer's AWS or GCP environment against what the Marshal installer needs, BEFORE the install session. Runs the read-only preflight script, interprets every failure and warning with its remediation, checks the things the script cannot see, and produces a short report to send the customer's platform team. Use before any customer install or upgrade, when a customer sends their VPC and subnet details, or when the operator says "check their environment", "are they ready to install", "preflight".
---

# Preflight a customer install

An install session fails on environment problems far more often than on the
installer. Every one of them is cheaper to find a week early, by email, than
live on a call with their platform team watching.

The rule: **run this before you agree an install date**, and again on the day,
because their environment changes under you.

## 1. Collect the inputs

Ask for what you do not have. Nothing except the region is required, and a
partial run is still useful: unknown values are reported as skipped, not
guessed.

| Input | Why it matters |
|---|---|
| region | An ALB can only use an ACM certificate from its own region, and the pinned EKS and Postgres versions are not offered everywhere |
| vpc id | DNS attributes, and whether the subnets really belong to it |
| private subnet ids | AZ coverage, free IP addresses, egress, the ALB role tag |
| public subnet ids | Only if they want an internet-facing load balancer |
| ingress host | Whether the DNS zone is in Route53, which decides the certificate flow |
| acm arn | If they already have a certificate: region, status, domain |
| cluster name | **Only when reusing a cluster.** Pass it otherwise and you will be told it does not exist, which is correct and harmless |
| the four onboarding values | Proves the credentials before anyone writes tfvars |

## 2. Run it

```bash
scripts/preflight-aws.sh --region <r> --vpc-id <v> \
  --private-subnets <a>,<b> [--public-subnets <c>,<d>] \
  [--ingress-host <host>] [--acm-arn <arn>] [--cluster-name <name>] \
  [--deployment-id <dep> --pull-token <mrpt> --chart-version <ver>]
```

Read-only throughout: every call is a describe, get or list. Exit 1 if anything
FAILED, 0 if everything passed or only warned. Run it with **their** read-only
credentials when they give you access, otherwise send them the script and ask
for the output.

## 3. Interpret, do not just forward

The script states facts. Deciding what they mean is this step's job.

| Result | What it actually means |
|---|---|
| `egress ... routes via an internet gateway, so this subnet is PUBLIC` | They handed you public subnets while thinking they were private. Nodes would get public IPs and the "private cluster" posture is gone. Go back and ask for the private tier. This is the single most common mix-up. |
| `no 0.0.0.0/0 route` | The install dies on image pulls, because nodes cannot reach `registry.marshal.codes`. They need NAT, a transit gateway path, or a proxy. Not negotiable. |
| `kubernetes.io/role/internal-elb absent` | Either let `tag_existing_subnets` add it, or have them add it. If neither happens the Ingress never gets an address **and emits no events at all**, which costs hours to diagnose live. |
| `only N free IPs` | The VPC CNI gives every pod a real subnet IP, so this is a ceiling on concurrent sessions, not a detail. Under 60 free addresses, ask for a bigger subnet before you start. |
| `AZ coverage: 1 AZ` | EKS will not create a cluster. Get a second subnet. |
| `enableDnsSupport` / `enableDnsHostnames` false | EKS requires both. They must flip them on the VPC; it is not something the installer can do. |
| `on-demand vCPU quota` tight or failing | A quota increase takes AWS days sometimes. Start it immediately, do not discover it on install day. The default shape needs **12 vCPU**: one `m5.xlarge` node plus one `m5.2xlarge` control-plane node. |
| `EKS <ver> available` fails | Change `kubernetes_version`. The pin is deliberate, but it is not available in every region. |
| `RDS postgres <ver>` fails | Change `rds_engine_version`, staying on 16.x, which the chart requires. |
| `ssm vpc endpoints missing` | Only a problem if the subnet also has no egress. If both are missing, the bastion we create is unreachable and they must tell you how they reach a private EKS endpoint instead. |
| `route53 zone` absent | Expect the two-apply certificate flow: first apply comes up on HTTP, they add the validation CNAME, second apply turns HTTPS on. Tell them before the session, not during. |
| `acm certificate PENDING_VALIDATION` | The ALB will serve HTTP only. The certificate has to be ISSUED first. |
| `addon aws-ebs-csi-driver` or `metrics-server` missing | Reuse path only. Without EBS CSI the bundled Redis PVC never binds and the api CrashLoops with a misleading error. Without metrics-server there is no `metrics.k8s.io` at all, so every HPA reads nothing. |
| `oidc provider absent` | Reuse path only. No IRSA, so no object storage and no credential-free registry pulls. |

## 4. Check what the script cannot see

- **Write permissions.** Nothing read-only can prove the apply identity may
  create a cluster, roles and a database. Say so plainly rather than implying
  the preflight clears the apply.
- **Reused cluster, from kubectl** (the script only sees the AWS API):
  ```bash
  kubectl get storageclass            # exactly one default, or PVCs hang Pending
  kubectl get deploy -n kube-system aws-load-balancer-controller
  kubectl auth can-i create namespace # the apply identity's RBAC, via their access entry
  ```
- **Egress from a node**, which is what actually matters for image pulls and
  cannot be tested before a node exists. Check it right after the cluster comes
  up, from a node rather than from a laptop:
  ```bash
  aws ssm send-command --document-name AWS-RunShellScript \
    --targets Key=instanceids,Values=<node-instance-id> \
    --parameters 'commands=["curl -sS -o /dev/null -w %{http_code} https://registry.marshal.codes/v2/"]'
  ```
- **Their own IaC owning the subnets.** If their Terraform manages those
  subnets' tags, `tag_existing_subnets` will fight it on every apply. Ask, and
  set it false if so.

## 5. Report

Give the operator, in this order: the failures with what the customer must do
about each, the warnings worth raising, what you could not check and why, and a
one-line verdict on whether to book the install. Keep the customer-facing part
free of internal detail: they need the action, not our incident history.

## Traps

- **A clean preflight is not a green light.** It proves the environment, not
  the apply. The three unknowns it cannot reach are write permissions, node
  egress and their own IaC.
- **Do not pass `--cluster-name` when Terraform will create the cluster.** The
  "does not exist" line is correct but reads like a failure to someone
  skimming.
- **Re-run on the day.** Subnets get re-tagged, quotas get consumed by other
  teams, and certificates expire between the first run and the session.
- **The script is in the customer-facing export on purpose.** They can run it
  themselves, which is usually faster than getting read-only credentials
  issued to you.
