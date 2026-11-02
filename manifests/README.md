# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout 2ad292418496505a2d1a4180bfd083ee4ded792e
kustomize build ./apps/whoami/overlays/int
```
