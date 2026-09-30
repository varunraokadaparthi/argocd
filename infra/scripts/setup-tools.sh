#!/usr/bin/env bash
# Install everything needed to run the kind + podman clusters.
# Supports macOS (Apple Silicon or Intel) and Linux (amd64 or arm64).
#
# podman comes from the platform package manager because it needs system
# integration. The CLI tools are pinned binaries dropped in $TOOLS_BIN so that
# every machine ends up on the same versions without sudo.
#
#   ./setup-tools.sh            install what is missing
#   ./setup-tools.sh --force    reinstall even if already present
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

detect_platform

# One scratch directory for the whole run. A per-function RETURN trap would
# outlive its own local and then trip over set -u on the next return.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# --- helpers --------------------------------------------------------------

# Prints the installed version of $1, or nothing if it is not installed.
# Each tool needs its own probe: a bare `kubectl version` reports the version
# of whatever cluster it is pointed at, not the client.
installed_version() {
  command -v "$1" >/dev/null 2>&1 || return 0
  case "$1" in
    kind)    kind version 2>/dev/null | awk '{print $2}' ;;
    kubectl) kubectl version --client -o json 2>/dev/null \
               | grep -m1 gitVersion | cut -d'"' -f4 ;;
    helm)    helm version --template '{{.Version}}' 2>/dev/null ;;
    argocd)  argocd version --client --short 2>/dev/null \
               | awk '{print $2}' | cut -d+ -f1 ;;
    podman)  podman --version 2>/dev/null | awk '{print $3}' ;;
  esac
}

# True when the tool is absent, --force was passed, or the installed version
# is not exactly what we pin. $2 is the wanted version, optional.
needs_install() {
  local tool="$1" want="${2:-}"
  $FORCE && return 0
  command -v "$tool" >/dev/null 2>&1 || return 0
  [[ -z "$want" ]] && return 1
  [[ "$(installed_version "$tool")" == "$want" ]] && return 1
  return 0
}

fetch() {
  local url="$1" dest="$2"
  curl --fail --silent --show-error --location --retry 3 "$url" --output "$dest"
}

install_binary() {
  local name="$1" url="$2"
  log "installing $name"
  fetch "$url" "$SCRATCH/$name"
  install -m 0755 "$SCRATCH/$name" "$TOOLS_BIN/$name"
}

# --- podman ---------------------------------------------------------------

install_podman() {
  if command -v podman >/dev/null 2>&1 && ! $FORCE; then
    log "podman already installed ($(podman --version))"
    return
  fi

  log "installing podman"
  if [[ "$OS" == "darwin" ]]; then
    command -v brew >/dev/null 2>&1 \
      || die "Homebrew is required on macOS: https://brew.sh"
    brew install podman
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y podman
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y podman
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm podman
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y podman
  else
    die "no supported package manager found; install podman manually"
  fi
}

# On macOS, containers run inside a Linux VM that has to be created first.
# Three control planes need more than the default machine gets.
setup_podman_machine() {
  [[ "$OS" == "darwin" ]] || return 0

  if ! podman machine inspect "$PODMAN_MACHINE" >/dev/null 2>&1; then
    log "creating podman machine '$PODMAN_MACHINE' (${PODMAN_MACHINE_CPUS} cpu, ${PODMAN_MACHINE_MEMORY}MB, ${PODMAN_MACHINE_DISK}GB)"
    # Rootful: kind needs privileges inside the VM that the rootless machine
    # does not grant, and the VM is already an isolation boundary.
    podman machine init "$PODMAN_MACHINE" \
      --cpus "$PODMAN_MACHINE_CPUS" \
      --memory "$PODMAN_MACHINE_MEMORY" \
      --disk-size "$PODMAN_MACHINE_DISK" \
      --rootful \
      --now
    return
  fi

  log "podman machine '$PODMAN_MACHINE' already exists"
  local state
  state="$(podman machine inspect "$PODMAN_MACHINE" --format '{{.State}}')"
  if [[ "$state" != "running" ]]; then
    log "starting podman machine"
    podman machine start "$PODMAN_MACHINE"
  fi
}

# --- cli tools ------------------------------------------------------------

install_kind() {
  needs_install kind "$KIND_VERSION" || { log "kind $KIND_VERSION already installed"; return; }
  install_binary kind \
    "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${OS}-${ARCH}"
}

install_kubectl() {
  needs_install kubectl "$K8S_VERSION" || { log "kubectl $K8S_VERSION already installed"; return; }
  install_binary kubectl \
    "https://dl.k8s.io/release/${K8S_VERSION}/bin/${OS}/${ARCH}/kubectl"
}

install_helm() {
  needs_install helm "$HELM_VERSION" || { log "helm $HELM_VERSION already installed"; return; }
  log "installing helm $HELM_VERSION"
  fetch "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz" "$SCRATCH/helm.tgz"
  tar -xzf "$SCRATCH/helm.tgz" -C "$SCRATCH"
  install -m 0755 "$SCRATCH/${OS}-${ARCH}/helm" "$TOOLS_BIN/helm"
}

install_argocd() {
  needs_install argocd "$ARGOCD_VERSION" || { log "argocd $ARGOCD_VERSION already installed"; return; }
  install_binary argocd \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-${OS}-${ARCH}"
}

# --- host configuration ---------------------------------------------------

# Rootless kind needs cpu/memory/pids delegated to the user slice. This is the
# single most common reason kind fails on a fresh Linux box.
configure_cgroup_delegation() {
  [[ "$OS" == "linux" ]] || return 0
  [[ "$(id -u)" -eq 0 ]] && return 0

  local controllers="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
  local missing=()
  if [[ -r "$controllers" ]]; then
    for c in cpu memory pids; do
      grep -qw "$c" "$controllers" || missing+=("$c")
    done
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "cgroup delegation already configured"
    return
  fi

  warn "cgroup controllers not delegated: ${missing[*]}"
  log "writing /etc/systemd/system/user@.service.d/delegate.conf (needs sudo)"
  sudo mkdir -p /etc/systemd/system/user@.service.d
  printf '[Service]\nDelegate=cpu cpuset io memory pids\n' \
    | sudo tee /etc/systemd/system/user@.service.d/delegate.conf >/dev/null
  sudo systemctl daemon-reload
  warn "log out and back in for delegation to take effect"
}

# Rootless podman maps container UIDs into a subordinate range on the host.
check_subuid() {
  [[ "$OS" == "linux" ]] || return 0
  [[ "$(id -u)" -eq 0 ]] && return 0

  local user; user="$(id -un)"
  if grep -q "^${user}:" /etc/subuid 2>/dev/null && grep -q "^${user}:" /etc/subgid 2>/dev/null; then
    log "subuid/subgid ranges present"
  else
    warn "no /etc/subuid or /etc/subgid entry for '$user'"
    warn "fix with: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user"
  fi
}

check_path() {
  case ":$PATH:" in
    *":$TOOLS_BIN:"*) ;;
    *) warn "$TOOLS_BIN is not on your PATH; add: export PATH=\"$TOOLS_BIN:\$PATH\"" ;;
  esac
}

# --- main -----------------------------------------------------------------

log "platform: $OS/$ARCH"
mkdir -p "$TOOLS_BIN"

install_podman
setup_podman_machine
install_kind
install_kubectl
install_helm
install_argocd
check_subuid
configure_cgroup_delegation
check_path

echo
log "installed versions"
for tool in podman kind kubectl helm argocd; do
  printf '  %-8s %s\n' "$tool" "$(installed_version "$tool" || true)"
done
echo
log "next: ./scripts/create-clusters.sh"
