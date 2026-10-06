# infra

Local multi-cluster environment for the ArgoCD setup: three kind clusters
running on podman.

| Cluster | Role  | Context      | Pod CIDR       | Service CIDR   |
| ------- | ----- | ------------ | -------------- | -------------- |
| `stage` | hub   | `kind-stage` | 10.240.0.0/16  | 10.241.0.0/16  |
| `int`   | spoke | `kind-int`   | 10.242.0.0/16  | 10.243.0.0/16  |
| `prod`  | spoke | `kind-prod`  | 10.244.0.0/16  | 10.245.0.0/16  |

ArgoCD runs on `stage` and manages itself plus the two spokes.

## Usage

```sh
./scripts/setup-tools.sh       # install/verify tooling; --force to reinstall
./scripts/create-clusters.sh   # idempotent; skips clusters that already exist
./scripts/delete-clusters.sh   # only removes stage/int/prod
```

All three are safe to re-run.

## Supported platforms

macOS on Apple Silicon or Intel, and Linux on amd64 or arm64.
`setup-tools.sh` detects the platform with `uname` and picks the matching
release asset; the pinned node image is a multi-arch manifest covering
`linux/amd64` and `linux/arm64`.

## Tooling

`setup-tools.sh` installs and version-checks everything. Versions are pinned
in `scripts/lib.sh`.

| Tool      | Version  | Source                                    |
| --------- | -------- | ----------------------------------------- |
| `podman`  | any      | platform package manager                   |
| `kind`    | v0.33.0  | pinned binary → `~/.local/bin`             |
| `kubectl` | v1.35.0  | pinned binary → `~/.local/bin`             |
| `helm`    | v3.20.2  | pinned binary → `~/.local/bin`             |
| `argocd`  | v3.5.3   | pinned binary → `~/.local/bin`             |

podman comes from the package manager (`brew`, `dnf`, `apt-get`, `pacman` or
`zypper`) because it needs system integration. Everything else is a pinned
binary in `~/.local/bin`, which needs no sudo and behaves identically on every
platform. Override the install location with `TOOLS_BIN`.

**`argocd` must stay on 3.5.x.** The source hydrator that the promotion work
in [../TODO.md](../TODO.md) depends on is beta as of Argo CD 3.5.0 and does
not exist before it; keep the CLI in step with the server.

**`kubectl` is deliberately pinned to the node image's Kubernetes version.**
A skew wider than one minor is unsupported and fails in confusing ways. Note
that `kubectl version` reports the *server* version when a context is active —
use `kubectl version --client` when checking by hand.

## Host requirements

### Linux

- **cgroup v2** with `cpu`, `memory` and `pids` delegated to your user slice.
  Without delegation the kubelet fails to start inside the node container.
  This is the most common reason kind fails on a fresh box.
  `setup-tools.sh` detects it and offers to write the drop-in:

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

- **subuid/subgid ranges** for your user, so rootless podman can map container
  UIDs. Checked by `setup-tools.sh`; fix with
  `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`.

### macOS

Containers run inside a Linux VM, so `setup-tools.sh` creates a podman machine
sized for three control planes (6 CPU, 12 GB, 60 GB disk — override with
`PODMAN_MACHINE_CPUS`, `PODMAN_MACHINE_MEMORY`, `PODMAN_MACHINE_DISK`). The
machine is created `--rootful`, which is the configuration kind expects; the
VM is already an isolation boundary. The default machine is undersized for
this topology.

Homebrew is required, and the machine must be running before
`create-clusters.sh` — the preflight check will tell you if it is not.

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

Name resolution comes from podman's `aardvark-dns`, and the API server
certificates already carry the right SANs.

**There is no LoadBalancer.** kind ships no cloud provider, so
`type: LoadBalancer` services sit in `<pending>` forever. The hub maps host
ports 8080 and 8443 to container ports 80 and 443, so installing an ingress
controller on `stage` puts the ArgoCD UI on <https://localhost:8443> (`install-argocd.sh` installs it). The hub
node is labelled `ingress-ready=true` for the ingress controller (Traefik, installed by `install-argocd.sh`).
The spokes have no port mappings; reach them with `kubectl port-forward`.

**Node images are ~1 GB each.** After tearing clusters down, reclaim space
with `podman system prune`.
