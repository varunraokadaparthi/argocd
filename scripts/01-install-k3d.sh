#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing k3d ==="

if command -v k3d &>/dev/null; then
    echo "k3d already installed: $(k3d version)"
    exit 0
fi

curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

echo ""
echo "k3d installed: $(k3d version)"
