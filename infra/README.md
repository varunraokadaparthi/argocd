# infra

Local multi-cluster environment for the ArgoCD setup: three kind clusters
running on rootless podman.

| Cluster | Role  | Context      | Pod CIDR       | Service CIDR   |
| ------- | ----- | ------------ | -------------- | -------------- |
| `stage` | hub   | `kind-stage` | 10.240.0.0/16  | 10.241.0.0/16  |
| `int`   | spoke | `kind-int`   | 10.242.0.0/16  | 10.243.0.0/16  |
| `prod`  | spoke | `kind-prod`  | 10.244.0.0/16  | 10.245.0.0/16  |

ArgoCD runs on `stage` and manages itself plus the two spokes.

## Usage

```sh
./scripts/create-clusters.sh   # idempotent; skips clusters that already exist
./scripts/delete-clusters.sh   # only removes stage/int/prod
```

## Requirements

Everything below is checked by `require_tools` in `scripts/lib.sh`, which fails
early rather than letting kind produce a confusing error.

- **podman** (rootless is fine) with entries in `/etc/subuid` and `/etc/subgid`
- **kind** v0.31+
- **kubectl**
- **cgroup v2** with the `cpu`, `memory` and `pids` controllers delegated to
  your user slice. Without delegation the kubelet fails to start inside the
  node container. To enable:

  ```sh
  sudo mkdir -p /etc/systemd/system/user@.service.d
  printf '[Service]\nDelegate=cpu cpuset io memory pids\n' \
    | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
  sudo systemctl daemon-reload
  ```

  Log out and back in, then confirm:

  ```sh
  cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
  ```

Keep `kubectl` within one minor version of the node image (currently
Kubernetes v1.35) — larger skew is unsupported and produces odd failures.

## Notes on kind + podman

**`KIND_EXPERIMENTAL_PROVIDER=podman` is mandatory.** kind still defaults to
Docker and calls the podman backend experimental. `scripts/lib.sh` exports it
so you never have to remember; if you run `kind` by hand, set it yourself.

**Use the internal endpoint when registering spokes.** The kubeconfig kind
writes points at `127.0.0.1:<random-port>`, which from inside an ArgoCD pod
means the pod itself. All three clusters share the `kind` podman network, so
the hub reaches a spoke at its container name instead:

```sh
kind get kubeconfig --name int --internal   # server: https://int-control-plane:6443
```

Name resolution is provided by podman's `aardvark-dns`, and the API server
certificates already carry the right SANs.

**There is no LoadBalancer.** kind ships no cloud provider, so
`type: LoadBalancer` services sit in `<pending>` forever. The hub maps host
ports 8080 and 8443 to container ports 80 and 443, so installing an ingress
controller on `stage` puts the ArgoCD UI on <http://localhost:8080>. The hub
node is labelled `ingress-ready=true` for ingress-nginx's kind manifest.
The spokes have no port mappings; reach them with `kubectl port-forward`.

**Node images are ~1 GB each.** After tearing clusters down, reclaim space with
`podman system prune`.
