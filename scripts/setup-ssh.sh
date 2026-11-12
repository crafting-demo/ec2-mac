#!/bin/bash
# Configure SSH for convenient access to the Mac from the workspace.
# Run manually or from a workspace lifecycle handler. After this, use `ssh mac`.
#
# Only the fenced "# >>> ec2-mac" block in ~/.ssh/config is rewritten; the rest
# of the file is left alone. The block goes first so its options win over any
# later wildcard Host entries.
set -euo pipefail

source "$(dirname "$0")/mac-env.sh"

REMOTE=$(jq -r ".public_ip" "$MAC_STATE")

if [ -z "$REMOTE" ] || [ "$REMOTE" = "null" ]; then
  echo "Mac instance not ready yet (no IP in resource state)"
  exit 1
fi

mkdir -p ~/.ssh
chmod 700 ~/.ssh
config=~/.ssh/config
touch "$config"
chmod 600 "$config"

begin="# >>> ec2-mac $MAC_HOST_ALIAS"
end="# <<< ec2-mac $MAC_HOST_ALIAS"
tmp=$(mktemp)
{
  echo "$begin"
  cat <<EOF
Host $MAC_HOST_ALIAS
  HostName $REMOTE
  User $MAC_USER
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ServerAliveInterval 30
  ServerAliveCountMax 3
EOF
  echo "$end"
  awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$config"
} >"$tmp"
cat "$tmp" >"$config"
rm -f "$tmp"

echo "SSH configured. Test with: ssh $MAC_HOST_ALIAS"
ssh -o ConnectTimeout=10 "$MAC_HOST_ALIAS" "echo 'Connection to Mac successful'"
