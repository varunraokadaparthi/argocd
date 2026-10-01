#!/usr/bin/env bash
# Install GitOps Promoter on the hub and wire it to this repository.
#
# Needs a GitHub App -- the ScmProvider CRD makes appID mandatory and offers
# no token path. Creating one is a browser step that cannot be scripted, so
# this reads the details from the environment:
#
#   GITHUB_APP_ID            the App's numeric ID
#   GITHUB_INSTALLATION_ID   its installation ID on this repo
#   GITHUB_APP_PRIVATE_KEY   path to the downloaded .pem
#
# The same App is used for Argo CD's push credential, since the hydrator has
# to write the environment branches and the permissions overlap exactly.
#
# Idempotent.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools

hub_ctx="kind-$HUB"
kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" get deploy argocd-server >/dev/null 2>&1 \
  || die "Argo CD is not installed -- run install-argocd.sh"

missing=()
[[ -n "${GITHUB_APP_ID:-}" ]]          || missing+=(GITHUB_APP_ID)
[[ -n "${GITHUB_INSTALLATION_ID:-}" ]] || missing+=(GITHUB_INSTALLATION_ID)
[[ -n "${GITHUB_APP_PRIVATE_KEY:-}" ]] || missing+=(GITHUB_APP_PRIVATE_KEY)
if [[ ${#missing[@]} -gt 0 ]]; then
  warn "missing: ${missing[*]}"
  cat <<'EOF'

Create a GitHub App first (Settings -> Developer settings -> GitHub Apps):

  Repository permissions
    Contents          Read and write    push hydrated branches, merge PRs
    Pull requests     Read and write    open and merge promotion PRs
    Commit statuses   Read and write    report gate results

  Then: Install App on this repository, generate a private key, and note the
  App ID (on the App page) and the Installation ID (the trailing number in
  the URL of the installation's settings page).

  export GITHUB_APP_ID=123456
  export GITHUB_INSTALLATION_ID=12345678
  export GITHUB_APP_PRIVATE_KEY=~/Downloads/your-app.private-key.pem

EOF
  die "GitHub App details required"
fi

[[ -f "$GITHUB_APP_PRIVATE_KEY" ]] || die "private key not found: $GITHUB_APP_PRIVATE_KEY"

# --- hydrator preflight ---------------------------------------------------

# Without this the Applications will accept a sourceHydrator and then never
# produce a hydrated branch, which is a confusing way to fail.
[[ "$(kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" get cm argocd-cmd-params-cm \
      -o jsonpath='{.data.hydrator\.enabled}' 2>/dev/null)" == "true" ]] \
  || die "Argo CD source hydrator is not enabled -- argocd/install must pin install-with-hydrator.yaml"

# --- argo cd write credential ---------------------------------------------

# The repo is public, so reading needed nothing. Hydrating does: Argo CD has
# to push the environment/*-next branches.
log "giving Argo CD write access to the repo"
kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-argocd-demo
  namespace: $ARGOCD_NAMESPACE
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/varunraokadaparthi/argocd.git
  githubAppID: "$GITHUB_APP_ID"
  githubAppInstallationID: "$GITHUB_INSTALLATION_ID"
  githubAppPrivateKey: |
$(sed 's/^/    /' "$GITHUB_APP_PRIVATE_KEY")
EOF

# --- promoter controller --------------------------------------------------

log "installing GitOps Promoter $PROMOTER_VERSION"
# install-without-ui needs no cert-manager: it ships no admission webhooks.
# Server-side apply for the same reason as Argo CD -- the CRDs are large.
#
# Applied twice on purpose. The manifest contains a ControllerConfiguration
# custom resource alongside the CRD that defines it, so on a fresh cluster the
# CR is rejected before its CRD is established. The controller then crash-loops
# with "ControllerConfiguration not found" rather than anything that points at
# ordering. The first pass installs the CRDs, the second fills in the CR.
promoter_url="https://github.com/argoproj-labs/gitops-promoter/releases/download/$PROMOTER_VERSION/install-without-ui.yaml"

kubectl --context "$hub_ctx" apply --server-side --force-conflicts -f "$promoter_url" >/dev/null 2>&1 || true

kubectl --context "$hub_ctx" wait --for condition=established --timeout=120s \
  crd/controllerconfigurations.promoter.argoproj.io \
  crd/promotionstrategies.promoter.argoproj.io \
  crd/gitrepositories.promoter.argoproj.io \
  crd/scmproviders.promoter.argoproj.io >/dev/null

kubectl --context "$hub_ctx" apply --server-side --force-conflicts -f "$promoter_url" >/dev/null

kubectl --context "$hub_ctx" -n promoter-system \
  rollout status deploy/promoter-controller-manager --timeout=300s

log "storing the GitHub App key for Promoter"
kubectl --context "$hub_ctx" -n promoter-system create secret generic github-app \
  --from-file=githubAppPrivateKey="$GITHUB_APP_PRIVATE_KEY" \
  --dry-run=client -o yaml | kubectl --context "$hub_ctx" apply -f - >/dev/null

# --- promoter resources ---------------------------------------------------

log "applying ScmProvider and GitRepository"
GITHUB_APP_ID="$GITHUB_APP_ID" GITHUB_INSTALLATION_ID="$GITHUB_INSTALLATION_ID" \
  envsubst < "$REPO_ROOT/promoter/scm.yaml" \
  | kubectl --context "$hub_ctx" apply -f - >/dev/null

log "applying PromotionStrategy and gates"
kubectl --context "$hub_ctx" apply -f "$REPO_ROOT/promoter/promotion-strategy.yaml" >/dev/null
kubectl --context "$hub_ctx" apply -f "$REPO_ROOT/promoter/commit-statuses.yaml" >/dev/null

# Switched over last, once the write credential exists. Before that the
# hydrator cannot push, so the Applications would sync from branches that
# never get populated -- and with prune enabled that removes the running
# workload. The active branches are seeded with the current manifests for the
# same reason.
log "switching the Applications to sourceHydrator"
kubectl --context "$hub_ctx" apply -f "$ARGOCD_DIR/applicationsets/whoami.yaml" >/dev/null

# --- report ---------------------------------------------------------------

echo
log "promoter installed"
kubectl --context "$hub_ctx" -n promoter-system get promotionstrategy,gitrepository,scmprovider \
  --no-headers 2>/dev/null | sed 's/^/  /'
echo
log "promotion flow"
printf '  apps/whoami/overlays/<env>  ->  environment/<env>-next  ->  environment/<env>\n'
printf '  int    auto-merge\n'
printf '  stage  auto-merge, waits on int being healthy\n'
printf '  prod   PR opened and gated, merged by a human\n'
echo
log "watch: kubectl --context $hub_ctx -n promoter-system get promotionstrategy whoami -o yaml"
