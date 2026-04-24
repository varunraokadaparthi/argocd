#!/usr/bin/env bash
set -euo pipefail

echo "=== Creating k3d clusters ==="

# Hub cluster (prod) — exposes port 8080 for ArgoCD UI
echo "[1/3] Creating hub cluster (prod)..."
k3d cluster create hub \
    --servers 1 \
    --agents 1 \
    --port "8080:80@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0" \
    --wait

# Int cluster (spoke)
echo "[2/3] Creating int cluster..."
k3d cluster create int \
    --servers 1 \
    --agents 1 \
    --k3s-arg "--disable=traefik@server:0" \
    --wait

# Stage cluster (spoke)
echo "[3/3] Creating stage cluster..."
k3d cluster create stage \
    --servers 1 \
    --agents 1 \
    --k3s-arg "--disable=traefik@server:0" \
    --wait

echo ""
echo "=== Clusters created ==="
echo ""
kubectl config get-contexts
echo ""
echo "Hub context:   k3d-hub"
echo "Int context:   k3d-int"
echo "Stage context: k3d-stage"
