#!/bin/bash
# Exports sandbox environment variables as JSON for Terraform's `data "external"`.
# Provides the sandbox name/id (for tagging) and the workspace's SSH public key
# (injected into the Mac's authorized_keys via user_data).
public_key=$(ssh-add -L | head -1)
cat <<EOF
{
  "sandbox_name": "$SANDBOX_NAME",
  "sandbox_id": "$SANDBOX_ID",
  "ssh_pub": "$public_key"
}
EOF
