# TODO

## Promotion via Argo GitOps Promoter

Deferred — decided on, not yet started. Promotion today does not exist: all
three environments track the same branch and resolve to the same image tag, so
a commit to `apps/whoami/base` lands on int, stage and prod at once.

Use [GitOps Promoter](https://github.com/argoproj-labs/gitops-promoter)
(`argoproj-labs`, v0.42.1, experimental) rather than branch-per-env or a
manual tag bump.

### How it changes the model

Promoter does not read the kustomize overlays directly. It needs a *hydrator*
to render them and push the output to per-environment branches, then it opens
PRs between those branches:

```
argocd branch            DRY branch: kustomize sources, one commit for all envs
  └─ hydrator renders each overlay
       environment/int-next     staging branch, hydrated manifests
       environment/int          live branch, what int actually syncs
       environment/stage-next
       environment/stage
       environment/prod-next
       environment/prod
```

Promoter opens `environment/<env>-next` → `environment/<env>` PRs and holds at
most one open PR per environment. Gates are `CommitStatus` resources, so prod
can require int to be healthy first.

Argo CD's **source hydrator** implements the hydration contract. It is beta as
of Argo CD v3.5.0 and disabled by default.

### Work required

1. Install Argo CD from `install-with-hydrator.yaml`, or set
   `hydrator.enabled: "true"` in `argocd-cmd-params-cm` and enable the commit
   server. **Install v3.5.x from the start** — 3.4.x has no usable hydrator and
   switching later means a reinstall.
2. Give Argo CD **write** credentials to this repo. Read is free because the
   repo is public; pushing hydrated branches is not. Needs a deploy key or
   GitHub App with `Contents: read/write`.
3. Rewrite `argocd/applicationsets/whoami.yaml` to use `spec.sourceHydrator`
   (`drySource` / `syncSource` / `hydrateTo`) instead of `spec.source`. The two
   are mutually exclusive.
4. Create a **GitHub App** for Promoter with `Checks: r/w`,
   `Contents: r/w`, `Pull requests: r/w`. Record app ID, installation ID, and
   the private key.
5. Install the controller. `install-without-ui.yaml` needs no cert-manager —
   verified: zero cert-manager references, no admission webhooks. The
   dashboard variants do.
6. Create `ScmProvider` (+ secret with `githubAppPrivateKey`), `GitRepository`,
   `PromotionStrategy` listing the three environment branches in order, and
   `DependentsSuccessfulCommitStatus` for ordering. All must live in the same
   namespace as the `PromotionStrategy`.
7. Seed the six environment branches.
8. Decide what gates prod: `argocd-app-health` on the previous environment is
   the usual starting point.

### Open questions

- Does `autoMerge: false` on every environment give the right feel for a demo,
  or should int auto-merge so only stage and prod need a human?
- Promoter is marked experimental. Acceptable here; note it if this pattern
  gets recommended anywhere real.
