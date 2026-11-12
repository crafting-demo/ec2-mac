#!/bin/bash
# Run a command on the Mac, inside the synced copy of the repo.
#
#   mac-run.sh xcodebuild -list
#   mac-run.sh xcrun simctl list devices booted
#
# Flushes the Mutagen session first so the Mac sees every edit made in the
# workspace, and again afterwards so files the command wrote (screenshots,
# snapshot references, ...) are back in the workspace when it returns. The
# command runs in a login shell so Homebrew and Xcode tools are on PATH.
# Exits with the command's exit status.
set -euo pipefail

source "$(dirname "$0")/mac-env.sh"

if [ $# -eq 0 ]; then
  echo "usage: $(basename "$0") COMMAND [ARGS...]" >&2
  exit 2
fi

"$MUTAGEN" sync flush "$MAC_SYNC_SESSION" >/dev/null

remote_cmd="cd $(printf '%q' "$MAC_REMOTE_REPO") && $(printf '%q ' "$@")"
status=0
ssh "$MAC_HOST_ALIAS" "zsh -lc $(printf '%q' "$remote_cmd")" || status=$?

"$MUTAGEN" sync flush "$MAC_SYNC_SESSION" >/dev/null || true
exit "$status"
