#!/usr/bin/env bash
# Wire Vault to the clusters: seed the KV engine, install External Secrets
# Operator on the hub, and give the hub a narrow identity on each spoke so it
# can push the resulting Secret into the app namespaces.
#
# Only the hub ever holds a Vault credential. The spokes receive secrets by
# PushSecret and never talk to Vault.
#
# Idempotent. Everything declarative lives in secrets/; what is generated here
# is credentials, which is exactly what must not be in git.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools
command -v helm >/dev/null 2>&1 || die "helm is required -- run setup-tools.sh"

hub_ctx="kind-$HUB"
kubectl --context "$hub_ctx" -n "$ARGOCD_NAMESPACE" get deploy argocd-server >/dev/null 2>&1 \
  || die "Argo CD is not installed -- run install-argocd.sh"
[[ -f "$VAULT_SECRETS_FILE" ]] || die "vault is not initialised -- run vault-up.sh"

# -i so `vault policy write eso -` can read the policy file from stdin.
vault_exec() {
  podman exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$root_token" \
    "$VAULT_CONTAINER" vault "$@"
}

root_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root_token"])' \
  "$VAULT_SECRETS_FILE")"

podman inspect "$VAULT_CONTAINER" --format '{{.State.Status}}' 2>/dev/null | grep -qx running \
  || die "vault container is not running -- run vault-up.sh"

# --- vault: engine, secret, policy, token ---------------------------------

if vault_exec secrets list -format=json | grep -q '"demo/"'; then
  log "kv-v2 engine 'demo' already enabled"
else
  log "enabling kv-v2 engine at demo/"
  vault_exec secrets enable -path=demo kv-v2 >/dev/null
fi

log "writing demo/whoami"
vault_exec kv put demo/whoami greeting="$DEMO_SECRET_VALUE" >/dev/null

log "applying ESO read policy"
vault_exec policy write eso - < "$REPO_ROOT/secrets/vault/eso-policy.hcl" >/dev/null

# A fresh token each run keeps this re-runnable. Periodic so it renews rather
# than expiring out from under the operator.
log "minting a Vault token for ESO"
eso_token="$(vault_exec token create -policy=eso -period=24h -format=json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"])')"

# --- external secrets operator on the hub ---------------------------------

log "installing External Secrets Operator ($ESO_VERSION) on '$HUB'"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null 2>&1
helm upgrade --install external-secrets external-secrets/external-secrets \
  --kube-context "$hub_ctx" \
  --namespace external-secrets --create-namespace \
  --version "$ESO_VERSION" \
  --set installCRDs=true \
  --wait --timeout 5m >/dev/null

log "storing the Vault token on the hub"
kubectl --context "$hub_ctx" -n external-secrets create secret generic vault-token \
  --from-literal=token="$eso_token" \
  --dry-run=client -o yaml | kubectl --context "$hub_ctx" apply -f - >/dev/null

log "applying ClusterSecretStore"
kubectl --context "$hub_ctx" apply -f "$REPO_ROOT/secrets/eso/cluster-secret-store.yaml" >/dev/null

# --- spoke access ---------------------------------------------------------

for cluster in "${SPOKES[@]}"; do
  spoke_ctx="kind-$cluster"
  ns="demo-$cluster"

  kubectl --context "$spoke_ctx" get namespace "$ns" >/dev/null 2>&1 \
    || die "namespace '$ns' does not exist on '$cluster' -- run bootstrap-apps.sh first"

  log "granting the hub secret-write access in $cluster/$ns"
  kubectl --context "$spoke_ctx" -n "$ns" apply -f \
    "$REPO_ROOT/secrets/spoke-access/eso-pusher-rbac.yaml" >/dev/null

  # The ClusterRoleBinding cannot live in git with the others: a cluster-scoped
  # binding has to name the subject's namespace, which differs per spoke.
  kubectl --context "$spoke_ctx" apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: eso-pusher-selfsubjectrulesreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: eso-pusher-selfsubjectrulesreview
subjects:
  - kind: ServiceAccount
    name: eso-pusher
    namespace: $ns
EOF

  for i in $(seq 1 30); do
    token="$(kubectl --context "$spoke_ctx" -n "$ns" get secret eso-pusher-token \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    [[ -n "$token" ]] && break
    sleep 1
  done
  [[ -n "${token:-}" ]] || die "token for eso-pusher on '$cluster' was never issued"

  ca="$(kubectl --context "$spoke_ctx" -n "$ns" get secret eso-pusher-token \
    -o jsonpath='{.data.ca\.crt}')"
  server="$(kind get kubeconfig --name "$cluster" --internal 2>/dev/null \
    | grep -m1 'server:' | awk '{print $2}')"

  log "creating SecretStore 'spoke-$cluster' on the hub"
  # Lives in the hub's app namespace because that is where the PushSecret and
  # its source Secret are.
  kubectl --context "$hub_ctx" -n "demo-$HUB" create secret generic "spoke-$cluster-token" \
    --from-literal=token="$token" \
    --dry-run=client -o yaml | kubectl --context "$hub_ctx" apply -f - >/dev/null

  kubectl --context "$hub_ctx" apply -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: spoke-$cluster
  namespace: demo-$HUB
spec:
  provider:
    kubernetes:
      remoteNamespace: $ns
      server:
        url: $server
        caBundle: $ca
      auth:
        token:
          bearerToken:
            name: spoke-$cluster-token
            key: token
EOF
done

echo
log "secrets wiring complete"
printf '  vault engine   demo/ (kv-v2)\n'
printf '  secret         demo/whoami  greeting=%s\n' "$DEMO_SECRET_VALUE"
printf '  hub            ExternalSecret pulls into demo-%s\n' "$HUB"
printf '  spokes         PushSecret replicates into %s\n' "${SPOKES[*]/#/demo-}"
echo
log "Argo CD syncs the ExternalSecret and PushSecret from git; force one with:"
log "  argocd app sync whoami-stage"
