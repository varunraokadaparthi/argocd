# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/varunraokadaparthi/argocd.git
# cd into the cloned directory
git checkout 0449267ddfedd0ef22e58ab8870579c3e61ea0a2
kustomize build ./apps/whoami/overlays/stage
```
