#!/usr/bin/env bash
# Collect a support bundle from a Marshal install: one folder (and a .tar.gz)
# with the cluster state and the logs of every relevant component for the last
# N hours, including the supervisor and agent logs of the spaces you name.
#
# READ-ONLY. It runs `kubectl get|describe|logs|top` and `helm list|status|history`
# and nothing else. It does not read Secrets, does not print `helm get values`
# (which holds your licence and pull token), and changes nothing in the cluster.
#
# Usage:
#   scripts/support-bundle.sh [--since 6h] [--space <id|name|slug>]... [--all-spaces]
#                             [--max-spaces 100] [--namespace marshal]
#                             [--spaces-namespace marshal-spaces] [--out DIR] [--no-tar]
#                             [--audit | --no-audit]
#
#   --space X       Collect that space's logs. Repeatable. X is the space id, the
#                   space name or its slug, or part of the pod name.
#   --all-spaces    Collect the logs of every space pod (capped by --max-spaces).
#   (neither)       Collect the spaces that look unhealthy: not Running, or a
#                   container that restarted, up to 20 of them.
#
#   --audit         Also export the Marshal audit log for the same time window
#   --no-audit      (who did what: sign-ins, space starts and stops, tool and
#                   network calls). Neither flag: you are asked, default no.
#                   The audit log can name people, hosts and tools, so it is
#                   never included unless you say yes. It is read from the
#                   bundled Postgres pod. With an external database (RDS,
#                   Cloud SQL) the bundle says so and you export it from the
#                   Audit page in the console instead.
#
# Spaces that are stopped have no pod, so there are no container logs to read.
# For those the bundle greps the control-plane logs for the space id instead and
# says so in MANIFEST.txt. If the problem is happening NOW, start the space
# first, then run this.
#
# Redaction: licence JWTs, pull tokens, Bearer tokens, passwords in URLs and
# common key/secret/token assignments are replaced with REDACTED in every file.
# That is best effort. Skim the folder before you send it.
set -uo pipefail

SINCE=6h NS=marshal SPACES_NS=marshal-spaces OUT="" TAR=1 ALL=0 MAXSP=100
SPACES=()
AUDIT=ask
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:?}"; shift 2 ;;
    --space) SPACES+=("${2:?}"); shift 2 ;;
    --all-spaces) ALL=1; shift ;;
    --max-spaces) MAXSP="${2:?}"; shift 2 ;;
    --namespace) NS="${2:?}"; shift 2 ;;
    --spaces-namespace) SPACES_NS="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --no-tar) TAR=0; shift ;;
    --audit) AUDIT=yes; shift ;;
    --no-audit) AUDIT=no; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$SINCE" in *[!0-9smhd]*|"") echo "--since must look like 90m, 6h or 2d" >&2; exit 2 ;; esac

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 2; }
TS="$(date -u +%Y%m%dT%H%MZ)"
OUT="${OUT:-./marshal-support-$TS}"
mkdir -p "$OUT"/{cluster,control-plane,spaces,helm} || exit 2
MANIFEST="$OUT/MANIFEST.txt"
: >"$MANIFEST"
note() { printf '%s\n' "$*" >>"$MANIFEST"; }

# run <dest-file> <command...>: capture stdout to dest; ALWAYS record the outcome,
# so a missing file is explained instead of silently absent.
run() {
  local dest="$1"; shift
  mkdir -p "$(dirname "$dest")"
  local err; err="$(mktemp)"
  if timeout 90 "$@" >"$dest" 2>"$err"; then
    note "ok       ${dest#"$OUT"/}"
  else
    note "FAILED   ${dest#"$OUT"/}  ($(head -c 200 "$err" | tr '\n' ' '))"
  fi
  rm -f "$err"
}
# logs <dest> <pod> <ns> <container> [--previous]
logs() {
  local dest="$1" pod="$2" ns="$3" c="$4"; shift 4
  run "$dest" kubectl logs "$pod" -n "$ns" -c "$c" --since="$SINCE" --timestamps --limit-bytes=52428800 "$@"
}

note "Marshal support bundle"
note "collected_at_utc: $(date -u +%FT%TZ)"
note "log_window:       last $SINCE"
note "context:          $(kubectl config current-context 2>/dev/null || echo unknown)"
note "namespaces:       control plane=$NS  spaces=$SPACES_NS"
note ""

