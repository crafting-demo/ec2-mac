#!/usr/bin/env bash
#
# publish-connection.sh
#
# Run this INSIDE the Crafting workspace that owns the EC2 Mac (the workspace that
# provisions the Mac via the macOS-in-Crafting-sandbox guide). It turns the Terraform
# resource state into the ~/mac/connection.json file the `cs mac` extension reads.
#
# Wire it into your sandbox as a post-checkout hook on the Mac-owning workspace
# (the one with `wait_for: [macos]`), e.g.:
#
#   manifest:
#     overlays:
#       - inline:
#           hooks:
#             post-checkout:
#               cmd: ./scripts/publish-connection.sh
#
# Override the path that the repo is checked out to ON THE MAC with REPO_PATH
# (defaults to /Users/ec2-user/<first checkout dir>, falling back to /Users/ec2-user).
set -euo pipefail

STATE="${MAC_STATE_FILE:-/run/sandbox/fs/resources/macos/state}"

# The guide gates the workspace with `wait_for: [macos]`, but poll briefly to be safe.
IP=""
for _ in $(seq 1 30); do
  IP="$(jq -r '.public_ip // empty' "$STATE" 2>/dev/null || true)"
  [ -n "$IP" ] && break
  sleep 2
done
[ -n "$IP" ] || { echo "publish-connection: no public_ip in $STATE yet" >&2; exit 1; }

# This workspace's own SSH FQDN -- the ProxyJump target the extension uses.
# Sandboxes inside a folder are addressed by ID; root-level sandboxes (the common case)
# are addressed by name. SANDBOX_FOLDER is set only when the sandbox lives in a folder.
if [ -n "${SANDBOX_FOLDER:-}" ]; then
  SB="${SANDBOX_ID}"
else
  SB="${SANDBOX_NAME}"
fi
WSHOST="${SANDBOX_WORKLOAD}--${SB}-${SANDBOX_ORG}${SANDBOX_SYSTEM_DNS_SUFFIX}"

REPO_PATH="${REPO_PATH:-/Users/ec2-user}"

mkdir -p "$HOME/mac"
cat > "$HOME/mac/connection.json" <<EOF
{
  "workspaceHost": "$WSHOST",
  "workspaceUser": "owner",
  "macHost": "$IP",
  "macUser": "ec2-user",
  "repoPath": "$REPO_PATH",
  "instanceId": $(jq '.instance_id // null' "$STATE"),
  "hostId": $(jq '.host_id // null' "$STATE")
}
EOF

echo "publish-connection: wrote ~/mac/connection.json (workspaceHost=$WSHOST macHost=$IP)"
