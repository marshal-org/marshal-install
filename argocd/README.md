# Install Marshal with ArgoCD (GitOps)

An alternative to `terraform apply`: let **ArgoCD** install and reconcile the
Marshal umbrella chart from the OCI registry. [`application.yaml`](application.yaml)
is the `Application`; this README is the flow.

Same product, same chart as the Terraform flavors — only the *installer* differs.
Pick this if ArgoCD is already how you ship to your clusters.

## The #1 gotcha (read first): secrets must be `existing`, never `generated`

ArgoCD **renders** the chart and **applies** the resulting manifests. It does not
run `helm install`, so Helm's `lookup` function — which the chart uses to reuse an
already-generated Secret — **never runs**. With the chart's default
`secrets.provider: generated`, ArgoCD would therefore emit a **fresh random**
`JWT_SECRET` and `KMS_LOCAL_KEY` on **every single sync**. That would:

- invalidate every issued session/API token (JWT_SECRET rotated), and
- make **every stored credential permanently undecryptable** (KMS_LOCAL_KEY is the
  master key that envelope-encrypts them).

So the ArgoCD path **requires** `secrets.provider: existing`: you seed one **stable**
Secret **once**, ArgoCD only *references* it (never manages, never prunes, never
rotates it). The Application in this dir is already set to `existing`.

## Prerequisites

- **ArgoCD** installed in the cluster (namespace `argocd`) and `argocd` CLI logged in.
- Your **shared pull-through image cache** running (one per customer — see the
  top-level README). The Application points `global.registry` at it.
- Your Marshal onboarding credentials: installation JWT, `dep_` id, `mrpt_` pull
  token — see [Credentials](../README.md#credentials-read-this-first).
- A **Postgres 16** DSN the cluster can reach (external / managed).

## On GKE: let Terraform provision, ArgoCD install

If the cluster doesn't exist yet, the [`gcp-gke`](../gcp-gke/) flavor can build it
and install nothing: `install_marshal = false` creates the cluster, node pools,
registry cache, buckets and static IP, makes no `kubernetes`/`helm` provider call,
and leaves the release to the Application here. `deployment_id` and
`registry_pull_token` must still be **real** values in that mode (the registry
cache uses them as its upstream credentials); only `installation_jwt` can be a
placeholder.

**Take the Application's cloud-derived values from the Terraform output, don't
retype them** — Terraform computes them whether or not it installs:

```bash
cd ../gcp-gke && terraform output -raw argocd_derived_values > values-derived.yaml
```

That covers `global.registry`, `toolsRegistryBase`, `registryAuth.mode`,
`ingress.className`/`annotations`, `api.serviceAccount.annotations`,
`supervisor.serviceAccount.annotations`, `controlPlane.nodeSelector`/`tolerations`,
and — when Redis is bundled and the control-plane pool is tainted —
`redis.master.nodeSelector`/`tolerations`, which `controlPlane.*` does not cover
(the bundled Bitnami subcharts don't read it). Re-render it after any apply that
changes the project, cluster name, cache repo, buckets or the taint toggle.
Everything else in the Application is a value you chose yourself.

One of those fails **silently**: a missing or wrong
`supervisor.serviceAccount.annotations` makes every object-storage call 403 at
session runtime (the supervisor does the spaces-persistence blob I/O inside
session pods) while the api's own storage connection test still passes — so the
install looks healthy. The only check that exercises it is to launch a space, stop
it, and resume it.

`secrets.provider: existing` is required on this path like any other ArgoCD
install — see the gotcha above and step 2 below.

## 1. Register the OCI chart repo credential in ArgoCD

ArgoCD needs the pull token to fetch the chart from `registry.marshal.codes`:

```bash
argocd repo add registry.marshal.codes/marshal-charts \
  --type helm --enable-oci \
  --username dep_ab12cd --password 'mrpt_9f3c…'
```

(The proxy ignores the username and authenticates on the `mrpt_` token in the
password — `deployment_id` is convention.) Declarative equivalent: an ArgoCD
`repository` Secret in the `argocd` namespace — keep its real token out of git
(sealed-secret / SOPS / External Secrets).

## 2. Seed the stable Secrets — ONCE (ArgoCD never manages these)

Create the namespace, then seed all operator-owned secret material. These are
**referenced** by the chart, not rendered by it, so ArgoCD never touches them.

```bash
kubectl create namespace marshal

# a) App secrets — the CRITICAL one. Random 32-byte hex each; generated ONCE and
#    never rotated. BACK THIS UP: losing KMS_LOCAL_KEY makes stored credentials
#    unrecoverable.
kubectl create secret generic marshal-app-secrets -n marshal \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=KMS_LOCAL_KEY="$(openssl rand -hex 32)"

# b) License — your installation JWT (key: jwt).
kubectl create secret generic marshal-license -n marshal \
  --from-literal=jwt="eyJhbGc…"

# c) Datastore DSN — external Postgres (key: database-url).
kubectl create secret generic marshal-db -n marshal \
  --from-literal=database-url="postgres://marshal:PW@HOST:5432/marshal?sslmode=require"
```

Prefer not to run `kubectl create secret` by hand? Use a **SealedSecret** (commit
the encrypted form) or **External Secrets Operator** (sync from your cloud secret
manager) for the same three Secrets — the point is only that they are **stable and
not chart-generated**. If you use External Secrets, you can instead set
`secrets.provider: externalSecrets` in the Application and let the operator populate
`marshal-app-secrets`.

## 3. Commit + apply the Application

Edit [`application.yaml`](application.yaml) — set `targetRevision` (chart version),
`global.registry` (your cache), `ingress.className` (whatever ingress controller your
cluster runs — this path isn't tied to one cloud), `ingress.host`, and the Postgres/redis
posture — then:

```bash
kubectl apply -f application.yaml
argocd app sync marshal
argocd app get marshal          # Healthy + Synced
```

Verify like the Terraform path:

```bash
kubectl get pods -n marshal
kubectl logs -n marshal -l app.kubernetes.io/component=api | grep "license verified"
```

## Day-2

- **Sync is manual by default.** The shipped `syncPolicy` has no `automated`
  block — install and every upgrade need an explicit `argocd app sync marshal`,
  same posture as the Terraform flavors needing an explicit `terraform apply`.
  Once you trust this path at your site, opt into full GitOps by adding
  `syncPolicy.automated: {prune: true, selfHeal: true}` — see the comment in
  `application.yaml`. Be aware `selfHeal` will then revert any manual `kubectl`
  fix you apply mid-incident.
- **Upgrade** — bump `targetRevision` in `application.yaml`, commit, then
  `argocd app sync marshal` (automatic if you've opted into `automated`). Roll
  back by reverting the commit + syncing, or `argocd app rollback marshal`.
- **Renew the license** — update the `marshal-license` Secret with the new JWT
  (`kubectl create secret … --dry-run=client -o yaml | kubectl apply -f -`), then
  restart the api. The Application is unchanged.
- **Never** flip `secrets.provider` back to `generated`, and never delete
  `marshal-app-secrets` — see the gotcha above.

## Values from a git file (alternative to inline)

The Application above keeps values inline (`helm.valuesObject`). To keep them in a
git-committed `values.yaml` instead, use a multi-source Application: one source is
the OCI chart, another is your git repo, and `helm.valueFiles` references
`$values/path/to/values.yaml`. Keep secret material OUT of that file — it stays in
the seeded Secrets.
