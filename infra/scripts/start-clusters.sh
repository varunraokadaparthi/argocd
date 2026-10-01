#!/usr/bin/env bash
# Restart the stage/int/prod clusters after stop-clusters.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools

for cluster in "${CLUSTERS[@]}"; do
  node="$cluster-control-plane"
  state="$(podman inspect "$node" --format '{{.State.Status}}' 2>/dev/null || echo absent)"
  case "$state" in
    running) log "cluster '$cluster' is already running" ;;
    absent)  die "cluster '$cluster' does not exist -- run create-clusters.sh" ;;
    *)       log "starting '$cluster'"; podman start "$node" >/dev/null ;;
  esac
done

# A restarted API server accepts connections before RBAC has finished
# bootstrapping, so early calls come back Forbidden. `kubectl wait` treats
# that as fatal rather than retrying, hence polling instead.
wait_ready() {
  local cluster="$1" i
  for i in $(seq 1 60); do
    if [[ "$(kubectl --context "kind-$cluster" get nodes --no-headers 2>/dev/null \
             | awk '{print $2}')" == "Ready" ]]; then
      return 0
    fi
    sleep 3
  done
  return 1
}

log "waiting for nodes to become Ready"
for cluster in "${CLUSTERS[@]}"; do
  wait_ready "$cluster" || warn "'$cluster' did not become Ready in time"
done

# Node containers usually get new addresses on the podman network after a
# restart. Registration stores hostnames rather than IPs precisely so this
# does not matter, but it is worth confirming rather than assuming.
if kubectl --context "kind-$HUB" -n "$ARGOCD_NAMESPACE" get deploy argocd-server >/dev/null 2>&1; then
  echo
  log "hub is up; Argo CD state survived"
  kubectl --context "kind-$HUB" -n "$ARGOCD_NAMESPACE" get applications.argoproj.io \
    -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
    --no-headers 2>/dev/null | sed 's/^/  /'
fi
