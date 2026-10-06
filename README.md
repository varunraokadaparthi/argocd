# argocd

Multi-cluster GitOps demo: three kind clusters on podman, Argo CD on the hub,
a demo app delivered to all three environments.

| Cluster | Role  | Context      | Namespace    |
| ------- | ----- | ------------ | ------------ |
| `stage` | hub   | `kind-stage` | `demo-stage` |
| `int`   | spoke | `kind-int`   | `demo-int`   |
| `prod`  | spoke | `kind-prod`  | `demo-prod`  |

Argo CD runs on `stage` and manages itself plus the two spokes.

```
apps/whoami/                    demo app: kustomize base + per-env overlays
argocd/install/                 Argo CD itself, version pinned
argocd/projects/                AppProject — the tenancy boundary
argocd/applicationsets/         ApplicationSet — one Application per environment
argocd/cluster-registration/    RBAC granting the hub access to a spoke
infra/clusters/                 kind cluster definitions
infra/scripts/                  tooling, cluster lifecycle, bootstrap
```

## Making a change

`main` is the source of truth. Argo CD's hydrator reads
`apps/whoami/overlays/*` from `main`, so a commit there is what starts a
deployment.

**Do not commit to `main` directly.** Branch, then raise a pull request:

```sh
git switch main && git pull
git switch -c my-change
# ...
git push -u origin my-change
gh pr create --base main
```

Merging that PR is what begins the promotion chain:

```
PR merged to main
   └─ Argo CD hydrates each overlay      -> environment/<env>-next
        └─ Promoter opens a gated PR     -> environment/<env>
             ├─ int    merges itself
             ├─ stage  merges itself once int is healthy
             └─ prod   waits for /lgtm
```

So an ordinary change goes through two sets of pull requests: yours into
`main`, which is reviewed for intent, and Promoter's per environment, which
are gated on health and ordering. The second set is machine-generated —
never edit those branches by hand.

## Config or commands?

Both, and the split is deliberate. You cannot GitOps your way into having
Argo CD, so bootstrap is imperative — but the scripts are thin wrappers that
apply config from this repo rather than inlining YAML.

| Thing | Where it lives | Why |
| --- | --- | --- |
| Argo CD version and manifest | `argocd/install/` | Upgrading is a reviewable diff, not an argument someone typed once |
| Spoke RBAC | `argocd/cluster-registration/` | Grants an identity, holds no credential |
| AppProject, ApplicationSet | `argocd/` | Applied once, then Argo CD owns them |
| App manifests | `apps/` | Argo CD reconciles these from git continuously |
| **Cluster credentials** | **nowhere — generated at run time** | Bearer tokens must never be committed |

The bootstrap order is `setup-tools` → `create-clusters` → `install-argocd` →
`register-clusters` → `bootstrap-apps`. Each is idempotent and each refuses to
run if the previous one has not.

To pause without losing anything, `stop-clusters.sh` and `start-clusters.sh`
stop and restart the node containers; etcd, Argo CD and the registered spokes
all survive. `delete-clusters.sh` discards the clusters and is the only way to
get the disk back.

## Vault

Vault runs *beside* the clusters rather than in one of them — a podman
container on the same `kind` network:

```sh
cd infra
./scripts/vault-up.sh      # start, initialise on first run, unseal
./scripts/vault-down.sh    # stop, keep data;  --purge to destroy it
```

| | |
| --- | --- |
| From the host | `http://127.0.0.1:8200` (UI, token auth) |
| From any pod | `http://vault:8200` |
| Storage | file backend in the `vault-data` podman volume |
| Unseal keys | `infra/vault/.vault-init.json`, mode 0600, gitignored |

Being outside the clusters means every cluster reaches it by the same name,
it survives `delete-clusters.sh`, and it behaves the way Vault usually does
for an application team: a service someone else operates. `vault-up.sh` is
idempotent — it initialises once and unseals on every run, which is what you
need after a restart.

