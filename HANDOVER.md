# Handover

State as of 2026-10-01. Everything below was working when the environment
was shut down.

## Where things stand

The whole chain runs end to end and has been exercised with a real change:

```
PR into main                           (#8, merged by a human)
  └─ Argo CD hydrates each overlay  -> environment/<env>-next
       └─ Promoter opens a gated PR -> environment/<env>
            ├─ int    #10  auto-merged by the promoter app
            ├─ stage  #9   auto-merged once int was healthy
            └─ prod   #11  merged by the /lgtm workflow
```

All three environments are active at `0449267` (the tip of `main`), running
Argo Rollouts with the component label from that change, serving the secret
from Vault. Nine Applications, all Synced and Healthy.

Nothing is in flight. No open PRs, no pending promotions.

## Bringing it back up

```sh
cd infra
./scripts/vault-up.sh        # start Vault, unseal it
./scripts/start-clusters.sh  # start stage, int, prod
```

That is all that is normally needed — the clusters, Argo CD, the registered
spokes, the promoter and everything else survive a stop/start. Give Argo CD
a couple of minutes to reconcile, then:

```sh
kubectl --context kind-stage -n argocd get applications
```

Expect nine, all Synced/Healthy. If they are not, the usual cause is Vault
still being sealed — `vault-up.sh` is idempotent and unseals on every run.

**After more than a day down, re-run the two secrets bootstraps:**

```sh
./scripts/secrets-bootstrap.sh
./scripts/promoter-bootstrap.sh    # needs the GITHUB_APP_* variables
```

Both ESO tokens are created with `-period=24h`. A periodic Vault token only
stays valid while something renews it inside each period, and nothing here
does, so they lapse while the environment is off. The failure is quiet:
existing Kubernetes Secrets keep their values, because ESO stops refreshing
rather than deleting, so every app carries on looking healthy — but
rotation stops working, and a `vault kv put` will not propagate. Both
scripts are idempotent and mint fresh tokens.

## What persists, and what is rebuilt

| | Survives stop | Survives `delete-clusters.sh` | Rebuilt by |
| --- | --- | --- | --- |
| Vault's data (`demo/*`, `platform/*`) | yes | **yes** — Vault is not in a cluster | nothing; it is the source |
| Kubernetes Secrets derived from it | yes | no | ESO, from Vault |
| Argo CD, registered spokes, promoter | yes | no | the bootstrap scripts |
| Cluster workloads | yes | no | Argo CD, from git |

Vault's file backend lives in the `vault-data` podman volume, so nothing
added to Vault is lost by tearing the clusters down. Rebuilding from
scratch needs no secret re-entered by hand — not even the GitHub App key,
which is in Vault at `platform/github-app`.

The one irreplaceable file is `infra/vault/.vault-init.json`. Without that
unseal key the volume is only encrypted bytes.

### Port-forwards

None survive a session. Restart whichever you need:

```sh
# Argo CD UI -- https://localhost:8081, user admin
kubectl --context kind-stage -n argocd port-forward svc/argocd-server 8081:443

# Rollouts dashboards -- note the namespace-scoped paths
kubectl --context kind-int   -n argo-rollouts port-forward svc/argo-rollouts-int-dashboard        3100:3100
kubectl --context kind-stage -n argo-rollouts port-forward svc/argo-rollouts-in-cluster-dashboard 3101:3100
# http://localhost:3100/rollouts/demo-int
# http://localhost:3101/rollouts/demo-stage
```

Vault's UI is at <http://127.0.0.1:8200> and is published by the container,
so it needs no port-forward.

The Argo CD admin password:

```sh
kubectl --context kind-stage -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### Rebuilding from nothing

If the clusters are gone rather than stopped, the full sequence is in
[README.md](README.md). In order:
`setup-tools.sh` → `create-clusters.sh` → `install-argocd.sh` →
`register-clusters.sh` → `bootstrap-apps.sh` → `vault-up.sh` →
`secrets-bootstrap.sh` → `promoter-bootstrap.sh`. Each is idempotent and
refuses to run if the one before it has not.

## Credentials

| What | Where | Notes |
| --- | --- | --- |
| Vault unseal key + root token | `infra/vault/.vault-init.json` | mode 0600, gitignored. **Lose this and the Vault volume is unrecoverable.** |
| GitHub App private key | Vault, `platform/github-app` | ESO builds the Kubernetes Secrets from it |
| GitHub App | `argocd-promoter-app`, id `5144694`, installation `166749577` | permissions: contents, pull_requests, **checks** — all write |

A copy of the App's `.pem` may still be in `~/Downloads`. It is no longer
needed — Vault holds it — and `*.pem` is gitignored, but it is worth
deleting.

## Working on this

`main` is the source of truth and the branch Argo CD hydrates from. Do not
commit to it directly: branch, raise a PR, merge. See **Making a change** in
[README.md](README.md).

The ApplicationSet and AppProjects are applied imperatively, so changing
them in git does nothing until `./infra/scripts/bootstrap-apps.sh` runs
again. Everything under `apps/` is reconciled from git and needs no such
step.

## What is still open

See [TODO.md](TODO.md). The one that matters:

**Secrets bypass promotion entirely.** `vault kv put demo/whoami` reaches
int, stage and prod within about three minutes with no gate, and Reloader
restarts the pods. That is a shorter path to production than a code change,
which at least needs a reviewed PR and then a `/lgtm`. Fixing it means
per-environment Vault paths so each environment's ExternalSecret reads only
its own.

## Things that cost time, so you do not rediscover them

- **The GitHub App needs `checks`, not `commit statuses`.** The CRD is named
  `CommitStatus` but Promoter calls the Checks API. With the wrong one the
  App authenticates, opens PRs, and silently never reports a gate. Run
  `./infra/scripts/github-app-check.sh` — it catches exactly this.
- **Changing App permissions requires accepting them on the installation**
  as a separate step. Saving on the App page is not enough.
- **Argo CD needs two credentials for one repo.** `repository` is read-only;
  pushing hydrated branches needs a second Secret labelled
  `repository-write`. Without it hydration renders, commits, then fails with
  `could not read Username for github.com`.
- **Argo CD refuses to hydrate to a branch root.** `syncSource.path` must be
  a subdirectory; it is `manifests`. A bare `.` also fails CRD validation.
- **Do not pre-create the `environment/*-next` branches.** The hydrator
  creates them. A hand-made commit there has no `hydrator.metadata` and
  Promoter rejects it. Only the three *active* branches need creating, which
  `promoter-branches.sh` does.
- **kustomize's `replicas:` transformer cannot see a Rollout.** It only
  knows Deployment, StatefulSet, ReplicaSet and ReplicationController.
  Replica counts are per-overlay patches for this reason.
- **A base transformer does not reach resources a component introduces.**
  Both the image pin and the labels are repeated in
  `components/rollout/kustomization.yaml` for that reason. They will drift
  if only one copy is edited.
- **Hydration races on `refs/notes/hydrator.metadata`.** Three Applications
  pushing the shared git note at once sometimes fails with `cannot lock
  ref`. It recovers on the next attempt; re-trigger with
  `kubectl -n argocd annotate application <name> argocd.argoproj.io/hydrate=normal --overwrite`.
- **Every promotion hop waits a ~3 minute Argo CD poll.** int → stage → prod
  takes several minutes. A webhook to `argocd-server` would remove it.
- **`/lgtm` only works on `environment/*` PRs**, by design, so it cannot
  become a general merge bot. Ordinary PRs merge normally.
