# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout 09ab49f10257431661b07b303aa59d26f4640bde
kustomize build ./apps/whoami/overlays/stage
```
