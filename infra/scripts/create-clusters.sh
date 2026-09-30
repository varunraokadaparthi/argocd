#!/usr/bin/env bash
# Create the stage hub and the int/prod spoke clusters on podman.
# Safe to re-run: existing clusters are left alone.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools

for cluster in "${CLUSTERS[@]}"; do
  if cluster_exists "$cluster"; then
    log "cluster '$cluster' already exists, skipping"
    continue
  fi

  log "creating cluster '$cluster'"
  kind create cluster \
    --name "$cluster" \
    --config "$KIND_CONFIG_DIR/$cluster.yaml" \
    --image "$KIND_NODE_IMAGE" \
    --wait 120s
done

# ingress-nginx's kind manifest schedules onto this label. Applied after
# creation rather than via kubeadmConfigPatches so the config files stay
# independent of the kubeadm API version the node image ships.
log "labelling hub node for ingress"
kubectl --context "kind-$HUB" label node "$HUB-control-plane" \
  ingress-ready=true --overwrite >/dev/null

log "waiting for nodes to become Ready"
for cluster in "${CLUSTERS[@]}"; do
  kubectl --context "kind-$cluster" wait --for=condition=Ready nodes --all --timeout=120s >/dev/null
done

echo
log "clusters ready"
printf '  %-8s %-22s %s\n' ROLE CONTEXT 'IN-CLUSTER API ENDPOINT'
for cluster in "${CLUSTERS[@]}"; do
  role="spoke"
  [[ "$cluster" == "$HUB" ]] && role="hub"
  # The address the hub's ArgoCD must use to reach a spoke. The default
  # kubeconfig points at 127.0.0.1, which resolves to the pod itself.
  internal="$(kind get kubeconfig --name "$cluster" --internal 2>/dev/null \
    | grep -m1 'server:' | awk '{print $2}')"
  printf '  %-8s %-22s %s\n' "$role" "kind-$cluster" "$internal"
done
echo
log "ArgoCD UI will be reachable at http://localhost:8080 once an ingress controller is installed on '$HUB'"