Two things that are wrong for production and deliberate here: TLS is
disabled, and the seal uses a single key share so a script can replay it.

## Secrets: Vault → the app

```sh
cd infra
./scripts/secrets-bootstrap.sh
```

Seeds Vault, installs External Secrets Operator on the hub, and gives the hub
a narrow identity on each spoke. Idempotent.

```
Vault  demo/whoami {greeting}          container, outside every cluster
  │
  │  ExternalSecret          (hub only — the sole Vault credential)
  ▼
demo-stage/whoami-config     Secret on the hub
  │
  │  PushSecret              ESO kubernetes provider, hub → spoke
  ├────────────► demo-int/whoami-config
  └────────────► demo-prod/whoami-config
```

**int and prod never hold a Vault credential.** The hub's identity on each
spoke is a `Role` scoped to Secrets in one namespace — separate from the
cluster-admin `argocd-manager` holds, so the secret path does not ride on
Argo CD's credentials. Vault's ESO policy is read-only and confined to the
`demo` mount.

The app's dependency is real rather than decorative: `WHOAMI_NAME` comes from
a `secretKeyRef` that is not `optional`, so without the Secret the pod sits in
`CreateContainerConfigError` instead of starting with an empty value. whoami
renders it as the first line of every response:

```
Name: hello-from-vault
Hostname: whoami-5bbdbb6b94-kl4wt
```

### Rotation

Rotation is end to end with no manual step:

```sh
vault kv put demo/whoami greeting="something-new"
```

