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
    Checks            Read and write    report gate results as check runs

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

[[ -f "$VAULT_SECRETS_FILE" ]] || die "vault is not initialised -- run vault-up.sh"
podman inspect "$VAULT_CONTAINER" --format '{{.State.Status}}' 2>/dev/null | grep -qx running \
  || die "vault container is not running -- run vault-up.sh"
kubectl --context "$hub_ctx" -n external-secrets get deploy external-secrets >/dev/null 2>&1 \
  || die "External Secrets Operator is not installed -- run secrets-bootstrap.sh"

# --- hydrator preflight ---------------------------------------------------

# Without this the Applications will accept a sourceHydrator and then never
# produce a hydrated branch, which is a confusing way to fail.
[[ "$(kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" get cm argocd-cmd-params-cm \
      -o jsonpath='{.data.hydrator\.enabled}' 2>/dev/null)" == "true" ]] \
  || die "Argo CD source hydrator is not enabled -- argocd/install must pin install-with-hydrator.yaml"

# --- argo cd write credential ---------------------------------------------

# The App credential goes into Vault, and ESO builds both Secrets from it --
# Promoter's in promoter-system and Argo CD's repository credential in argocd.
# The .pem therefore only has to exist on disk for this one command; rotating
# it later is a `vault kv put`, with no re-run of this script.
root_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root_token"])' \
  "$VAULT_SECRETS_FILE")"
vault_exec() {
  podman exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$root_token" \
    "$VAULT_CONTAINER" vault "$@"
}

if vault_exec secrets list -format=json | grep -q '"platform/"'; then
  log "kv-v2 engine 'platform' already enabled"
else
  # A separate mount from the application one so a policy can grant read on
  # platform credentials without also granting read on demo/.
  log "enabling kv-v2 engine at platform/"
  vault_exec secrets enable -path=platform kv-v2 >/dev/null
fi

log "storing the GitHub App credential in Vault at platform/github-app"
vault_exec kv put platform/github-app \
  appID="$GITHUB_APP_ID" \
  installationID="$GITHUB_INSTALLATION_ID" \
  privateKey=@/dev/stdin >/dev/null < "$GITHUB_APP_PRIVATE_KEY"

log "applying platform read policy"
vault_exec policy write eso-platform - < "$REPO_ROOT/secrets/vault/platform-policy.hcl" >/dev/null

log "minting a Vault token for the platform store"
platform_token="$(vault_exec token create -policy=eso-platform -period=24h -format=json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"])')"

kubectl --context "$hub_ctx" -n external-secrets create secret generic vault-platform-token \
  --from-literal=token="$platform_token" \
  --dry-run=client -o yaml | kubectl --context "$hub_ctx" apply -f - >/dev/null

log "applying the platform ClusterSecretStore"
kubectl --context "$hub_ctx" apply -f "$REPO_ROOT/secrets/eso/platform-secret-store.yaml" >/dev/null

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

# Both Secrets are built by ESO from Vault rather than created here, so the
# only copy of the key lives in Vault.
log "syncing the GitHub App credential out of Vault"
kubectl --context "$hub_ctx" apply -f "$REPO_ROOT/promoter/github-app-externalsecrets.yaml" >/dev/null

for pair in "promoter-system github-app" "$ARGOCD_NAMESPACE repo-argocd-demo"; do
  set -- $pair
  for i in $(seq 1 30); do
    [[ "$(kubectl --context "$hub_ctx" -n "$1" get externalsecret "$2" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] && break
    sleep 2
  done
  kubectl --context "$hub_ctx" -n "$1" get secret "$2" >/dev/null 2>&1 \
    || die "ESO did not produce $1/$2 -- check 'kubectl -n $1 describe externalsecret $2'"
  log "  $1/$2 synced"
done

# --- promoter resources ---------------------------------------------------

log "applying ScmProvider and GitRepository"
GITHUB_APP_ID="$GITHUB_APP_ID" GITHUB_INSTALLATION_ID="$GITHUB_INSTALLATION_ID" \
  envsubst < "$REPO_ROOT/promoter/scm.yaml" \
  | kubectl --context "$hub_ctx" apply -f - >/dev/null

log "applying PromotionStrategy and gates"
kubectl --context "$hub_ctx" apply -f "$REPO_ROOT/promoter/promotion-strategy.yaml" >/dev/null
kubectl --context "$hub_ctx" apply -f "$REPO_ROOT/promoter/commit-statuses.yaml" >/dev/null

# The branches have to exist and carry manifests before the Applications
# point at them.
log "ensuring environment branches exist"
"$(dirname "${BASH_SOURCE[0]}")/promoter-branches.sh"

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
