#!/usr/bin/env bash
# Apply the AppProject and ApplicationSet to the hub.
#
# This is the last imperative step. Everything it applies is config from git,
# and from here on Argo CD reconciles from the repo rather than from anything
# run locally.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools

hub_ctx="kind-$HUB"
kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" get deploy argocd-server >/dev/null 2>&1 \
  || die "Argo CD is not installed on '$HUB' -- run install-argocd.sh"

for cluster in "${SPOKES[@]}"; do
  kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" \
    get secret "cluster-$cluster" >/dev/null 2>&1 \
    || die "spoke '$cluster' is not registered -- run register-clusters.sh"
done

# Argo CD fetches from the remote, not from this working tree, so unpushed
# commits produce Applications that generate fine and then fail to sync with a
# path-not-found error.
branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
if ! git -C "$REPO_ROOT" diff --quiet HEAD -- "$REPO_ROOT/apps" "$ARGOCD_DIR"; then
  warn "apps/ or argocd/ has uncommitted changes; Argo CD will not see them"
fi
if [[ -n "$(git -C "$REPO_ROOT" log --oneline "origin/$branch..$branch" 2>/dev/null)" ]]; then
  warn "branch '$branch' is ahead of origin; push before expecting a sync"
fi

# The project must exist first: an Application naming a missing project is
# rejected by the admission logic.
log "applying AppProject"
kubectl --context "$hub_ctx" apply -f "$ARGOCD_DIR/projects/demo.yaml"

log "applying ApplicationSet"
kubectl --context "$hub_ctx" apply -f "$ARGOCD_DIR/applicationsets/whoami.yaml"

log "waiting for Applications to be generated"
for i in $(seq 1 30); do
  count="$(kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" \
    get applications.argoproj.io --no-headers 2>/dev/null | wc -l)"
  [[ "$count" -ge 3 ]] && break
  sleep 2
done

echo
log "applications"
kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,CLUSTER:.spec.destination.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
  2>/dev/null | sed 's/^/  /'
echo
log "sync is polled every 3 minutes by default; 'argocd app sync <name>' to force one"
