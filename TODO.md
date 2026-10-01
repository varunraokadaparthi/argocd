# TODO

## Finish turning on GitOps Promoter

Everything is built and committed; the controller is installed and the
manifests validate against its CRDs. One step remains, and it cannot be
scripted.

**Create a GitHub App** and run `infra/scripts/promoter-bootstrap.sh` with
`GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID` and `GITHUB_APP_PRIVATE_KEY` set.
Permissions and where to find the IDs are in the README under step 8. The
`ScmProvider` CRD makes `appID` mandatory — GitHub has no token path, so an
App is not optional.

Until then the Applications still use `spec.source` and all three
environments move together. Nothing is broken; the switch to
`sourceHydrator` is the last thing the bootstrap script does, on purpose.

## Secrets still fan out

Promoter promotes git commits. The Vault secret is not in git, so
`vault kv put demo/whoami` reaches int, stage and prod within about three
minutes with no gate at all — Reloader then restarts prod. That is a sharper
path to production than the git one, which at least leaves a reviewable
commit.

Closing it means per-environment paths in Vault:

```
demo/int/whoami      ExternalSecret in demo-int reads only this
demo/stage/whoami
demo/prod/whoami
```

Promoting a secret becomes writing it to the next path. Worth doing at the
same time as the Promoter switch-on rather than after — the current shared
`demo/whoami` cannot be gated no matter what Promoter does.

Open question: whether the promotion of a secret should be driven by the
same PR that promotes the manifests, or stay a separate deliberate act. The
first is tidier; the second is harder to do by accident.

## Smaller things

- `PushSecret` is `external-secrets.io/v1alpha1` while the rest of ESO is
  `v1`. Expect it to move.
- Promoter is marked experimental. Fine here; worth saying out loud if this
  pattern gets recommended anywhere real.
- The `vault-available` gate checks that Vault is unsealed, not that the
  specific secret an environment needs exists. A missing key would still
  promote green and then fail to start.
