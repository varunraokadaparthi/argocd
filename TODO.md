# TODO

## Secrets still fan out

The one real gap. Promoter promotes git commits; the Vault secret is not in
git, so `vault kv put demo/whoami` reaches int, stage and prod within about
three minutes with no gate at all, and Reloader then restarts prod. That is a
shorter path to production than the git one, which at least leaves a
reviewable commit and a gated PR.

Closing it means per-environment paths in Vault:

```
demo/int/whoami      ExternalSecret in demo-int reads only this
demo/stage/whoami
demo/prod/whoami
```

Promoting a secret becomes writing it to the next path. The current shared
`demo/whoami` cannot be gated no matter what Promoter does.

Open question: whether a secret should be promoted by the same PR that
promotes the manifests, or stay a separate deliberate act. The first is
tidier; the second is harder to do by accident.

## When a second app arrives

Do not add per-app environment branches. Set
`PromotionStrategy.spec.activePath` instead (e.g. `apps/whoami`): proposed
branches become `environment/<env>-next/<activePath>` while the active
branch stays shared, so each app promotes independently without multiplying
the branches someone has to create by hand.

That change also moves `hydrator.metadata` to `<activePath>/hydrator.metadata`
and means `syncSource.path` has to match the activePath. Worth doing at the
point the second app lands rather than retrofitting later.

## Smaller things

- **The pod spec is duplicated** between `apps/whoami/base/deployment.yaml`
  and `apps/whoami/components/rollout/rollout.yaml`. Inherent to the pattern
  — a Rollout is a different kind, not a patch — but they will drift if only
  one is edited. A `kustomize` build check in CI would catch it.
- **Every promotion hop waits a ~3 minute Argo CD poll**, so int → stage →
  prod takes several minutes of waiting rather than working. A GitHub webhook
  to `argocd-server` would make each hop immediate.
- **`PushSecret` is `external-secrets.io/v1alpha1`** while the rest of ESO is
  `v1`. Expect it to move.
- **Promoter is marked experimental.** Fine here; worth saying out loud if
  this pattern gets recommended anywhere real.
- **The `vault-available` gate checks that Vault is unsealed**, not that the
  specific secret an environment needs exists. A missing key would promote
  green and then fail to start.
- **Hydration races on `refs/notes/hydrator.metadata`.** Three Applications
  pushing the shared git note at once occasionally loses: one fails with
  `cannot lock ref` and recovers on the next attempt. Harmless here, more
  visible with more applications.
- **Two GitHub credentials would be better than one.** Argo CD only needs
  `contents: write`; Promoter needs pull requests and checks too. A separate
  App for the hydrator would mean it cannot open or merge PRs.
