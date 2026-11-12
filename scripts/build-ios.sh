#!/bin/bash
# Build an iOS scheme on the Mac from the workspace.
#
#   build-ios.sh [SCHEME] [extra xcodebuild args...]
#
# Code reaches the Mac through the Mutagen sync (mac-run.sh flushes it first).
# DerivedData lives on the persistent data volume, so incremental builds stay
# warm across suspend/resume and instance replacement.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source "$here/mac-env.sh"

SCHEME="${1:-MyApp}"   # <-- REPLACE with your scheme
shift || true

echo "==> Building $SCHEME on Mac..."
"$here/mac-run.sh" xcodebuild \
  -scheme "$SCHEME" \
  -sdk iphoneos \
  -configuration Release \
  -derivedDataPath "$MAC_DERIVED_DATA" \
  "$@" \
  build

echo "==> Build complete."

# Build products are not synced back. To copy them to the workspace:
#   scp -r "$MAC_HOST_ALIAS:$MAC_DERIVED_DATA/Build/Products/Release-iphoneos" ./build-output/
