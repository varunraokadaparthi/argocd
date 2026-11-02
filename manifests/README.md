# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout e958b32337c0953c2025c47f7461c7f4662f706a
kustomize build ./apps/whoami/overlays/stage
```
