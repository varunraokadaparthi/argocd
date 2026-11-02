# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout 9afd52b32acb4eb6191433dbffdfa3fffd4c7940
kustomize build ./apps/whoami/overlays/int
```
