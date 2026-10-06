#!/usr/bin/env bash
# Install Argo CD on the hub cluster from argocd/install/.
# Safe to re-run: apply is idempotent and doubles as an upgrade once the
# pinned version in argocd/install/kustomization.yaml changes.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools
cluster_exists "$HUB" || die "hub cluster '$HUB' does not exist -- run create-clusters.sh"

ctx="kind-$HUB"

# Ingress controller first, so the Argo CD Ingress has something to serve it.
log "installing Traefik $TRAEFIK_CHART_VERSION"
helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
helm --kube-context "$ctx" upgrade --install traefik traefik/traefik \
  --version "$TRAEFIK_CHART_VERSION" --namespace traefik --create-namespace \
  --values "$ARGOCD_DIR/traefik/values.yaml" --wait --timeout 5m

log "creating namespace '$ARGOCD_NAMESPACE' on '$HUB'"
kubectl --context "$ctx" create namespace "$ARGOCD_NAMESPACE" \
  --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null

# Server-side apply is required, not a preference: the Argo CD CRDs exceed the
# 262144-byte limit on the last-applied-configuration annotation that
# client-side apply writes.
log "applying argocd/install (server-side)"
kubectl --context "$ctx" apply -k "$ARGOCD_DIR/install" --server-side --force-conflicts

log "waiting for Argo CD to come up"
for deploy in argocd-repo-server argocd-server argocd-applicationset-controller argocd-commit-server; do
  if kubectl --context "$ctx" -n "$ARGOCD_NAMESPACE" get deploy "$deploy" >/dev/null 2>&1; then
    kubectl --context "$ctx" -n "$ARGOCD_NAMESPACE" \
      rollout status "deploy/$deploy" --timeout=300s
  else
    warn "deployment '$deploy' not present in this manifest"
  fi
done
kubectl --context "$ctx" -n "$ARGOCD_NAMESPACE" \
  rollout status statefulset/argocd-application-controller --timeout=300s

# The hydrator is what the promotion work depends on; fail loudly now rather
# than confusingly later if the wrong manifest was pinned.
if [[ "$(kubectl --context "$ctx" -n "$ARGOCD_NAMESPACE" get cm argocd-cmd-params-cm \
        -o jsonpath='{.data.hydrator\.enabled}' 2>/dev/null)" == "true" ]]; then
  log "source hydrator enabled"
else
  warn "source hydrator NOT enabled -- argocd/install must pin install-with-hydrator.yaml"
fi

echo
log "Argo CD installed"
printf '  version   %s\n' \
  "$(kubectl --context "$ctx" -n "$ARGOCD_NAMESPACE" get deploy argocd-server \
     -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')"
printf '  password  %s\n' \
  "$(kubectl --context "$ctx" -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '(not found)')"
echo
log "UI: https://localhost:8443 as 'admin' (self-signed cert)"
log "next: ./scripts/register-clusters.sh"
