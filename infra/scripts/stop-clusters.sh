#!/usr/bin/env bash
# Stop the stage/int/prod clusters without destroying them.
#
# kind has no stop command, so this acts on the node containers directly.
# Everything survives: etcd state, Argo CD, the registered cluster Secrets.
# Use start-clusters.sh to bring them back, or delete-clusters.sh to discard.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools

for cluster in "${CLUSTERS[@]}"; do
  node="$cluster-control-plane"
  state="$(podman inspect "$node" --format '{{.State.Status}}' 2>/dev/null || echo absent)"
  case "$state" in
    # The node image does not complete a shutdown on podman's stop signal
    # (SIGRTMIN+3), so every stop ends in SIGKILL regardless of the timeout --
    # raising it to 60s only wasted a minute per cluster. A short timeout is
    # honest about that. etcd recovers from this: a stop/start cycle was
    # verified to preserve cluster state, Argo CD and the registered spokes.
    running) log "stopping '$cluster'"; podman stop --time 5 "$node" >/dev/null 2>&1 ;;
    absent)  log "cluster '$cluster' does not exist, skipping" ;;
    *)       log "cluster '$cluster' is already $state, skipping" ;;
  esac
done

echo
log "stopped; disk is still in use -- delete-clusters.sh to reclaim it"
log "restart with ./scripts/start-clusters.sh"
