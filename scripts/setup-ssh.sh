#!/bin/bash
# Configure SSH for convenient access to the Mac from the workspace.
# Run manually or from a workspace lifecycle handler. After this, use `ssh mac`.
set -e

REMOTE=$(jq -r ".public_ip" /run/sandbox/fs/resources/macos/state)

if [ -z "$REMOTE" ] || [ "$REMOTE" = "null" ]; then
  echo "Mac instance not ready yet (no IP in resource state)"
  exit 1
fi

mkdir -p ~/.ssh

cat > ~/.ssh/config <<EOF
Host mac
  HostName $REMOTE
  User ec2-user
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ServerAliveInterval 30
  ServerAliveCountMax 3
EOF

echo "SSH configured. Test with: ssh mac"
ssh -o ConnectTimeout=10 mac "echo 'Connection to Mac successful'"
