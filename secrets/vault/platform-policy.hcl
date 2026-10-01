# Read access to platform credentials only.
#
# Deliberately a separate policy and token from the application one. The
# GitHub App private key can push to every branch of this repo and merge its
# own promotion PRs; it must not be readable through the same store that the
# demo tenant uses.

path "platform/data/*" {
  capabilities = ["read"]
}

path "platform/metadata/*" {
  capabilities = ["read", "list"]
}
