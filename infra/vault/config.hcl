# Vault runs as a plain podman container on the shared `kind` network, not as
# a workload in any of the clusters. That makes it reachable by name from pods
# in all three, survives delete-clusters.sh, and matches how Vault usually
# appears to an application team: an external service someone else operates.

storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

# How Vault advertises itself to clients. `vault` is the container name, which
# podman's aardvark-dns resolves for anything on the `kind` network, including
# pods inside the clusters.
api_addr = "http://vault:8200"

ui = true

# Vault normally mlocks memory so secrets cannot be swapped to disk, which
# needs the IPC_LOCK capability. Disabled here to keep the container
# unprivileged; for a local demo the tradeoff is fine, in production it is not.
disable_mlock = true
