# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout 2e00b782fe3d0e9546db141f21ec07837c58ec3f
kustomize build ./apps/whoami/overlays/stage
```
