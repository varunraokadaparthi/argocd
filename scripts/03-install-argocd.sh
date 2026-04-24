#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing ArgoCD on hub cluster ==="

kubectl config use-context k3d-hub

# Add Argo Helm repo
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

# Install ArgoCD
helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --set 'server.service.type=LoadBalancer' \
    --set 'server.insecure=true' \
    --set 'configs.params."server\.insecure"=true' \
    --set 'controller.args.appResyncPeriod=30' \
    --wait \
    --timeout 5m

echo ""
echo "Waiting for ArgoCD server to be ready..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=120s

# Get the initial admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "=========================================="
echo "  ArgoCD installed successfully!"
echo "=========================================="
echo ""
echo "  UI:       http://localhost:8080"
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASSWORD}"
echo ""
echo "  CLI login:"
echo "    argocd login localhost:8080 --insecure --username admin --password '${ARGOCD_PASSWORD}'"
echo ""
