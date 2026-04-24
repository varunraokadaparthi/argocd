#!/usr/bin/env bash
set -euo pipefail

echo "=== Registering spoke clusters with ArgoCD ==="

kubectl config use-context k3d-hub

GIT_REPO_URL="${GIT_REPO_URL:?ERROR: Set GIT_REPO_URL env var first (e.g. export GIT_REPO_URL=git@github.com:varunraokadaparthi/argocd.git)}"

# --- Helper: get cluster connection details from k3d ---
get_cluster_server() {
    local cluster_name="$1"
    # Get the internal Docker network IP of the k3s server
    local container_name="k3d-${cluster_name}-server-0"
    local ip
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_name}")
    echo "https://${ip}:6443"
}

get_cluster_ca() {
    local context="k3d-$1"
    kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${context}\")].cluster.certificate-authority-data}"
}

get_cluster_token() {
    local context="k3d-$1"
    kubectl --context "${context}" create serviceaccount argocd-manager -n kube-system --dry-run=client -o yaml | kubectl --context "${context}" apply -f -
    kubectl --context "${context}" create clusterrolebinding argocd-manager-role --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager --dry-run=client -o yaml | kubectl --context "${context}" apply -f -

    # Create a long-lived token for the service account
    local secret_name="argocd-manager-token"
    cat <<YAML | kubectl --context "${context}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
YAML

    # Wait for token to be populated
    for i in $(seq 1 10); do
        local token
        token=$(kubectl --context "${context}" -n kube-system get secret "${secret_name}" -o jsonpath='{.data.token}' 2>/dev/null || true)
        if [[ -n "${token}" ]]; then
            echo "${token}" | base64 -d
            return
        fi
        sleep 1
    done
    echo "ERROR: Failed to get token for cluster $1" >&2
    exit 1
}

# --- Register each spoke cluster ---
register_cluster() {
    local name="$1"
    local env_label="$2"

    echo ""
    echo "Registering cluster: ${name} (env=${env_label})"

    local server ca_data bearer_token
    server=$(get_cluster_server "${name}")
    ca_data=$(get_cluster_ca "${name}")
    bearer_token=$(get_cluster_token "${name}")

    cat <<YAML | kubectl --context k3d-hub apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${name}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: "${env_label}"
  annotations:
    git_repo_url: "${GIT_REPO_URL}"
type: Opaque
stringData:
  name: "${name}"
  server: "${server}"
  config: |
    {
      "bearerToken": "${bearer_token}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${ca_data}"
      }
    }
YAML

    echo "  -> Registered ${name} at ${server}"
}

register_cluster "int" "int"
register_cluster "stage" "stage"

# --- Label the in-cluster (hub) destination as prod ---
echo ""
echo "Labeling in-cluster (hub) as env=prod..."

# The in-cluster secret is auto-created by ArgoCD — we patch it with labels
# If it doesn't exist yet, create it
cat <<YAML | kubectl --context k3d-hub apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cluster-hub-in-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: "prod"
  annotations:
    git_repo_url: "${GIT_REPO_URL}"
type: Opaque
stringData:
  name: "hub"
  server: "https://kubernetes.default.svc"
  config: |
    {
      "tlsClientConfig": {
        "insecure": false
      }
    }
YAML

echo ""
echo "=== Cluster registration complete ==="
echo ""
echo "Verify with: argocd cluster list"
