#!/usr/bin/env bash
# Check an AWS environment against what the aws-eks flavor needs, BEFORE anyone
# writes tfvars or runs terraform.
#
# Why this exists separately from the flavor's own preconditions: those run at
# plan time, need a complete tfvars, and stop at the first failure. This runs
# read-only with a handful of arguments, reports EVERY problem in one pass, and
# is safe to hand to a customer's platform team so they can clear their own
# environment before the install session rather than during it.
#
# It is strictly read-only. Every call is a describe/get/list. It creates
# nothing, changes nothing, and needs no write permission.
#
# Usage (nothing is required except --region; pass what you know):
#   scripts/preflight-aws.sh --region eu-west-1 \
#     --vpc-id vpc-0123 --private-subnets subnet-a,subnet-b \
#     [--public-subnets subnet-c,subnet-d] \
#     [--cluster-name marshal-poc] [--ingress-host marshal.acme.com] \
#     [--acm-arn arn:aws:acm:...] \
#     [--deployment-id dep_ab12cd --pull-token mrpt_… --chart-version 0.23.0] \
#     [--k8s-version 1.36] [--rds-version 16.14]
#
# Exit code is 1 if anything FAILED, 0 if everything passed or only warned.
set -uo pipefail

REGION="" VPC_ID="" PRIVATE_SUBNETS="" PUBLIC_SUBNETS="" CLUSTER_NAME=""
INGRESS_HOST="" ACM_ARN="" DEPLOYMENT_ID="" PULL_TOKEN="" CHART_VERSION=""
K8S_VERSION="1.36" RDS_VERSION="16.14"

while [ $# -gt 0 ]; do
  case "$1" in
    --region)          REGION="${2:-}";          shift 2 ;;
    --vpc-id)          VPC_ID="${2:-}";          shift 2 ;;
    --private-subnets) PRIVATE_SUBNETS="${2:-}"; shift 2 ;;
    --public-subnets)  PUBLIC_SUBNETS="${2:-}";  shift 2 ;;
    --cluster-name)    CLUSTER_NAME="${2:-}";    shift 2 ;;
    --ingress-host)    INGRESS_HOST="${2:-}";    shift 2 ;;
    --acm-arn)         ACM_ARN="${2:-}";         shift 2 ;;
    --deployment-id)   DEPLOYMENT_ID="${2:-}";   shift 2 ;;
    --pull-token)      PULL_TOKEN="${2:-}";      shift 2 ;;
    --chart-version)   CHART_VERSION="${2:-}";   shift 2 ;;
    --k8s-version)     K8S_VERSION="${2:-}";     shift 2 ;;
    --rds-version)     RDS_VERSION="${2:-}";     shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REGION" ] || { echo "--region is required" >&2; exit 2; }

