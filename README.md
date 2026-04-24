# ArgoCD Multi-Cluster GitOps with k3d

A production-patterned ArgoCD hub-and-spoke setup running entirely on a single machine using k3d (k3s in Docker). One **hub** cluster runs ArgoCD and manages two **spoke** clusters — demonstrating real multi-cluster GitOps with environment promotion.

## Architecture

```
                        ┌──────────────────┐
                        │   GitHub Repo    │
                        │  (this repo)     │
                        └────────┬─────────┘
                                 │ sync (HEAD)
                                 ▼
┌────────────────────────────────────────────────────────┐
│                  k3d-hub (prod)                        │
│                                                        │
│   ┌──────────────────────────────────────────────┐     │
│   │  ArgoCD                                      │     │
│   │  ├── ApplicationSet: demo-app                │     │
│   │  │   └── Cluster Generator (label: env)      │     │
│   │  ├── AppProject: apps    (dev workloads)     │     │
│   │  └── AppProject: infra   (platform)          │     │
│   └──────────┬────────────────────┬──────────────┘     │
│              │                    │                     │
│    ┌─────────▼─────────┐         │                     │
│    │ demo-app-prod     │         │                     │
│    │ (3 replicas)      │         │                     │
│    └───────────────────┘         │                     │
└──────────────────────────────────┼─────────────────────┘
                    ┌──────────────┴──────────────┐
                    │                             │
         ┌──────────▼──────────┐       ┌──────────▼──────────┐
         │    k3d-int          │       │    k3d-stage        │
         │                     │       │                     │
         │  demo-app-int       │       │  demo-app-stage     │
         │  (1 replica)        │       │  (2 replicas)       │
         │  "Hello from INT"   │       │  "Hello from STAGE" │
         └─────────────────────┘       └─────────────────────┘
```

## Best Practices Applied

