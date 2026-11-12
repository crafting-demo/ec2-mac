#!/bin/bash
# Crafting daemon: keep the workspace checkout ($MAC_REPO_DIR) and its copy on
# the Mac ($MAC_REMOTE_REPO) in two-way sync with Mutagen.
#
# The workspace is the source of truth: git, credentials and the agent stay
# here, and conflicts resolve in the workspace's favor (two-way-resolved).
# Files created on the Mac (Package.resolved, snapshot test references, ...)
# still sync back. .git and build output are never synced.
#
# The session is labeled with a hash of its configuration and recreated when
# that changes, so editing MAC_SYNC_IGNORES or the paths takes effect on the
# next daemon restart.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source "$here/mac-env.sh"

"$here/install-mutagen.sh"
"$here/setup-ssh.sh"
"$here/mac-prepare-volume.sh"

ignores=(DerivedData build .build .DS_Store)
for pattern in $MAC_SYNC_IGNORES; do
  ignores+=("$pattern")
done
ignore_flags=()
for pattern in "${ignores[@]}"; do
  ignore_flags+=(--ignore "$pattern")
done

beta="$MAC_HOST_ALIAS:$MAC_REMOTE_REPO"
config_hash=$(printf '%s\n' "$MAC_REPO_DIR" "$beta" "${ignores[@]}" | sha256sum | cut -c1-16)

# A daemon may already be running, e.g. autostarted by a `mutagen` CLI call.
"$MUTAGEN" daemon stop >/dev/null 2>&1 || true
"$MUTAGEN" daemon run &
daemon_pid=$!
trap 'kill "$daemon_pid" 2>/dev/null || true' EXIT
trap 'exit 143' TERM INT

for _ in $(seq 1 30); do
  "$MUTAGEN" sync list >/dev/null 2>&1 && break
  sleep 1
done

if current=$("$MUTAGEN" sync list "$MAC_SYNC_SESSION" \
  --template '{{range .}}{{index .Labels "ec2-mac-config"}}{{end}}' 2>/dev/null); then
  if [ "$current" = "$config_hash" ]; then
    echo "Mutagen session $MAC_SYNC_SESSION is up to date"
  else
    echo "Mutagen session $MAC_SYNC_SESSION has an old configuration; recreating it"
    "$MUTAGEN" sync terminate "$MAC_SYNC_SESSION"
    current=""
  fi
fi

if [ "$current" != "$config_hash" ]; then
  echo "Creating Mutagen session $MAC_SYNC_SESSION: $MAC_REPO_DIR <-> $beta"
  "$MUTAGEN" sync create \
    --name "$MAC_SYNC_SESSION" \
    --label "ec2-mac-config=$config_hash" \
    --mode two-way-resolved \
    --ignore-vcs \
    "${ignore_flags[@]}" \
    "$MAC_REPO_DIR" "$beta"
fi

"$MUTAGEN" sync list "$MAC_SYNC_SESSION"
wait "$daemon_pid"
