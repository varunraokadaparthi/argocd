# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout f415fb8cc0006d24e90e3ae62652a3a1def78c57
kustomize build ./apps/whoami/overlays/int
```
