#!/usr/bin/env bash
# Create and seed the environment branches GitOps Promoter promotes between.
#
# Each environment needs two: environment/<env>-next, where Argo CD's
# hydrator pushes rendered manifests, and environment/<env>, which the
# cluster syncs and which only changes when a promotion PR merges.
#
# Both start from one shared orphan commit so a PR between them has common
# ancestry. The active branch is then seeded with the manifests the cluster
# is already running -- the ApplicationSet has prune enabled, so switching an
# Application to sourceHydrator while its active branch was empty would
# delete the workload. int and stage auto-merge and would recover; prod does
# not, so it would stay down until someone merged by hand.
#
# Idempotent: existing branches are left alone, and seeding is skipped where
# the branch already has manifests.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v git >/dev/null || die "git is required"
command -v kubectl >/dev/null || die "kubectl is required"

cd "$REPO_ROOT"

git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote"

# Must match syncSource.path in argocd/applicationsets/whoami.yaml. Argo CD
# refuses to hydrate to a branch root, so it is a subdirectory.
MANIFEST_PATH="${MANIFEST_PATH:-manifests}"

branch_exists() { git ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1; }

# --- create ---------------------------------------------------------------

# One empty root commit shared by every branch.
seed="$(git commit-tree "$(git hash-object -t tree /dev/null)" \
  -m "Seed environment branch for GitOps Promoter")"

for env in "${CLUSTERS[@]}"; do
  for branch in "environment/$env" "environment/$env-next"; do
    if branch_exists "$branch"; then
      log "branch '$branch' already exists"
    else
      git push -q origin "$seed:refs/heads/$branch"
      log "created '$branch'"
    fi
  done
done

# --- seed the active branches --------------------------------------------

for env in "${CLUSTERS[@]}"; do
  branch="environment/$env"
  git fetch -q origin "refs/heads/$branch"
  parent="$(git rev-parse FETCH_HEAD)"

  if git ls-tree -r FETCH_HEAD --name-only | grep -q "^$MANIFEST_PATH/"; then
    log "'$branch' already has manifests, leaving it alone"
    continue
  fi

  log "seeding '$branch' from apps/whoami/overlays/$env"
  rendered="$(mktemp)"
  kubectl kustomize "$REPO_ROOT/apps/whoami/overlays/$env" > "$rendered" \
    || die "could not render overlay for '$env'"
  blob="$(git hash-object -w "$rendered")"
  rm -f "$rendered"

  # A scratch index so the working tree and the real index are untouched.
  tmpidx="$(mktemp)"
  GIT_INDEX_FILE="$tmpidx" git read-tree --empty
  GIT_INDEX_FILE="$tmpidx" git update-index --add \
    --cacheinfo "100644,$blob,$MANIFEST_PATH/manifest.yaml"
  tree="$(GIT_INDEX_FILE="$tmpidx" git write-tree)"
  rm -f "$tmpidx"

  commit="$(git commit-tree "$tree" -p "$parent" -m "Seed $branch with current rendered manifests

Pre-populates the active branch so switching to sourceHydrator does not
leave it empty and trigger a prune.")"
  git push -q origin "$commit:refs/heads/$branch"
done

echo
log "environment branches"
git ls-remote --heads origin 'refs/heads/environment/*' \
  | awk '{printf "  %-34s %s\n", substr($2,12), substr($1,1,8)}'
