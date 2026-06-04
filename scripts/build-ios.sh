#!/bin/bash
# Build an iOS project on the Mac and (optionally) pull back artifacts.
set -e

REMOTE=$(jq -r ".public_ip" /run/sandbox/fs/resources/macos/state)
SCHEME="${1:-MyApp}"
PROJECT_DIR="${2:-my-ios-app}"

echo "==> Syncing code to Mac..."
rsync -az --delete \
  --exclude '.git' \
  --exclude 'DerivedData' \
  --exclude 'build' \
  -e "ssh -o StrictHostKeyChecking=no" \
  "$PROJECT_DIR/" "ec2-user@$REMOTE:~/$PROJECT_DIR/"

echo "==> Building $SCHEME on Mac..."
ssh -o StrictHostKeyChecking=no "ec2-user@$REMOTE" \
  "cd ~/$PROJECT_DIR && xcodebuild -scheme $SCHEME -sdk iphoneos -configuration Release build"

echo "==> Build complete."

# To pull back artifacts (e.g. the .app or .ipa):
#   rsync -az -e "ssh -o StrictHostKeyChecking=no" \
#     "ec2-user@$REMOTE:~/$PROJECT_DIR/build/Release-iphoneos/" "./build-output/"
