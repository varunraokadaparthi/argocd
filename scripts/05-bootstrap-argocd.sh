#!/usr/bin/env bash
set -euo pipefail

echo "=== Bootstrapping ArgoCD configuration ==="

kubectl config use-context k3d-hub

GIT_REPO_URL="${GIT_REPO_URL:?ERROR: Set GIT_REPO_URL env var first (e.g. export GIT_REPO_URL=git@github.com:varunraokadaparthi/argocd.git)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# --- Step 1: Register the Git repository with ArgoCD ---
echo "[1/3] Registering Git repository..."

# For public repos, no credentials needed
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: repo-argocd
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: "${GIT_REPO_URL}"
YAML

echo "  -> Repository registered: ${GIT_REPO_URL}"

# --- Step 2: Apply AppProjects ---
echo ""
echo "[2/3] Applying AppProjects..."
kubectl apply -f "${REPO_ROOT}/argocd-config/projects/"
echo "  -> AppProjects applied"

# --- Step 3: Apply ApplicationSets ---
echo ""
echo "[3/3] Applying ApplicationSets..."
kubectl apply -f "${REPO_ROOT}/argocd-config/applicationsets/"
echo "  -> ApplicationSets applied"

echo ""
echo "=========================================="
echo "  Bootstrap complete!"
echo "=========================================="
echo ""
echo "  ArgoCD will now auto-sync applications"
echo "  to all registered clusters."
echo ""
echo "  Check status:"
echo "    argocd app list"
echo "    kubectl -n argocd get applications"
echo "    kubectl -n argocd get applicationsets"
echo ""
echo "  Open the UI: http://localhost:8080"
echo ""
