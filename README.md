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
apps/whoami/          demo app: kustomize base + per-env overlays
argocd/projects/      AppProject — the tenancy boundary
argocd/applicationsets/  ApplicationSet — one Application per environment
infra/clusters/       kind cluster definitions
infra/scripts/        tooling and cluster lifecycle
```

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

## 3. Install Argo CD on the hub ⬜

Install **v3.5.3 with the hydrator manifest**, not plain `install.yaml`.
Plain works for steps 3–7, but the promoter work in [TODO.md](TODO.md) needs
the hydrator, and switching later means reinstalling.

```sh
kubectl --context kind-stage create namespace argocd
kubectl --context kind-stage -n argocd apply -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.3/manifests/install-with-hydrator.yaml
kubectl --context kind-stage -n argocd rollout status deploy/argocd-server --timeout=300s
```

Get the initial admin password:

```sh
kubectl --context kind-stage -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Reach the UI. Port-forward works immediately:

```sh
kubectl --context kind-stage -n argocd port-forward svc/argocd-server 8081:443
# https://localhost:8081  (user: admin)
```

For the ingress path instead — the `stage` cluster maps host ports 8080/8443
to 80/443 and its node is labelled `ingress-ready=true` — install
ingress-nginx's kind manifest and add an Ingress. A `LoadBalancer` Service
will never get an address; kind ships no cloud provider.

## 4. Register the spoke clusters ⬜

The ApplicationSet addresses clusters by registered name: `in-cluster`, `int`,
`prod`. `in-cluster` exists by default; the spokes must be added.

**The wrinkle.** Registration stores the spoke's API address in a Secret on the
hub. The kubeconfig kind writes says `https://127.0.0.1:<random-port>`, which
from inside an Argo CD pod means the pod itself. The hub must instead use
`https://int-control-plane:6443` — verified reachable from a pod on `stage`,
with matching cert SANs.

But `argocd cluster add` connects to the spoke itself to create the
ServiceAccount, and `int-control-plane` does not resolve from the *host* —
only from inside the podman network. So the obvious command cannot be used
as-is. Either:

- run `argocd cluster add kind-int --name int` with the normal kubeconfig, then
  patch the resulting cluster Secret's `server` field to the internal address; or
- create the `argocd-manager` ServiceAccount, ClusterRoleBinding and token in
  each spoke with `kubectl`, and build the cluster Secret directly with the
  internal address.

The second is more declarative and avoids the CLI's connection test. Either
way the result is a Secret in `argocd` on the hub labelled
`argocd.argoproj.io/secret-type: cluster`, holding `name`, `server` and a
`config` blob with the bearer token and CA.

Verify:

```sh
argocd cluster list   # expect in-cluster, int, prod — all Successful
```

## 5. Push the app config ⬜

Argo CD reads git, not your working tree. The commit holding `apps/whoami/**`
and `argocd/**` is currently local only.

```sh
git push origin argocd
```

The repo is public, so **no read credentials are needed**. Write credentials
become necessary only for the hydrator in [TODO.md](TODO.md).

## 6. Apply the AppProject, then the ApplicationSet ⬜

Order matters: an Application naming a project that does not exist is
rejected.

```sh
kubectl --context kind-stage apply -f argocd/projects/demo.yaml
kubectl --context kind-stage apply -f argocd/applicationsets/whoami.yaml
```

The AppProject restricts this tenant to this repo and to `demo-*` namespaces
on the three clusters, and permits `Namespace` as the only cluster-scoped kind
so `CreateNamespace=true` works.

## 7. Verify ⬜

```sh
argocd app list                      # whoami-int, whoami-stage, whoami-prod
kubectl --context kind-int  -n demo-int   get deploy,pod
kubectl --context kind-prod -n demo-prod  get deploy,pod,pdb
```

Expect all three `Synced` / `Healthy`, with 1 / 2 / 3 replicas for int / stage
/ prod and a PodDisruptionBudget only in prod.

## 8. Promotion ⬜ — see [TODO.md](TODO.md)

Not implemented, and deliberately so. **Steps 1–7 give you fan-out, not
promotion**: every environment tracks the same branch and the same image tag,
so one commit moves all three at once. Argo GitOps Promoter is the chosen
approach; the work is written up in [TODO.md](TODO.md).

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
