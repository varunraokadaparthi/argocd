# What External Secrets Operator is allowed to do in Vault.
# Read-only, and only under the demo mount -- ESO never needs to write, and
# the token built from this policy is what gets handed to the cluster.
#
# kv-v2 splits data and metadata onto separate paths, so both are listed.

path "demo/data/*" {
  capabilities = ["read"]
}

path "demo/metadata/*" {
  capabilities = ["read", "list"]
}