This setup follows the patterns recommended by the [Codefresh ArgoCD best practices guide](https://codefresh.io/blog/argo-cd-anti-patterns-for-gitops/):

| Pattern | How it's implemented |
|---------|---------------------|
| **Everything in Git** | All ApplicationSets, AppProjects, and manifests are declarative YAML in this repo |
| **ApplicationSets over manual Apps** | Cluster generator with `env` label auto-creates apps per cluster |
| **Separate infra from apps** | Distinct `AppProject`s: `apps` (dev workloads) vs `infra` (platform) |
| **Kustomize overlays per env** | `base/` + `overlays/{int,stage,prod}` — each independently buildable |
| **Auto-sync + self-heal** | All apps have `automated: {prune: true, selfHeal: true}` |
| **Promote values, not apps** | ApplicationSet is static; promotion = changing overlay files |
| **Developer independence** | `kustomize build apps/demo-app/overlays/int` works without ArgoCD |
| **No Helm sandwich** | No Applications wrapped in Helm charts |
| **No manual overrides** | No `argocd app set`; all config flows through Git |
| **HEAD for targetRevision** | All apps track `HEAD` — promotion happens via Git, not revision pinning |
| **Cluster labels** | Clusters labeled `env=int/stage/prod` — no ad-hoc server configs |
| **Declarative cluster secrets** | Clusters registered as Kubernetes Secrets, not `argocd cluster add` |

## Prerequisites

- Docker (running)
- kubectl
- helm
- argocd CLI
- ~4 GB free RAM (3 lightweight k3d clusters)
- A GitHub repository (this repo pushed to a remote)

## Repository Structure

```
.
├── scripts/                           # Step-by-step setup scripts
│   ├── 01-install-k3d.sh             # Install k3d
│   ├── 02-create-clusters.sh         # Create hub + int + stage clusters
│   ├── 03-install-argocd.sh          # Helm install ArgoCD on hub
│   ├── 04-register-clusters.sh       # Register spokes + label clusters
│   ├── 05-bootstrap-argocd.sh        # Apply projects + ApplicationSets
│   └── 99-teardown.sh                # Delete everything
│
├── argocd-config/                     # ArgoCD configuration (separate concern)
│   ├── projects/
│   │   ├── apps-project.yaml         # AppProject: developer workloads
│   │   └── infra-project.yaml        # AppProject: infrastructure
│   └── applicationsets/
│       └── demo-app-appset.yaml      # ApplicationSet: cluster generator
│
├── apps/                              # Application manifests (Kustomize)
│   └── demo-app/
│       ├── base/                      # Shared base (nginx + configmap)
│       └── overlays/
│           ├── int/                   # 1 replica, INT greeting
│           ├── stage/                 # 2 replicas, STAGE greeting
│           └── prod/                  # 3 replicas, PROD greeting
│
└── infra/                             # Infrastructure manifests
    └── namespace-config/
        ├── base/                      # Namespace + ResourceQuota
        └── overlays/
            ├── int/
            └── stage/
```

**Why three top-level directories?** Following the principle of separating concerns:
- `argocd-config/` — ArgoCD's own configuration (projects, applicationsets)
- `apps/` — Developer application manifests (what gets deployed)
- `infra/` — Platform/infrastructure manifests (namespaces, quotas, etc.)

Developers work in `apps/` and never touch `argocd-config/`. Platform engineers own `infra/` and `argocd-config/`.

## Setup Guide

### Step 1: Install k3d

```bash
./scripts/01-install-k3d.sh
```

Downloads and installs the k3d binary. Skips if already installed.

### Step 2: Create clusters

```bash
./scripts/02-create-clusters.sh
```

Creates three k3d clusters:
- **k3d-hub** — the ArgoCD management plane (prod), exposes port 8080
- **k3d-int** — integration environment (spoke)
- **k3d-stage** — staging environment (spoke)

Verify: `kubectl config get-contexts` should show all three.

### Step 3: Install ArgoCD

```bash
./scripts/03-install-argocd.sh
```

Installs ArgoCD via Helm on the hub cluster. Prints the admin password and UI URL.

Open `http://localhost:8080` and log in with `admin` / `<printed password>`.

### Step 4: Push this repo to GitHub and register clusters

First, push this repo to GitHub:
```bash
git push -u origin main
```

Then register the spoke clusters:
```bash
export GIT_REPO_URL=git@github.com:varunraokadaparthi/argocd.git
./scripts/04-register-clusters.sh
```

This creates ArgoCD cluster secrets with `env` labels and injects the `git_repo_url` annotation that the ApplicationSet references.

### Step 5: Bootstrap ArgoCD

```bash
export GIT_REPO_URL=git@github.com:varunraokadaparthi/argocd.git
./scripts/05-bootstrap-argocd.sh
```

Applies:
1. Git repository secret (tells ArgoCD where to pull manifests)
2. AppProjects (`apps`, `infra`)
3. ApplicationSets (auto-generates one Application per cluster)

ArgoCD auto-syncs and deploys `demo-app` to all three clusters within ~30 seconds.

### Verify everything works

```bash
# Check applications
argocd app list

# Check per-cluster deployments
kubectl --context k3d-hub   get pods -n demo-app
kubectl --context k3d-int   get pods -n demo-app
kubectl --context k3d-stage get pods -n demo-app

# Check environment-specific config
kubectl --context k3d-int   get configmap demo-app-config -n demo-app -o yaml
kubectl --context k3d-stage get configmap demo-app-config -n demo-app -o yaml
```

## How Environment Promotion Works

Promotion = changing overlay files and pushing to Git. The ApplicationSet is **static** — you never modify it.

**Example: promote from 1 replica to 2 in int:**

1. Edit `apps/demo-app/overlays/int/kustomization.yaml`
2. Change replicas from `1` to `2`
3. `git commit && git push`
4. ArgoCD detects the change and auto-syncs within 30 seconds

**Example: promote a new config value from int to stage:**

1. Test the change in `overlays/int/`
2. Copy the same patch into `overlays/stage/`
3. `git commit && git push`
4. ArgoCD syncs both clusters independently

This is the **"promote values, not applications"** pattern — the Application CRDs never change; only the Kustomize overlays do.

## How to Add a New Application

1. Create the Kustomize structure:
   ```
   apps/my-new-app/
   ├── base/
   │   ├── kustomization.yaml
   │   ├── deployment.yaml
   │   └── service.yaml
   └── overlays/
       ├── int/
       │   └── kustomization.yaml
       ├── stage/
       │   └── kustomization.yaml
       └── prod/
           └── kustomization.yaml
   ```

2. Create an ApplicationSet in `argocd-config/applicationsets/my-new-app-appset.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: my-new-app
     namespace: argocd
   spec:
     goTemplate: true
     goTemplateOptions: ["missingkey=error"]
     generators:
       - clusters:
           selector:
             matchExpressions:
               - key: env
                 operator: In
                 values: [int, stage, prod]
     template:
       metadata:
         name: 'my-new-app-{{.metadata.labels.env}}'
       spec:
         project: apps
         source:
           repoURL: '{{.metadata.annotations.git_repo_url}}'
           targetRevision: HEAD
           path: 'apps/my-new-app/overlays/{{.metadata.labels.env}}'
         destination:
           server: '{{.server}}'
           namespace: my-new-app
         syncPolicy:
           automated:
             prune: true
             selfHeal: true
           syncOptions:
             - CreateNamespace=true
   ```

3. Add the namespace to the `apps` AppProject's allowed destinations.

4. Commit, push, and apply: `kubectl apply -f argocd-config/applicationsets/`

## How to Add a New Cluster

1. Create the k3d cluster:
   ```bash
   k3d cluster create qa --servers 1 --agents 1
   ```

2. Register it with ArgoCD as a labeled secret (follow the pattern in `04-register-clusters.sh`), using label `env: qa`.

3. Add `qa` to the ApplicationSet's `matchExpressions.values` list.

4. Create `overlays/qa/` in each app that should deploy there.

5. Commit and push. ArgoCD auto-generates the new Applications.

## Testing Self-Heal

ArgoCD's self-heal reverts manual changes. Try it:

```bash
# Manually scale (ArgoCD will revert within 30s)
kubectl --context k3d-int scale deploy demo-app -n demo-app --replicas=5

# Watch it revert
kubectl --context k3d-int get deploy demo-app -n demo-app -w
```

## Teardown

```bash
./scripts/99-teardown.sh
```

Deletes all three k3d clusters. Your Git repo and manifests remain untouched — you can recreate the entire setup in minutes by re-running the scripts.

## Troubleshooting

**ArgoCD UI not accessible on port 8080:**
```bash
# Check the load balancer
docker ps | grep k3d-hub-serverlb
# Restart it if needed
k3d cluster start hub
```

**Application stuck in "Unknown" or "Missing":**
```bash
# Check cluster connectivity
argocd cluster list
# Verify the secret labels
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster --show-labels
```

**Sync errors:**
```bash
# Check ApplicationSet status
kubectl -n argocd get applicationsets
kubectl -n argocd describe applicationset demo-app
# Check generated Applications
kubectl -n argocd get applications
argocd app get demo-app-int
```

**Kustomize build errors (test locally first):**
```bash
kustomize build apps/demo-app/overlays/int
kustomize build apps/demo-app/overlays/stage
kustomize build apps/demo-app/overlays/prod
```
