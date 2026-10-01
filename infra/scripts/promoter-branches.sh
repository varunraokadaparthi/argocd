#!/usr/bin/env bash
# Create the active environment branches GitOps Promoter promotes into.
#
# Only the active branches, and only as empty commits. Two things this
# deliberately does NOT do:
#
#   The environment/<env>-next branches are the hydrator's responsibility --
#   Argo CD creates them when it first pushes. Pre-creating them puts a
#   commit on the branch with no hydrator.metadata, and Promoter rejects it
#   with "has hydrated commit ... but no dry SHA from hydrator.metadata".
#
#   The active branches are not seeded with manifests. An empty branch has no
#   manifests/ path at all (git cannot store an empty directory), so Argo CD
#   reports "app path does not exist" and syncs nothing -- it does not prune,
#   because it will not act on a desired state it could not determine.
#
# What is needed is that the active branch exists at all: GitHub cannot open
# a pull request into a base branch that is missing, and Promoter has no
# branch-creation code of its own.
#
# Idempotent.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v git >/dev/null || die "git is required"
cd "$REPO_ROOT"
git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote"

# One empty root commit shared by every environment, so that a later PR from
# environment/<env>-next has common ancestry with its base.
seed="$(git commit-tree "$(git hash-object -t tree /dev/null)" \
  -m "Seed environment branch for GitOps Promoter")"

for env in "${CLUSTERS[@]}"; do
  branch="environment/$env"
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    log "branch '$branch' already exists"
  else
    git push -q origin "$seed:refs/heads/$branch"
    log "created '$branch'"
  fi
done

echo
log "environment branches on the remote"
git ls-remote --heads origin 'refs/heads/environment/*' \
  | awk '{printf "  %-34s %s\n", substr($2,12), substr($1,1,8)}'
echo
log "the -next branches appear once Argo CD hydrates; they are not created here"
