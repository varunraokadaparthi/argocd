#!/usr/bin/env bash
# Register the spoke clusters with the hub's Argo CD.
#
# `argocd cluster add` is not used here. It connects to the spoke to create the
# ServiceAccount, and the address the hub must store -- the spoke's in-network
# name, e.g. https://int-control-plane:6443 -- does not resolve from the host.
# Instead the RBAC half is applied from git and the credential half is built
# here from the resulting token.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools

hub_ctx="kind-$HUB"
kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" get deploy argocd-server >/dev/null 2>&1 \
  || die "Argo CD is not installed on '$HUB' -- run install-argocd.sh"

# Waits for the token controller to populate the requested Secret.
wait_for_token() {
  local ctx="$1" i
  for i in $(seq 1 30); do
    if [[ -n "$(kubectl --context "$ctx" -n kube-system get secret argocd-manager-token \
                 -o jsonpath='{.data.token}' 2>/dev/null)" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

for cluster in "${SPOKES[@]}"; do
  cluster_exists "$cluster" || die "spoke cluster '$cluster' does not exist"
  spoke_ctx="kind-$cluster"

  log "granting the hub an identity on '$cluster'"
  kubectl --context "$spoke_ctx" apply -f \
    "$ARGOCD_DIR/cluster-registration/argocd-manager-rbac.yaml" >/dev/null

  wait_for_token "$spoke_ctx" || die "token for argocd-manager on '$cluster' was never issued"

  # Read the credential out of the spoke. This is the part that cannot live in
  # git, which is why it is assembled at run time rather than committed.
  token="$(kubectl --context "$spoke_ctx" -n kube-system get secret argocd-manager-token \
    -o jsonpath='{.data.token}' | base64 -d)"
  ca="$(kubectl --context "$spoke_ctx" -n kube-system get secret argocd-manager-token \
    -o jsonpath='{.data.ca\.crt}')"

  # The in-network address. The kubeconfig kind writes says 127.0.0.1, which
  # from inside an Argo CD pod would mean the pod itself.
  server="$(kind get kubeconfig --name "$cluster" --internal 2>/dev/null \
    | grep -m1 'server:' | awk '{print $2}')"
  [[ -n "$server" ]] || die "could not determine internal API address for '$cluster'"

  log "registering '$cluster' at $server"
  kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$cluster
  namespace: $ARGOCD_NAMESPACE
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: $cluster
  server: $server
  config: |
    {
      "bearerToken": "$token",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "$ca"
      }
    }
EOF
done

# Prove the address and CA in each Secret actually work from inside the hub,
# rather than just that a Secret exists. A wrong address otherwise surfaces
# much later as an unexplained sync failure.
#
# This runs a throwaway pod in the Argo CD namespace instead of exec'ing into
# a component: the Argo CD images ship no shell tooling. Any HTTP response
# proves DNS, routing and TLS all worked -- an unauthenticated request is
# expected to be rejected, and 401/403 is a pass.
echo
log "verifying each registered address from inside the hub"
for cluster in "${SPOKES[@]}"; do
  server="$(kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" \
    get secret "cluster-$cluster" -o jsonpath='{.data.server}' | base64 -d)"
  ca="$(kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" \
    get secret "cluster-$cluster" -o jsonpath='{.data.config}' | base64 -d \
    | grep -o '"caData": *"[^"]*"' | cut -d'"' -f4)"

  code="$(kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" \
    run "reg-check-$cluster" --rm -i --restart=Never --quiet \
    --image=docker.io/curlimages/curl:latest --timeout=90s \
    --env="CA=$ca" --env="SERVER=$server" -- \
    sh -c 'echo "$CA" | base64 -d > /tmp/ca.crt
           curl -s --cacert /tmp/ca.crt --max-time 10 \
                -o /dev/null -w "%{http_code}" "$SERVER/version"' 2>/dev/null || true)"

  case "$code" in
    200|401|403) printf '  %-6s %-34s ok (HTTP %s, TLS verified)\n' "$cluster" "$server" "$code" ;;
    *)           warn "$cluster at $server unreachable from the hub (got '${code:-no response}')" ;;
  esac
done

echo
log "registered clusters"
# Secret fields are base64; decode so the output is readable.
kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" get secrets \
  -l argocd.argoproj.io/secret-type=cluster \
  -o jsonpath='{range .items[*]}{.data.name}{" "}{.data.server}{"\n"}{end}' 2>/dev/null \
  | while read -r n s; do
      printf '  %-6s %s\n' "$(base64 -d <<<"$n")" "$(base64 -d <<<"$s")"
    done
echo
log "next: ./scripts/bootstrap-apps.sh"