PASS=0 WARN=0 FAIL=0
pass() { printf '  \033[32mPASS\033[0m  %-34s %s\n' "$1" "${2:-}"; PASS=$((PASS+1)); }
warn() { printf '  \033[33mWARN\033[0m  %-34s %s\n' "$1" "${2:-}"; WARN=$((WARN+1)); }
fail() { printf '  \033[31mFAIL\033[0m  %-34s %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
skip() { printf '  ----  %-34s %s\n' "$1" "${2:-}"; }
head2() { printf '\n%s\n' "$1"; }

aws_q() { aws --region "$REGION" "$@" 2>&1; }

# ── Identity ────────────────────────────────────────────────────────────────
head2 "Identity"
if ident="$(aws_q sts get-caller-identity --query '[Account,Arn]' --output text)"; then
  pass "aws credentials" "$(printf '%s' "$ident" | tr '\t' ' ')"
else
  fail "aws credentials" "$ident"
  echo; echo "Nothing else can be checked without credentials." >&2; exit 1
fi

# Write permissions cannot be proven without writing. Say so rather than
# implying this script clears the apply.
skip "write permissions" "not checkable read-only; the apply is the real test"

# ── Marshal onboarding credentials ──────────────────────────────────────────
head2 "Marshal credentials"
if [ -n "$DEPLOYMENT_ID" ] && [ -n "$PULL_TOKEN" ] && [ -n "$CHART_VERSION" ]; then
  if ! command -v helm >/dev/null 2>&1; then
    warn "chart pull" "helm not installed, skipped"
  else
    tmp="$(mktemp -d)"
    if out="$(helm registry login registry.marshal.codes --username "$DEPLOYMENT_ID" --password "$PULL_TOKEN" 2>&1)"; then
      if out="$(helm pull "oci://registry.marshal.codes/marshal-charts/marshal" --version "$CHART_VERSION" -d "$tmp" 2>&1)"; then
        pass "chart pull" "marshal $CHART_VERSION"
      else
        fail "chart pull" "login ok, pull failed: $(printf '%s' "$out" | tail -1)"
      fi
    else
      fail "registry login" "$(printf '%s' "$out" | tail -1)"
    fi
    rm -rf "$tmp"
  fi
else
  skip "chart pull" "pass --deployment-id/--pull-token/--chart-version to check"
fi

# ── Region capabilities ─────────────────────────────────────────────────────
head2 "Region $REGION"

if v="$(aws_q eks describe-addon-versions --kubernetes-version "$K8S_VERSION" --query 'addons[0].addonName' --output text)" \
   && [ "$v" != "None" ] && [ -n "$v" ]; then
  pass "EKS $K8S_VERSION available" ""
else
  fail "EKS $K8S_VERSION available" "pick another kubernetes_version; this one is not offered here"
fi

if aws_q rds describe-db-engine-versions --engine postgres --engine-version "$RDS_VERSION" \
     --query 'DBEngineVersions[0].EngineVersion' --output text | grep -q "^$RDS_VERSION"; then
  pass "RDS postgres $RDS_VERSION" ""
else
  fail "RDS postgres $RDS_VERSION" "not available in $REGION; set rds_engine_version to one that is"
fi

# L-1216C47A is "Running On-Demand Standard (A,C,D,H,I,M,R,T,Z) instances",
# counted in vCPUs. The control plane alone wants 8 (one m5.2xlarge).
quota="$(aws_q service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
          --query 'Quota.Value' --output text)"
case "$quota" in
  ''|*[!0-9.]*) warn "on-demand vCPU quota" "could not read it: ${quota:-no value}" ;;
  *)
    q=${quota%.*}
    if [ "$q" -ge 32 ]; then pass "on-demand vCPU quota" "$q vCPU limit (this is the LIMIT, not free capacity: subtract whatever the account already runs)"
    elif [ "$q" -ge 16 ]; then warn "on-demand vCPU quota" "$q vCPU, tight: 8 for the control plane plus sessions"
    else fail "on-demand vCPU quota" "$q vCPU is not enough for one m5.2xlarge plus a session node"
    fi ;;
esac

# ── VPC ─────────────────────────────────────────────────────────────────────
if [ -z "$VPC_ID" ]; then
  head2 "VPC"
  skip "vpc" "pass --vpc-id to check an existing VPC (skip if Terraform will create one)"
else
  head2 "VPC $VPC_ID"
  if cidr="$(aws_q ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text)" \
     && [ "$cidr" != "None" ]; then
    pass "vpc exists" "$cidr"
    # The --attribute value is lower-camel while the response key is upper-camel,
    # so both spellings are written out. ${attr^} would be neater and is bash 4
    # only: this has to run on a macOS laptop's bash 3.2 too.
    for pair in "enableDnsSupport EnableDnsSupport" "enableDnsHostnames EnableDnsHostnames"; do
      attr="${pair% *}"; key="${pair#* }"
      val="$(aws_q ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute "$attr" \
              --query "$key.Value" --output text 2>/dev/null)"
      if [ "$val" = "True" ]; then pass "$attr" ""; else fail "$attr" "EKS requires this to be true"; fi
    done
  else
    fail "vpc exists" "$cidr"
  fi
fi