Within roughly three minutes every cluster is serving the new value. The
chain is ESO pulling on its 1m interval, PushSecret replicating on its own
1m interval, then [Reloader](https://github.com/stakater/Reloader) noticing
the changed Secret and performing a rolling restart.

That last step is necessary, not decorative. An environment variable from a
`secretKeyRef` is resolved once at container start, so updating the Secret
alone leaves running pods serving the stale value — verified before Reloader
was added. Mounting the secret as a file would not help either, because
whoami takes its name as a command-line argument.

The Deployment opts in by name rather than with
`reloader.stakater.com/auto`, so the dependency is readable where it matters:

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: whoami-config
```

Reloader runs on **all three clusters** — it acts on Deployments in its own
cluster and cannot reach across — installed by the `reloader` ApplicationSet
under the `platform` project.

## Two AppProjects

| Project | Holds | May create |
| --- | --- | --- |
| `demo` | the whoami app | namespaced resources in `demo-*` only |
| `platform` | Reloader | `ClusterRole`, `ClusterRoleBinding`, `Namespace` |

Reloader watches every namespace, so it needs cluster-scoped RBAC and a
namespace outside `demo-*`. Widening `demo` to fit would have granted the
application tenant the ability to create ClusterRoles — precisely what an
AppProject exists to prevent. Platform components and application workloads
want different permissions, so they get different projects.


---

# Full setup

Status as of writing: steps 1–2 are done, 3 onward are not.

## 1. Install tooling ✅

```sh
cd infra
./scripts/setup-tools.sh
```

Installs and version-checks podman, kind, kubectl, helm and argocd on macOS
(Apple Silicon or Intel) and Linux (amd64 or arm64). See
[infra/README.md](infra/README.md) for host requirements — on Linux the one
that actually bites is cgroup v2 delegation of `cpu`, `memory` and `pids`.

The argocd CLI is pinned to v3.5.3 to match the server installed in step 3.
The source hydrator that [TODO.md](TODO.md) depends on is beta in Argo CD
3.5.0+, so both must be 3.5.x.

## 2. Create the clusters ✅

```sh
cd infra
./scripts/create-clusters.sh
```

Idempotent. Creates `stage`, `int`, `prod`, each single-node, each with its own
pod/service CIDR, all on the shared `kind` podman network. Prints each
cluster's in-cluster API endpoint, which step 4 needs.

## 3. Install Argo CD on the hub ✅

```sh
cd infra
./scripts/install-argocd.sh
```

Applies `argocd/install/`, which pins **v3.5.3 via
`install-with-hydrator.yaml`** rather than plain `install.yaml`. That manifest
already sets `hydrator.enabled: "true"` and ships the commit-server, both of
which the promoter work in [TODO.md](TODO.md) needs. The script asserts the
flag afterwards so a wrong pin fails loudly here instead of confusingly later.

Server-side apply is used out of necessity, not preference: the Argo CD CRDs
exceed the 262144-byte limit on the annotation that client-side apply writes.

The script installs ingress-nginx first (`argocd/ingress-nginx/`, pinned), then
Argo CD with an Ingress, and prints the version and initial admin password.
The UI is at <https://localhost:8443> (user: `admin`; the certificate is
self-signed, so the browser will warn). ingress-nginx redirects plain HTTP to
HTTPS, so 8443 is the port to use even though 8080 is also mapped. If something
else on your machine already holds 8080, it will shadow the cluster there.

`server.insecure` is set on argocd-server so TLS ends at the ingress instead of
the two fighting over redirects. A `LoadBalancer` Service will never get an
address; kind ships no cloud provider, hence ingress rather than a Service.

## 4. Register the spoke clusters ✅

```sh
cd infra
./scripts/register-clusters.sh
```

The ApplicationSet addresses clusters by registered name: `in-cluster`, `int`,
`prod`. `in-cluster` exists by default; the spokes must be added.

**Why not `argocd cluster add`.** The hub must record the spoke's in-network
address, `https://int-control-plane:6443` — the `127.0.0.1:<random-port>` in
the kubeconfig would, from inside an Argo CD pod, mean the pod itself. But
`argocd cluster add` connects to the spoke to create the ServiceAccount, and
`int-control-plane` does not resolve from the *host*, only from inside the
podman network. So the CLI cannot be pointed at the address that needs
storing.

The script splits it instead:

- `argocd/cluster-registration/argocd-manager-rbac.yaml` is applied to each
  spoke. It holds the ServiceAccount, ClusterRole, binding and a requested
  token Secret — no credential, so it lives in git.
- The Secret on the hub is assembled at run time from that token plus the
  internal address. It holds a bearer token and is never committed.

It then verifies each address from a pod inside the hub, checking DNS,
routing and TLS against the stored CA.

## 5. Push the app config ✅

Argo CD reads git, not your working tree. The commit holding `apps/whoami/**`
and `argocd/**` is currently local only.

```sh
git push origin main
```

`bootstrap-apps.sh` warns if you skip this, and the symptom if you ignore it
is `app path does not exist` on every Application.

The repo is public, so **no read credentials are needed**. Write credentials
become necessary only for the hydrator in [TODO.md](TODO.md).

## 6. Apply the AppProjects and ApplicationSets ✅

```sh
cd infra
./scripts/bootstrap-apps.sh
```

Applies both AppProjects first — an Application naming a project that does
not exist is rejected — then the three ApplicationSets: `whoami`, `reloader`
and `argo-rollouts`. Nine Applications in total, three per cluster. The
script refuses to run if Argo CD is missing or a spoke is unregistered, and
warns about unpushed commits.

This is the last imperative step for the application itself. From here Argo
CD reconciles from the repo.

## 7. Verify ✅

```sh
argocd app list
kubectl --context kind-int  -n demo-int  get rollout,pod
kubectl --context kind-prod -n demo-prod get rollout,pod,pdb
```

Expect nine Applications `Synced` / `Healthy`, and 1 / 2 / 3 replicas for
int / stage / prod with a PodDisruptionBudget only in prod.

## 8. Promotion — GitOps Promoter ✅

Live. A change to `apps/whoami/overlays/*` is hydrated to all three
`-next` branches, Promoter opens a gated PR per environment, int and stage
merge themselves in order, and prod waits for a human.

Setting it up on a fresh cluster needs a GitHub App, which is a browser step
nobody can script.

`promoter-bootstrap.sh` calls `promoter-branches.sh`, which creates the
three active environment branches as empty commits. The
`environment/*-next` branches are *not* created: pushing them is the
hydrator's job, and a pre-created commit without a `hydrator.metadata` file
makes Promoter refuse it with "has hydrated commit … but no dry SHA".

```sh
export GITHUB_APP_ID=123456
export GITHUB_INSTALLATION_ID=12345678
export GITHUB_APP_PRIVATE_KEY=~/Downloads/your-app.private-key.pem
cd infra && ./scripts/promoter-bootstrap.sh
```

### The GitHub App

One App serves both Argo CD and Promoter — the permissions are the same.
Settings → Developer settings → GitHub Apps → New:

| Repository permission | Access | Needed for |
| --- | --- | --- |
| Contents | Read and write | Argo CD pushes hydrated branches; Promoter merges PRs |
| Pull requests | Read and write | Promoter opens and merges promotion PRs |
| Checks | Read and write | gates report their results, via check runs |

Install it on this repository, generate a private key, and note the App ID
(on the App page) and the Installation ID (the trailing number in the URL of
the installation's settings page).

**The repo being public is not enough.** Reading needed no credential;
hydrating does, because Argo CD has to push.

**A personal access token cannot be used instead**, and not because Promoter
is being opinionated. Gates are published as GitHub *check runs*, and per
GitHub's own documentation, "write permission for the REST API to interact
with checks is only available to GitHub Apps. OAuth apps and authenticated
users … are not able to create them." A PAT would authenticate, open pull
requests, and never report why one was blocked. Promoter's GitLab, Gitea and
Forgejo providers do take a plain token — GitHub is the exception.

A PAT *would* suffice for Argo CD's push credential alone, since the hydrator
only writes branches. That is two credentials to rotate instead of one, for no
gain, so a single App serves both here.

Of the three values only the private key is a secret. The App ID and
Installation ID are just identifiers — the key is what signs a JWT proving
"I am this App", which is then exchanged for a one-hour installation token.

### The key lives in Vault, not on disk

`promoter-bootstrap.sh` writes the credential to `platform/github-app` and
then lets ESO build both consumers' Secrets from it:

```
Vault  platform/github-app {appID, installationID, privateKey}
  ├──► promoter-system/github-app      Promoter's ScmProvider
  └──► argocd/repo-argocd-demo         Argo CD's repository credential
```

So the `.pem` only has to exist on disk for that one command, and rotating
the key afterwards is a `vault kv put` — no re-running the bootstrap, no key
in a shell history. `*.pem` is gitignored as a backstop. If it leaks,
generate a new one on the App page; the App and its installation survive.

**It does not use the `vault` store the demo app uses.** That one is usable
from any namespace on the hub, so anything able to create an ExternalSecret
could have read a key that can push to every branch and merge its own
promotion PRs. The `vault-platform` store is scoped twice over: its Vault
token can read `platform/*` and nothing else, and `conditions` limit it to
the `argocd` and `promoter-system` namespaces. Verified — an ExternalSecret
in `demo-stage` referencing it fails with `SecretSyncedError` and no Secret
is produced.

If Vault goes down these Secrets keep their last value; ESO stops refreshing
rather than deleting, so Argo CD and Promoter carry on.

Check the values before using them — wrong IDs otherwise look like a healthy
controller that silently never opens a PR:

```sh
cd infra && ./scripts/github-app-check.sh
```

It signs a JWT, exchanges it for an installation token, verifies
`contents` / `pull_requests` / `statuses` are all `write`, and confirms the
installation can see the repository — reporting which step failed. If the
installation ID is wrong it lists the ones the App actually has.

### Branches

Six, already created:

```
apps/whoami/overlays/int        dry source, on the `argocd` branch
      │ Argo CD source hydrator renders and pushes
      ▼
environment/int-next            proposed
      │ Promoter opens a PR, gated
      ▼
environment/int                 active — the int cluster syncs this
```

### Why `environment/` and not the app name

`environment/<env>` is the naming Promoter's own documentation recommends,
and it stays correct with more than one application. The axis that scales is
not the branch name but `PromotionStrategy.spec.activePath`:

```
environment/int                        shared active branch
environment/int-next/apps/whoami       whoami's proposed branch
environment/int-next/apps/payments     payments' proposed branch
```

Each application gets its own PromotionStrategy and its own proposed branch,
so it promotes independently, but they all merge into one active branch per
environment, each touching only its own path. Naming the branches after the
app instead would mean three more active branches per application — all of
which someone has to create by hand, since nothing in the toolchain creates
them. `activePath` keeps it at three regardless of how many apps there are.

Only one app here, so `activePath` is unset and the manifests sit at the
branch root under `manifests/`.

Only the three active branches need creating, and only as empty commits —
GitHub cannot open a pull request into a base branch that does not exist,
and Promoter has no branch-creation code of its own. The `-next` branches
appear when Argo CD first hydrates.

Creating them empty is safe despite `prune: true`. An empty branch has no
`manifests/` path at all, since git cannot store an empty directory, so
Argo CD reports `app path does not exist` and syncs nothing. It does not
prune, because it will not act on a desired state it could not determine.

### Order and gates

| Environment | Merge | Waits for |
| --- | --- | --- |
| `int` | automatic | — |
| `stage` | automatic | int healthy |
| `prod` | **human clicks merge** | stage healthy |

Two gates publish GitHub commit statuses, so the reasoning is visible on the
PR rather than buried in a controller:

- **`argocd-health`** (`ArgoCDCommitStatus`) — is the Argo CD Application for
  the upstream environment actually healthy? Applications are matched by the
  `promoter.argoproj.io/app: whoami` label, and each one's environment is read
  from `sourceHydrator.syncSource.targetBranch`.
- **`vault-available`** (`WebRequestCommitStatus`) — polls Vault's
  `/v1/sys/health` and requires `sealed == false`. The app will not start
  without its secret, so promoting into an environment whose secret source is
  sealed would produce a green PR and a broken deployment.

Ordering is enforced by `DependentsSuccessfulCommitStatus`, which turns the
`dependsOn` graph into a gate of its own.

### Merging prod with /lgtm

`environment/prod` has `autoMerge: false`, so Promoter opens the PR, runs the
gates and stops. The merge is done by a GitHub Actions workflow
(`.github/workflows/lgtm-merge.yml`) when someone comments:

```
/lgtm
```

Promoter deliberately does not perform this merge, so the act is attributable
to the person who approved it. The workflow checks four things before
merging: the comment starts with `/lgtm`, the PR's base is an
`environment/*` branch so this cannot become a general merge bot, the
commenter has write access, and every check run on the head SHA is
successful. It comments on success and explains itself on refusal.

`/lgtm` is an option, not a requirement — the Merge button still works, and
nothing blocks a normal PR. It has no effect on int or stage, which Promoter
merges itself long before anyone could comment.

**`issue_comment` workflows always run from the default branch's copy of the
file.** The default branch here is `main`, so the workflow is committed there
as well; editing it only on `argocd` changes nothing. Switching the default
branch to `argocd` would remove the duplicate.

## Progressive delivery

Argo Rollouts replaces the Deployment with a `Rollout`, so a new version is
checked before it takes all the traffic. Opted into per environment with two
lines, following the kustomize *components* pattern:

```yaml
components:
  - ../../components/rollout
  - ../../components/rollout/strategy-canary
```

| Environment | Strategy | Shape |
| --- | --- | --- |
| `int` | canary | 25% → pause → health analysis → 50% → pause → 100% |
| `stage` | blue/green | stand up alongside, analyse via preview Service, switch |
| `prod` | blue/green | same as stage, so promotion holds no surprises |

```
apps/whoami/components/rollout/
├── kustomization.yaml                 adds the Rollout, deletes the Deployment
├── rollout.yaml
├── analysistemplate-health-check.yaml  HTTP check, takes a Service name
├── strategy-bluegreen/
└── strategy-canary/
```

Splitting "use a Rollout" from "which strategy" is what makes the strategy
swappable without touching the workload.

### The UI

The dashboard is per-cluster — it only shows Rollouts in the cluster it runs
in — so reach each by port-forward:

```sh
kubectl --context kind-int   -n argo-rollouts port-forward svc/argo-rollouts-int-dashboard        3100:3100
kubectl --context kind-stage -n argo-rollouts port-forward svc/argo-rollouts-in-cluster-dashboard 3101:3100
```

Then <http://localhost:3100/rollouts/demo-int> and
<http://localhost:3101/rollouts/demo-stage>. Open the namespace-scoped path:
the dashboard defaults to `default`, which is empty.

`setup-tools.sh` installs the kubectl plugin, which shows the same state and
can drive a rollout by hand:

```sh
kubectl argo rollouts get rollout whoami -n demo-int --context kind-int --watch
kubectl argo rollouts promote whoami -n demo-prod --context kind-prod
```

### Three things the base layout forced

**The `replicas:` transformer cannot see a Rollout.** It only recognises
Deployment, StatefulSet, ReplicaSet and ReplicationController, so every
overlay failed to build until replica counts moved to per-overlay patches.

**prod's spread patch had to retarget to `Rollout`.** Once the component
deletes the Deployment, a patch whose target matches nothing is a hard error,
not a no-op.

**The pod spec is duplicated** between `base/deployment.yaml` and
`components/rollout/rollout.yaml`. A Rollout is a different kind, not a patch
over a Deployment, so there is no way to inherit it. `workloadRef` avoids the
duplication but leaves a zero-scaled Deployment in the cluster, which reads
worse. They will drift if only one is edited.

### What this does not fix

Promoter promotes **git commits**. The Vault secret lives outside git by
design, so `vault kv put demo/whoami` still reaches all three environments at
once. Gating that needs per-environment paths — `demo/int/whoami`,
`demo/stage/whoami`, `demo/prod/whoami` — with each ExternalSecret reading
only its own. Tracked in [TODO.md](TODO.md).

---

# How this works

## Argo CD's object model

**`Application`** — the unit of sync. A pointer from *(repo, path, revision)*
to *(cluster, namespace)*. Argo CD renders the manifests at that path, diffs
against live state, and reconciles.

**`AppProject`** — the tenancy boundary. Every Application belongs to exactly
one, and the project constrains which repos it may read, which
cluster/namespace pairs it may write, and which resource kinds it may create.
The built-in `default` project allows everything everywhere, which is why real
setups do not use it. **A tenant is an AppProject.**

**`ApplicationSet`** — a generator plus a template, producing one Application
per element. Three environments would otherwise mean three near-identical
Application manifests kept in sync by hand. This repo uses a list generator
because the environment-to-cluster mapping is fixed and worth reading at a
glance; a cluster or git-directory generator would suit a dynamic fleet.

## The sync loop

1. **repo-server** clones at `targetRevision`, enters `path`, detects
   `kustomization.yaml`, runs kustomize build. That output is the desired
   state, cached against the commit SHA.
2. **application-controller** reads live state from the destination cluster
   and diffs.
3. With `syncPolicy.automated`, it applies. `prune: true` deletes what you
   removed from git; `selfHeal: true` reverts manual cluster edits.

Nothing runs on the spokes. The hub's controller makes outbound API calls using
the token from each cluster Secret.

**Detection is polling.** Default reconciliation is every 3 minutes, so a
commit can take that long to appear. A GitHub webhook to `argocd-server` makes
it immediate.