# ── Cluster ─────────────────────────────────────────────────────────────────
run "$OUT/cluster/version.txt"        kubectl version
run "$OUT/cluster/nodes.txt"          kubectl get nodes -o wide --show-labels
run "$OUT/cluster/nodes-describe.txt" kubectl describe nodes
run "$OUT/cluster/top-nodes.txt"      kubectl top nodes
run "$OUT/cluster/pods-all.txt"       kubectl get pods -A -o wide
run "$OUT/cluster/pods-not-running.txt" kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide
run "$OUT/cluster/events.txt"         kubectl get events -A --sort-by=.lastTimestamp
run "$OUT/cluster/pdb.txt"            kubectl get pdb -A
run "$OUT/cluster/hpa.txt"            kubectl get hpa -A
run "$OUT/cluster/pvc.txt"            kubectl get pvc -A
run "$OUT/cluster/ingress.txt"        kubectl get ingress,svc -n "$NS" -o wide
run "$OUT/cluster/storageclass.txt"   kubectl get storageclass
run "$OUT/cluster/priorityclass.txt"  kubectl get priorityclass
if command -v helm >/dev/null; then
  run "$OUT/helm/list.txt"    helm list -A
  rel="$(helm list -n "$NS" -q 2>/dev/null | head -1)"
  if [ -n "$rel" ]; then
    run "$OUT/helm/status.txt"  helm status "$rel" -n "$NS"
    run "$OUT/helm/history.txt" helm history "$rel" -n "$NS"
  fi
else
  note "skipped  helm/ (helm is not installed here)"
fi

# ── Control plane: every container of every pod in the release namespace ─────
for pod in $(kubectl get pods -n "$NS" -o name 2>/dev/null | sed 's#^pod/##'); do
  d="$OUT/control-plane/$pod"
  run "$d/describe.txt" kubectl describe pod "$pod" -n "$NS"
  for c in $(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null); do
    logs "$d/$c.log" "$pod" "$NS" "$c"
    # A previous log exists only after a restart; absence is normal, so don't record a failure.
    kubectl logs "$pod" -n "$NS" -c "$c" --previous --since="$SINCE" --timestamps >"$d/$c.previous.log" 2>/dev/null \
      && note "ok       control-plane/$pod/$c.previous.log" || rm -f "$d/$c.previous.log"
  done
done

# ── Spaces ───────────────────────────────────────────────────────────────────
# Tab-separated: pod, space-id, space-name, phase, total restarts, node
TAB="$(printf '\t')"
kubectl get pods -n "$SPACES_NS" -l app=marshal-space -o \
  jsonpath="{range .items[*]}{.metadata.name}{\"\\t\"}{.metadata.labels['space-id']}{\"\\t\"}{.metadata.labels['space-name']}{\"\\t\"}{.status.phase}{\"\\t\"}{.status.containerStatuses[*].restartCount}{\"\\t\"}{.spec.nodeName}{\"\\n\"}{end}" \
  >"$OUT/spaces/_pods.tsv" 2>"$OUT/spaces/_pods.err" \
  && note "ok       spaces/_pods.tsv" || note "FAILED   spaces/_pods.tsv  ($(head -c 200 "$OUT/spaces/_pods.err" | tr '\n' ' '))"
rm -f "$OUT/spaces/_pods.err"
run "$OUT/spaces/_pods-wide.txt" kubectl get pods -n "$SPACES_NS" -o wide
run "$OUT/spaces/_events.txt"    kubectl get events -n "$SPACES_NS" --sort-by=.lastTimestamp

selected=()
if [ "$ALL" = 1 ]; then
  while IFS="$TAB" read -r pod _; do [ -n "$pod" ] && selected+=("$pod"); done <"$OUT/spaces/_pods.tsv"