# ── Subnets ─────────────────────────────────────────────────────────────────
check_subnets() {
  label="$1"; ids="$2"; want_tag="$3"
  [ -n "$ids" ] || { skip "$label subnets" "none given"; return; }
  list="$(printf '%s' "$ids" | tr ',' ' ')"
  azs=""
  for s in $list; do
    row="$(aws_q ec2 describe-subnets --subnet-ids "$s" \
            --query 'Subnets[0].[AvailabilityZone,AvailableIpAddressCount,VpcId,CidrBlock]' --output text)"
    case "$row" in
      *error*|*Error*|"") fail "$label $s" "$(printf '%s' "$row" | tail -1)"; continue ;;
    esac
    az="$(printf '%s' "$row" | awk '{print $1}')"
    free="$(printf '%s' "$row" | awk '{print $2}')"
    vpc="$(printf '%s' "$row" | awk '{print $3}')"
    cidr="$(printf '%s' "$row" | awk '{print $4}')"

    if [ -n "$VPC_ID" ] && [ "$vpc" != "$VPC_ID" ]; then
      fail "$label $s" "is in $vpc, not $VPC_ID"
      continue
    fi
    azs="$azs $az"

    # The VPC CNI gives every pod a real subnet IP, so free addresses are a
    # capacity limit on sessions, not a detail.
    if [ "$free" -ge 250 ]; then pass "$label $s" "$az  $cidr  $free free IPs"
    elif [ "$free" -ge 60 ]; then warn "$label $s" "$az  $cidr  only $free free IPs; every pod takes one"
    else fail "$label $s" "$az  $cidr  $free free IPs is too few for session pods"
    fi

    # A default route is what lets nodes reach registry.marshal.codes. Its
    # target may be a NAT gateway, a transit gateway or an appliance ENI; any
    # of those is fine, having none is not.
    rt="$(aws_q ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$s" \
           --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId,TransitGatewayId,NetworkInterfaceId]' \
           --output text)"
    [ -n "$rt" ] || rt="$(aws_q ec2 describe-route-tables \
           --filters "Name=vpc-id,Values=${VPC_ID:-$vpc}" "Name=association.main,Values=true" \
           --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId,TransitGatewayId,NetworkInterfaceId]' \
           --output text)"
    target="$(printf '%s' "$rt" | tr '\t' '\n' | grep -v '^None$' | head -1)"
    if [ -z "$target" ]; then
      fail "$label $s egress" "no 0.0.0.0/0 route; nodes cannot reach registry.marshal.codes"
    else
      case "$target" in
        igw-*) [ "$want_tag" = "elb" ] && pass "$label $s egress" "internet gateway (public subnet)" \
                                       || warn "$label $s egress" "routes via an internet gateway, so this subnet is PUBLIC" ;;
        *)     pass "$label $s egress" "$target" ;;
      esac
    fi

    # Missing ALB tags is the silent failure: the Ingress never gets an
    # address and emits no events at all.
    tagk="kubernetes.io/role/$want_tag"
    have="$(aws_q ec2 describe-subnets --subnet-ids "$s" \
             --query "Subnets[0].Tags[?Key=='$tagk'].Value" --output text)"
    if [ -n "$have" ] && [ "$have" != "None" ]; then
      pass "$label $s $tagk" "$have"
    else
      warn "$label $s $tagk" "absent; tag_existing_subnets=true will add it, or add it yourself"
    fi
  done

  n="$(printf '%s' "$azs" | tr ' ' '\n' | grep -c '[a-z]')"
  u="$(printf '%s' "$azs" | tr ' ' '\n' | grep '[a-z]' | sort -u | wc -l | tr -d ' ')"
  if [ "$u" -ge 2 ]; then pass "$label AZ coverage" "$u AZs across $n subnets"
  else fail "$label AZ coverage" "$u AZ; EKS requires subnets in at least two"
  fi
}

head2 "Subnets"
check_subnets "private" "$PRIVATE_SUBNETS" "internal-elb"
[ -n "$PUBLIC_SUBNETS" ] && check_subnets "public" "$PUBLIC_SUBNETS" "elb"

# ── Systems Manager reachability for the bastion ─────────────────────────────
head2 "Bastion access (Systems Manager)"
if [ -z "$VPC_ID" ]; then
  skip "ssm path" "needs --vpc-id"
