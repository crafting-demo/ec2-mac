#!/bin/bash
# Push source code from the workspace to the Mac using rsync.
set -e

REMOTE=$(jq -r ".public_ip" /run/sandbox/fs/resources/macos/state)
PROJECT_DIR="${1:-.}"

rsync -az --delete \
  --exclude '.git' \
  --exclude 'DerivedData' \
  --exclude 'build' \
  -e "ssh -o StrictHostKeyChecking=no" \
  "$PROJECT_DIR/" "ec2-user@$REMOTE:~/$(basename "$PROJECT_DIR")/"

echo "Code synced to Mac at ~/$(basename "$PROJECT_DIR")"
