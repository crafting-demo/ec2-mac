## Building and testing on the Mac

This workspace is the source of truth for the repo. A copy is kept in sync on an
EC2 Mac, which has Xcode and the iOS simulator. Edit files and run git here, in
the workspace. Run anything that needs macOS through `mac-run.sh`:

```bash
~/infra/scripts/mac-run.sh xcodebuild -list
~/infra/scripts/build-ios.sh MyApp
~/infra/scripts/mac-run.sh xcodebuild test -scheme MyApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath /Volumes/crafting-data/DerivedData
~/infra/scripts/mac-run.sh xcrun simctl io booted screenshot screenshot.png
```

- `mac-run.sh` syncs your edits to the Mac before the command runs and syncs any
  files it writes (screenshots, snapshot references) back afterwards. Don't copy
  files to the Mac by hand.
- Commands run from the repo root on the Mac, so use repo-relative paths.
- Always pass `-derivedDataPath /Volumes/crafting-data/DerivedData` to
  `xcodebuild` so builds stay incremental.
- Never run `git` on the Mac. The Mac copy has no `.git` directory.
