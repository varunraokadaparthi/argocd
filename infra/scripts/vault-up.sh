#!/usr/bin/env bash
# Start Vault beside the clusters, initialise it on first run, and unseal it.
#
# Vault is deliberately not a workload in any cluster: it is a container on the
# same podman network, so pods everywhere reach it at http://vault:8200 and it
# survives delete-clusters.sh. Safe to re-run -- it initialises once and
# unseals every time, which is what you want after a host or container restart.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

detect_platform
command -v podman >/dev/null 2>&1 || die "podman is required"

# The clusters create this network; Vault has to join the same one to be
# resolvable from inside them.
podman network exists "$VAULT_NETWORK" 2>/dev/null \
  || die "podman network '$VAULT_NETWORK' does not exist -- run create-clusters.sh first"

vault_exec() { podman exec -e VAULT_ADDR=http://127.0.0.1:8200 "$VAULT_CONTAINER" vault "$@"; }

# --- container ------------------------------------------------------------

state="$(podman inspect "$VAULT_CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo absent)"
case "$state" in
  running)
    log "vault container already running"
    ;;
  absent)
    # The config is mounted outside /vault/config on purpose: the image's
    # entrypoint appends `-config=/vault/config` to whatever you pass, so a
    # file in there would be loaded twice and the duplicate listener stanza
    # fails with "address already in use".
    log "creating vault container ($VAULT_IMAGE)"
    podman volume exists "$VAULT_VOLUME" 2>/dev/null || podman volume create "$VAULT_VOLUME" >/dev/null
    podman run -d \
      --name "$VAULT_CONTAINER" \
      --network "$VAULT_NETWORK" \
      --publish "$VAULT_HOST_PORT:8200" \
      --volume "$VAULT_VOLUME:/vault/data" \
      --volume "$VAULT_DIR/config.hcl:/vault/userconfig/config.hcl:ro,Z" \
      "$VAULT_IMAGE" server -config=/vault/userconfig/config.hcl >/dev/null
    ;;
  *)
    log "starting existing vault container (was $state)"
    podman start "$VAULT_CONTAINER" >/dev/null
    ;;
esac

log "waiting for vault to listen"
for i in $(seq 1 30); do
  # 501 = not initialised, 503 = sealed, 200 = ready. Any of them means the
  # API is up, which is all we need before init/unseal.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
    "$VAULT_ADDR_HOST/v1/sys/health" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "000" ]] && break
  sleep 1
done
[[ -n "${code:-}" && "$code" != "000" ]] || die "vault did not start; check 'podman logs $VAULT_CONTAINER'"

# --- initialise -----------------------------------------------------------

initialised="$(curl -s --max-time 5 "$VAULT_ADDR_HOST/v1/sys/health" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("initialized"))' 2>/dev/null || echo unknown)"

if [[ "$initialised" == "False" ]]; then
  log "initialising vault (first run)"
  # One key share is wrong for production and right for a laptop: it keeps
  # the unseal step to a single secret that a script can replay on restart.
  umask 077
  vault_exec operator init -key-shares=1 -key-threshold=1 -format=json \
    > "$VAULT_SECRETS_FILE"
  chmod 600 "$VAULT_SECRETS_FILE"
  log "unseal key and root token written to $VAULT_SECRETS_FILE (gitignored)"
else
  log "vault already initialised"
  [[ -f "$VAULT_SECRETS_FILE" ]] \
    || die "vault is initialised but $VAULT_SECRETS_FILE is missing -- cannot unseal"
fi

# --- unseal ---------------------------------------------------------------

sealed="$(curl -s --max-time 5 "$VAULT_ADDR_HOST/v1/sys/seal-status" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sealed"))' 2>/dev/null || echo unknown)"

if [[ "$sealed" == "True" ]]; then
  log "unsealing"
  key="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["unseal_keys_b64"][0])' \
    "$VAULT_SECRETS_FILE")"
  vault_exec operator unseal "$key" >/dev/null
else
  log "vault already unsealed"
fi

# --- report ---------------------------------------------------------------

root_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root_token"])' \
  "$VAULT_SECRETS_FILE")"

echo
log "vault ready"
printf '  version     %s\n' "$VAULT_VERSION"
printf '  from host   %s\n' "$VAULT_ADDR_HOST"
printf '  from pods   %s\n' "$VAULT_ADDR_CLUSTER"
printf '  root token  %s\n' "$root_token"
printf '  secrets     %s\n' "$VAULT_SECRETS_FILE"
echo
log "UI: $VAULT_ADDR_HOST  (token auth, paste the root token)"
