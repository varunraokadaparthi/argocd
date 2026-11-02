# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout 1995306332c20c0d9b9af3e26bfcd6e7439869fc
kustomize build ./apps/whoami/overlays/int
```
