# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout 242ae0a3bb4587eb48c9f01a80b039122bc637ec
kustomize build ./apps/whoami/overlays/int
```