elif [ ${#SPACES[@]} -gt 0 ]; then
  for want in "${SPACES[@]}"; do
    found=0 pats=(-e "$want")
    while IFS="$TAB" read -r pod sid sname _; do
      [ -n "$pod" ] || continue
      case "$sid|$sname|$pod" in *"$want"*) selected+=("$pod"); found=1; pats+=(-e "$sid") ;; esac
    done <"$OUT/spaces/_pods.tsv"
    [ "$found" = 1 ] || note "NO POD   space '$want': no pod in $SPACES_NS (stopped, or the name is wrong). Control-plane mentions are in spaces/$want/api-mentions.log."
    mkdir -p "$OUT/spaces/$want"
    grep -rhF "${pats[@]}" "$OUT/control-plane" --include='*.log' >"$OUT/spaces/$want/api-mentions.log" 2>/dev/null || true
  done
else
  # Default: the spaces that look unhealthy.
  while IFS="$TAB" read -r pod sid sname phase restarts _; do
    [ -n "$pod" ] || continue
    r=0; for n in $restarts; do r=$((r + n)); done
    { [ "$phase" != "Running" ] || [ "$r" -gt 0 ]; } && selected+=("$pod")
  done <"$OUT/spaces/_pods.tsv"
  note "spaces:   no --space given: collected the ${#selected[@]} unhealthy space pod(s). Use --space <name> or --all-spaces for others."
fi

# de-duplicate, then cap
mapfile -t selected < <(printf '%s\n' "${selected[@]:-}" | awk 'NF && !s[$0]++')
if [ "${#selected[@]}" -gt "$MAXSP" ]; then
  note "CAPPED   ${#selected[@]} space pods selected, collecting the first $MAXSP (raise --max-spaces)"
  selected=("${selected[@]:0:$MAXSP}")
fi
[ "$ALL" = 1 ] && note "spaces:   --all-spaces: ${#selected[@]} space pod(s)"
[ "$ALL" = 0 ] && [ ${#SPACES[@]} -gt 5 ] && note "spaces:   more than 5 spaces named: ${#selected[@]} pod(s) matched"

for pod in "${selected[@]}"; do
  [ -n "$pod" ] || continue
  d="$OUT/spaces/$pod"
  run "$d/describe.txt" kubectl describe pod "$pod" -n "$SPACES_NS"
  run "$d/events.txt"   kubectl get events -n "$SPACES_NS" --field-selector=involvedObject.name="$pod" --sort-by=.lastTimestamp
  for c in $(kubectl get pod "$pod" -n "$SPACES_NS" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null); do
    # supervisor = lifecycle, restore/persist, run events. agent = the coding agent. docker = the DinD sidecar.
    logs "$d/$c.log" "$pod" "$SPACES_NS" "$c"
    kubectl logs "$pod" -n "$SPACES_NS" -c "$c" --previous --since="$SINCE" --timestamps >"$d/$c.previous.log" 2>/dev/null \
      && note "ok       spaces/$pod/$c.previous.log" || rm -f "$d/$c.previous.log"
  done
done

# ── Audit log (only if asked for) ────────────────────────────────────────────
if [ "$AUDIT" = ask ]; then
  if [ -t 0 ]; then
    printf 'Include the audit log for the last %s? It records who did what (sign-ins, space starts and stops, tool and network calls). [y/N] ' "$SINCE"
    read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) AUDIT=yes ;; *) AUDIT=no ;; esac
  else
    AUDIT=no
  fi
fi
if [ "$AUDIT" = yes ]; then
  mkdir -p "$OUT/audit"
  n="${SINCE%[smhd]}"; u="${SINCE: -1}"
  case "$u" in s) unit=seconds ;; m) unit=minutes ;; h) unit=hours ;; d) unit=days ;; esac
  pgpod="$(kubectl get pods -n "$NS" -l app.kubernetes.io/name=postgresql -o name 2>/dev/null | head -1)"
  if [ -n "$pgpod" ]; then
    run "$OUT/audit/audit_events.csv" kubectl exec -n "$NS" "$pgpod" -- sh -c \
      "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U \"\${POSTGRES_USER:-marshal}\" -d \"\${POSTGRES_DB:-marshal}\" -v ON_ERROR_STOP=1 -c \"\\copy (select created_at, org_id, user_id, user_name, session_id, action, resource_type, resource_id, status, severity, status_code, metadata from public.audit_events where created_at > now() - interval '$n $unit' order by created_at desc limit 200000) to stdout csv header\""
  else
    note "SKIPPED  audit/  (no bundled Postgres pod found: the database is external. Export the audit log from the Audit page in the console, or from the bucket set in Settings > Auditing, and send it separately)"
    echo "audit: no bundled Postgres pod found; see MANIFEST.txt" >&2
  fi
else
  note "SKIPPED  audit/  (not requested)"
fi

# ── Redact every file, then pack ─────────────────────────────────────────────
note ""
note "redaction: applied to every file below (best effort; skim before sending)"
find "$OUT" -type f ! -name MANIFEST.txt -print0 | xargs -0 -r sed -i -E \
  -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/REDACTED_JWT/g' \
  -e 's/mrpt_[A-Za-z0-9._-]+/mrpt_REDACTED/g' \
  -e 's/[Bb]earer +[A-Za-z0-9._~+\/=-]{8,}/Bearer REDACTED/g' \
  -e 's#(://[^:/@ ]+):[^@/ ]+@#\1:REDACTED@#g' \
  -e 's/AKIA[0-9A-Z]{16}/AKIA_REDACTED/g' \
  -e 's/(gh[pousr]_|sk-|xox[abprs]-)[A-Za-z0-9_-]{16,}/\1REDACTED/g' \
  -e 's/((password|passwd|secret|token|api[_-]?key|authorization|credential)[A-Za-z_]*["'"'"']?[ ]*[:=][ ]*["'"'"']?)[^ "'"'"',}]+/\1REDACTED/Ig'

cat >"$OUT/README.txt" <<EOF
Marshal support bundle, collected $(date -u +%FT%TZ), log window: last $SINCE.

  MANIFEST.txt     what was collected and what failed, and why
  cluster/         nodes, events, pods, PDBs, HPAs, PVCs, ingress
  helm/            release status and history (no values)
  control-plane/   describe + logs of every container, per pod
  audit/           the audit log for the window, only if you asked for it
  spaces/          one folder per space pod: supervisor.log (lifecycle, restore,
                   run events), agent.log, docker.log, describe, events

Before you send it: open a few files and check nothing sensitive is left.
Send the .tar.gz, not the folder.
EOF
if [ "$TAR" = 1 ]; then
  tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" && echo "bundle: $OUT.tar.gz"
fi
echo "folder: $OUT"
fails="$(grep -c '^FAILED' "$MANIFEST" || true)"
echo "collected with $fails failure(s). Read $MANIFEST first."
