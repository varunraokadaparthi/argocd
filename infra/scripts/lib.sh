#!/usr/bin/env bash
# Shared settings for the infra scripts. Source this, do not execute it.

# kind still treats podman as experimental and defaults to docker, so every
# kind invocation needs this. Exported here rather than relying on the shell.
export KIND_EXPERIMENTAL_PROVIDER=podman

# Pinned for reproducibility. Matches the default of kind v0.31.0.
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f}"

HUB="stage"
SPOKES=(int prod)
CLUSTERS=("$HUB" "${SPOKES[@]}")

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND_CONFIG_DIR="$INFRA_DIR/kind"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# Fail early with an actionable message rather than deep inside kind.
require_tools() {
  local missing=()
  for tool in podman kind kubectl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required tools: ${missing[*]}"

  podman info >/dev/null 2>&1 || die "podman is not usable; try 'podman info'"

  # Rootless kind needs cgroup v2 with cpu/memory/pids delegated to the user
  # slice, otherwise kubelet fails to start with obscure cgroup errors.
  [[ "$(stat -fc %T /sys/fs/cgroup)" == "cgroup2fs" ]] \
    || die "cgroup v2 is required for rootless kind"

  local controllers="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
  if [[ -r "$controllers" ]]; then
    for c in cpu memory pids; do
      grep -qw "$c" "$controllers" \
        || warn "cgroup controller '$c' is not delegated; see infra/README.md"
    done
  fi
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$1"
}
