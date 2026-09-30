#!/usr/bin/env bash
# Shared settings for the infra scripts. Source this, do not execute it.

# kind still treats podman as experimental and defaults to docker, so every
# kind invocation needs this. Exported here rather than relying on the shell.
export KIND_EXPERIMENTAL_PROVIDER=podman

# --- pinned versions ------------------------------------------------------
# kubectl is pinned to the node image's Kubernetes version. Keep them in step:
# a skew wider than one minor version is unsupported and fails in odd ways.
KIND_VERSION="${KIND_VERSION:-v0.31.0}"
K8S_VERSION="${K8S_VERSION:-v1.35.0}"
HELM_VERSION="${HELM_VERSION:-v3.20.2}"

# Must be 3.5.x: the source hydrator the promotion work depends on is beta as
# of Argo CD 3.5.0 and absent before it. Keep the CLI and server in step.
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.3}"

# Multi-arch manifest list covering linux/amd64 and linux/arm64.
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:${K8S_VERSION}@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f}"

# Where setup-tools.sh installs CLI binaries. No sudo, same on every platform.
TOOLS_BIN="${TOOLS_BIN:-$HOME/.local/bin}"

# macOS only: the Linux VM that actually runs the containers.
PODMAN_MACHINE="${PODMAN_MACHINE:-podman-machine-default}"
PODMAN_MACHINE_CPUS="${PODMAN_MACHINE_CPUS:-6}"
PODMAN_MACHINE_MEMORY="${PODMAN_MACHINE_MEMORY:-12288}"
PODMAN_MACHINE_DISK="${PODMAN_MACHINE_DISK:-60}"

# --- topology -------------------------------------------------------------
HUB="stage"
SPOKES=(int prod)
CLUSTERS=("$HUB" "${SPOKES[@]}")

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$INFRA_DIR/.." && pwd)"
CLUSTER_CONFIG_DIR="$INFRA_DIR/clusters"
ARGOCD_DIR="$REPO_ROOT/argocd"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# --- platform detection ---------------------------------------------------
# Sets OS (linux|darwin) and ARCH (amd64|arm64) using the naming that kind,
# kubectl, helm and argocd all happen to share in their release assets.
detect_platform() {
  case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=darwin ;;
    *)      die "unsupported OS: $(uname -s)" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *)             die "unsupported architecture: $(uname -m)" ;;
  esac

  export OS ARCH
}

# --- preflight ------------------------------------------------------------
require_tools() {
  detect_platform

  local missing=()
  for tool in podman kind kubectl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [[ ${#missing[@]} -eq 0 ]] \
    || die "missing required tools: ${missing[*]} -- run ./scripts/setup-tools.sh"

  if [[ "$OS" == "darwin" ]]; then
    require_podman_machine
  else
    require_cgroup_delegation
  fi

  podman info >/dev/null 2>&1 || die "podman is not usable; try 'podman info'"
}

# macOS runs containers inside a Linux VM, so the machine has to be up and
# needs enough headroom for three clusters' worth of control planes.
require_podman_machine() {
  podman machine inspect "$PODMAN_MACHINE" >/dev/null 2>&1 \
    || die "no podman machine '$PODMAN_MACHINE' -- run ./scripts/setup-tools.sh"

  local state
  state="$(podman machine inspect "$PODMAN_MACHINE" --format '{{.State}}' 2>/dev/null || true)"
  [[ "$state" == "running" ]] \
    || die "podman machine '$PODMAN_MACHINE' is $state -- run 'podman machine start $PODMAN_MACHINE'"
}

# Rootless kind needs cgroup v2 with controllers delegated to the user slice,
# otherwise the kubelet fails to start inside the node container.
require_cgroup_delegation() {
  [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]] \
    || die "cgroup v2 is required for rootless kind"

  # Rootful podman is not subject to user-slice delegation.
  [[ "$(id -u)" -eq 0 ]] && return 0

  local controllers="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
  [[ -r "$controllers" ]] || return 0

  for c in cpu memory pids; do
    grep -qw "$c" "$controllers" \
      || warn "cgroup controller '$c' is not delegated; see infra/README.md"
  done
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$1"
}
