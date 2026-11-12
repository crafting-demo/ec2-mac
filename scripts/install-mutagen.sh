#!/bin/bash
# Install a pinned Mutagen release into $MUTAGEN_HOME. Safe to run repeatedly.
#
# The release tarball ships mutagen-agents.tar.gz next to the binary; Mutagen
# uses it to install its agent on the Mac over SSH, so both are kept together.
set -euo pipefail

source "$(dirname "$0")/mac-env.sh"

if [ -x "$MUTAGEN" ] && [ -f "$MUTAGEN_HOME/mutagen-agents.tar.gz" ]; then
  exit 0
fi

case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

url="https://github.com/mutagen-io/mutagen/releases/download/v$MUTAGEN_VERSION/mutagen_linux_${arch}_v$MUTAGEN_VERSION.tar.gz"
echo "Installing Mutagen $MUTAGEN_VERSION into $MUTAGEN_HOME"
mkdir -p "$MUTAGEN_HOME"
curl -fsSL "$url" | tar -xz -C "$MUTAGEN_HOME" mutagen mutagen-agents.tar.gz
"$MUTAGEN" version
