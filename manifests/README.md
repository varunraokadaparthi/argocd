# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout fb897e9e78b26cfe1d355409c7ed4dff1318d9b4
kustomize build ./apps/whoami/overlays/prod
```
