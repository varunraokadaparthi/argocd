#!/usr/bin/env bash
# Tear down the stage/int/prod clusters. Leaves other kind clusters untouched.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools

for cluster in "${CLUSTERS[@]}"; do
  if ! cluster_exists "$cluster"; then
    log "cluster '$cluster' does not exist, skipping"
    continue
  fi
  log "deleting cluster '$cluster'"
  kind delete cluster --name "$cluster"
done

log "done; run 'podman system prune' to reclaim image and volume space"
