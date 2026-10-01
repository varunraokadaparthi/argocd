#!/usr/bin/env bash
# Stop Vault. Data is kept in the podman volume unless --purge is given.
#
#   ./vault-down.sh           stop the container, keep the data
#   ./vault-down.sh --purge   also remove the volume and the unseal keys
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

state="$(podman inspect "$VAULT_CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo absent)"
if [[ "$state" == "running" ]]; then
  log "stopping vault"
  podman stop "$VAULT_CONTAINER" >/dev/null
elif [[ "$state" == "absent" ]]; then
  log "vault container does not exist"
else
  log "vault is already $state"
fi

if $PURGE; then
  warn "purging vault data -- every secret and the unseal key will be lost"
  podman rm -f "$VAULT_CONTAINER" >/dev/null 2>&1 || true
  podman volume rm "$VAULT_VOLUME" >/dev/null 2>&1 || true
  rm -f "$VAULT_SECRETS_FILE"
  log "purged"
else
  log "data kept in volume '$VAULT_VOLUME'; ./scripts/vault-up.sh to resume"
fi
