#!/usr/bin/env bash
# Verify a GitHub App's credentials before running promoter-bootstrap.sh.
#
# Wrong IDs or the wrong key otherwise surface as a Promoter controller that
# looks installed and quietly never opens a pull request. This walks the same
# path Promoter does -- sign a JWT as the App, exchange it for an installation
# token, check the repo and the permissions -- and says which step failed.
#
#   GITHUB_APP_ID=123456 \
#   GITHUB_INSTALLATION_ID=12345678 \
#   GITHUB_APP_PRIVATE_KEY=~/path/key.pem \
#   ./github-app-check.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${GITHUB_APP_ID:?set GITHUB_APP_ID}"
: "${GITHUB_INSTALLATION_ID:?set GITHUB_INSTALLATION_ID}"
: "${GITHUB_APP_PRIVATE_KEY:?set GITHUB_APP_PRIVATE_KEY}"
[[ -f "$GITHUB_APP_PRIVATE_KEY" ]] || die "private key not found: $GITHUB_APP_PRIVATE_KEY"
command -v openssl >/dev/null || die "openssl is required"

REPO_OWNER="${REPO_OWNER:-varunraokadaparthi}"
REPO_NAME="${REPO_NAME:-argocd}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# --- 1. sign a JWT as the App --------------------------------------------

now="$(date +%s)"
# iat backdated 60s: GitHub rejects tokens whose iat is in the future, and
# small clock differences are common.
header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$GITHUB_APP_ID" | b64url)"
signature="$(printf '%s.%s' "$header" "$payload" \
  | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY" -binary | b64url)" \
  || die "could not sign with $GITHUB_APP_PRIVATE_KEY -- is it the App's RSA private key?"
jwt="$header.$payload.$signature"

app="$(curl -s --max-time 20 -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" https://api.github.com/app)"

app_slug="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("slug",""))' <<<"$app" 2>/dev/null || true)"
if [[ -z "$app_slug" ]]; then
  warn "$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("message","unexpected response"))' <<<"$app" 2>/dev/null || echo "$app" | head -1)"
  die "App ID $GITHUB_APP_ID did not authenticate -- check the ID matches the key"
fi
log "authenticated as App '$app_slug' (id $GITHUB_APP_ID)"

# --- 2. exchange it for an installation token -----------------------------

tok_resp="$(curl -s --max-time 20 -X POST \
  -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/$GITHUB_INSTALLATION_ID/access_tokens")"

token="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' <<<"$tok_resp" 2>/dev/null || true)"
if [[ -z "$token" ]]; then
  warn "$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("message","unexpected response"))' <<<"$tok_resp" 2>/dev/null || true)"
  warn "installations this App actually has:"
  curl -s --max-time 20 -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
    https://api.github.com/app/installations \
    | python3 -c 'import json,sys
for i in json.load(sys.stdin):
    print("    id=%s  account=%s" % (i["id"], i["account"]["login"]))' 2>/dev/null || true
  die "installation ID $GITHUB_INSTALLATION_ID is not valid for this App"
fi
log "installation $GITHUB_INSTALLATION_ID issued a token"

# --- 3. permissions -------------------------------------------------------

perms="$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("permissions",{})))' <<<"$tok_resp")"
ok=true
for want in contents:write pull_requests:write checks:write; do
  key="${want%%:*}"; need="${want##*:}"
  have="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('$key','(none)'))" "$perms")"
  if [[ "$have" == "$need" ]]; then
    printf '  %-16s %s\n' "$key" "$have"
  else
    printf '  %-16s %s  (need %s)\n' "$key" "$have" "$need"
    ok=false
  fi
done
$ok || die "the App is missing permissions -- fix them on the App page, then accept the new permissions on the installation"

# --- 4. can it see the repo? ---------------------------------------------

repo_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
  -H "Authorization: token $token" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME")"
[[ "$repo_code" == "200" ]] \
  || die "the installation cannot see $REPO_OWNER/$REPO_NAME (HTTP $repo_code) -- is the App installed on it?"
log "repository $REPO_OWNER/$REPO_NAME is accessible"

echo
log "all checks passed -- ./scripts/promoter-bootstrap.sh will work with these values"
