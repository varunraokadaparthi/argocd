# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout 8be2ff3aa4dbc91ff514dc990d231401a6f7050d
kustomize build ./apps/whoami/overlays/stage
```