else
  eps="$(aws_q ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" \
          --query 'VpcEndpoints[].ServiceName' --output text)"
  missing=""
  for svc in ssm ssmmessages ec2messages; do
    printf '%s' "$eps" | grep -q "\.$svc\$\|\.$svc[[:space:]]" || missing="$missing $svc"
  done
  if [ -z "$missing" ]; then
    pass "ssm vpc endpoints" "ssm, ssmmessages, ec2messages present"
  else
    warn "ssm vpc endpoints" "missing:$missing. Fine IF the subnet has egress, since SSM is then reached over the internet"
  fi
fi

# ── DNS and TLS ─────────────────────────────────────────────────────────────
head2 "DNS and TLS"
if [ -n "$INGRESS_HOST" ]; then
  zone="$INGRESS_HOST"
  found=""
  while [ -n "$zone" ] && [ "$zone" != "${zone#*.}" ]; do
    id="$(aws route53 list-hosted-zones-by-name --dns-name "$zone" \
           --query "HostedZones[?Name=='${zone}.'].Id" --output text 2>/dev/null)"
    if [ -n "$id" ] && [ "$id" != "None" ]; then found="$zone ${id##*/}"; break; fi
    zone="${zone#*.}"
  done
  if [ -n "$found" ]; then
    pass "route53 zone" "$found  (certificate can validate automatically)"
  else
    warn "route53 zone" "no hosted zone for $INGRESS_HOST in this account. Only matters if you set acm_request_certificate=true, which then needs the two-apply flow: apply, add the printed CNAME yourself, apply again. With the default tls_mode=self_signed this does not apply and the install is one apply"
  fi
else
  skip "route53 zone" "pass --ingress-host to check"
fi

if [ -n "$ACM_ARN" ]; then
  case "$ACM_ARN" in
    arn:aws*:acm:"$REGION":*) ;;
    *) fail "acm certificate region" "$ACM_ARN is not in $REGION; an ALB can only use a certificate from its own region" ;;
  esac
  st="$(aws_q acm describe-certificate --certificate-arn "$ACM_ARN" \
         --query 'Certificate.[Status,DomainName]' --output text)"
  case "$st" in
    ISSUED*) pass "acm certificate" "$(printf '%s' "$st" | tr '\t' ' ')" ;;
    PENDING_VALIDATION*) warn "acm certificate" "PENDING_VALIDATION; the ALB will not serve HTTPS until it is ISSUED" ;;
    *) fail "acm certificate" "$(printf '%s' "$st" | tail -1)" ;;
  esac
else
  skip "acm certificate" "pass --acm-arn to check one you already have"
fi

# ── Existing cluster, only when reusing one ─────────────────────────────────
head2 "Existing cluster"
if [ -z "$CLUSTER_NAME" ]; then
  skip "cluster" "pass --cluster-name only if you are REUSING a cluster"
else
  info="$(aws_q eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.[version,status,identity.oidc.issuer]' --output text)"
  case "$info" in
    *ResourceNotFound*|*error*) skip "cluster $CLUSTER_NAME" "does not exist yet, so Terraform will create it" ;;
    *)
      pass "cluster $CLUSTER_NAME" "$(printf '%s' "$info" | awk '{print $1, $2}')"
      printf '%s' "$info" | grep -q 'oidc' && pass "oidc provider" "present (IRSA possible)" \
                                           || fail "oidc provider" "absent; IRSA roles cannot be created"
      addons="$(aws_q eks list-addons --cluster-name "$CLUSTER_NAME" --query 'addons' --output text)"
      for a in aws-ebs-csi-driver metrics-server; do
        printf '%s' "$addons" | grep -q "$a" && pass "addon $a" "" \
          || fail "addon $a" "EKS does not enable it by default and the install needs it"
      done ;;
  esac
fi

# ── Summary ─────────────────────────────────────────────────────────────────
printf '\n%s\n' "$PASS passed, $WARN warnings, $FAIL failures."
if [ "$FAIL" -gt 0 ]; then
  echo "Clear the failures before the install. Warnings are judgement calls." >&2
  exit 1
fi
echo "No blocking problems found. Warnings above are worth a look."
