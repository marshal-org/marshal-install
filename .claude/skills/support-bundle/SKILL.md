---
name: support-bundle
description: Collect what you need to understand a problem on your Marshal install, including the supervisor and agent logs of specific spaces or all spaces, into one redacted folder covering the last N hours, then read it symptom by symptom. Settles which spaces, which time window, whether the space is running and whether to include the audit log, runs scripts/support-bundle.sh, and reads the result with you. Use when a space will not start, died, hangs or behaves wrongly, when the install is unhealthy, or before you contact Marshal support.
---

# Support bundle: logs from every relevant component

The collector is `scripts/support-bundle.sh` in your installer checkout. It only reads,
removes tokens and passwords from every file, and **records every failure in `MANIFEST.txt`**
instead of leaving a file silently missing.

**Speed matters.** Pod logs vanish with the pod, and Kubernetes keeps events for about an
hour by default. A space that was stopped or deleted has no container logs left. Collect the
bundle **as soon as you see the problem**, before anyone restarts anything.

## 1. Settle the inputs

Four answers, then one command. Read what you can first: `kubectl get pods -n marshal-spaces`
lists the space pods, and the Marshal console shows each space's name and status.

- **Which spaces.** The name or id of each space that had the problem. Not sure which? Use
  `--all-spaces` and note roughly when it happened.
- **How far back.** At least the time since it last worked. `--since 6h` is the default; use
  `24h` if it happened yesterday.
- **Is the space running right now?** If it is stopped and the problem is that it will not
  start, **start it first and let it fail**, then collect: a stopped space has no pod and so
  no logs. If it already failed and was restarted, note that.
- **Include the audit log?** It records who did what in the window: sign-ins, space starts and
  stops, tool and network calls. It is your choice, and the default is no, because it names
  people and hosts. Include it when the question is "who or what did this", a blocked call, a
  credential change, or a space that someone stopped. Add `--audit` to include it or
  `--no-audit` to leave it out; with neither, the script asks.

The audit log is read from the bundled Postgres pod. On an external database (RDS, Cloud SQL)
`MANIFEST.txt` says `SKIPPED audit/`; export it from the **Audit** page in the console, or
take it from the bucket in **Settings > Auditing**, and add it separately.

Also note, for the report: when it started (with timezone), what changed just before (an
upgrade, a node change, a new manifest), and the chart version.

## 2. Collect

From a machine with `kubectl` access to the cluster (the bastion, if that is how you reach
it), in your installer checkout:

```bash
scripts/support-bundle.sh --since 6h --space <name-or-id> --no-audit   # named spaces
scripts/support-bundle.sh --since 6h --all-spaces --no-audit           # every space pod, capped at 100
scripts/support-bundle.sh --since 2h --no-audit                        # no space flag: only the unhealthy space pods
```

Repeat `--space` for more than one space. Other flags: `--namespace` (control plane, default
`marshal`), `--spaces-namespace` (default `marshal-spaces`), `--max-spaces`, `--out DIR`,
`--no-tar`. It does not read Secrets or Helm values. It prints the folder and the `.tar.gz`
it wrote.

## 3. Read the bundle

Open `MANIFEST.txt` **first**. `FAILED` lines say what is missing and why (`top nodes` failing
means no metrics-server; a `NO POD` line means that space was stopped).

```
cluster/         nodes, nodes-describe (Allocated resources), events, pods, pdb, hpa, pvc, ingress
helm/            release status and history. No values.
control-plane/   <pod>/describe.txt, <container>.log, <container>.previous.log
spaces/          <pod>/describe.txt, events.txt, supervisor.log, agent.log, docker.log
                 (+ dbproxy.log, mcps.log when the space has them), *.previous.log
                 <name>/api-mentions.log: control-plane lines mentioning that space id
```

| Symptom | Read, in this order |
|---|---|
| A space will not start (stuck starting) | `spaces/<pod>/describe.txt`: the **Events** at the bottom (scheduling, image pull, volume attach). Then `supervisor.log`: the restore and bootstrap phase. Then `docker.log` if the space uses Docker. Then `cluster/events.txt`. |
| Pod Pending | `describe.txt` Events: `Insufficient cpu`, `Insufficient ephemeral-storage`, an untolerated taint, or a volume zone mismatch. Then `cluster/nodes-describe.txt`, **Allocated resources** per node. Then the `size-node-pools` skill. |
| A space died or restarted | `describe.txt`: **Last State** and **Reason** (`OOMKilled`, `Error`, exit code) per container. Then `<container>.previous.log`: the lines just before it died. |
| A run failed or never completed | `supervisor.log`: look for `run:started` and `run:complete`. A run that ends without a completion frame is reported as failed. Then `agent.log`. |
| "too many open files" or "no space left on device" with free disk | inotify exhaustion, not disk. Check `cluster/nodes-describe.txt` for DiskPressure (usually False) and that the node-tuner DaemonSet is running on that node (`cluster/pods-all.txt`). |
| Console errors, 5xx, login problems | `control-plane/<api pod>/api.log` and `gateway`, then `cluster/ingress.txt` and the ingress events. |
| Everything slow or Pending across the board | `cluster/top-nodes.txt`, `cluster/pdb.txt`, `cluster/hpa.txt`, `cluster/pods-not-running.txt`. |
| Right after an upgrade | `helm/history.txt`, then the migrate job pod in `control-plane/`. |

Every log line is timestamped (UTC). Build a short timeline across `supervisor.log`,
`events.txt` and `api-mentions.log` before forming a theory.

## 4. Report

1. **What happened**, with the timeline and the quoted lines that prove it.
2. **Cause**: confirmed, or "likely" with what would confirm it.
3. **Not in the bundle**: what could not be seen (a stopped space, a log window too short,
   `FAILED` lines) and what to collect next.

If you need Marshal support, send that report with the `.tar.gz`, through your shared support
channel or support@marshal.codes.

## 5. Handling the bundle

Logs can hold your data even after redaction (file paths, repo names, prompts). Redaction is
best effort: open a few files before you send the bundle anywhere. Keep it out of public
issues and chat channels, do not commit it, and delete it when the case is closed.
