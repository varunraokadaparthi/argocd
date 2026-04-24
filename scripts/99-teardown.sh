#!/usr/bin/env bash
set -euo pipefail

echo "=== Tearing down ArgoCD multi-cluster setup ==="
echo ""

read -p "This will delete ALL k3d clusters (hub, int, stage). Continue? [y/N] " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

for cluster in hub int stage; do
    if k3d cluster list 2>/dev/null | grep -q "${cluster}"; then
        echo "Deleting cluster: ${cluster}..."
        k3d cluster delete "${cluster}"
    else
        echo "Cluster ${cluster} not found, skipping."
    fi
done

echo ""
echo "=== Teardown complete ==="
echo ""
echo "Remaining k3d clusters:"
k3d cluster list 2>/dev/null || echo "  (none)"
