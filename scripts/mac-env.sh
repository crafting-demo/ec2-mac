# Shared settings for the workspace-side scripts. Sourced, not executed.
# Every value can be overridden from the workspace environment (e.g. the `env`
# list in .sandbox/template.yaml).

# Resource state written by the `macos` Terraform resource.
MAC_STATE="${MAC_STATE:-/run/sandbox/fs/resources/macos/state}"

# SSH alias for the Mac, written into ~/.ssh/config by setup-ssh.sh.
MAC_HOST_ALIAS="${MAC_HOST_ALIAS:-mac}"
MAC_USER="${MAC_USER:-ec2-user}"

# The git checkout in the workspace. This is the source of truth.
MAC_REPO_DIR="${MAC_REPO_DIR:-$HOME/my-ios-app}"   # <-- REPLACE (or set MAC_REPO_DIR in the template)
MAC_REPO_NAME="${MAC_REPO_NAME:-$(basename "$MAC_REPO_DIR")}"

# Where the persistent EBS data volume is mounted on the Mac.
MAC_DATA_MOUNT="${MAC_DATA_MOUNT:-/Volumes/crafting-data}"
MAC_REMOTE_REPO="$MAC_DATA_MOUNT/$MAC_REPO_NAME"
MAC_DERIVED_DATA="$MAC_DATA_MOUNT/DerivedData"

# Mutagen sync session between MAC_REPO_DIR and MAC_REMOTE_REPO.
MAC_SYNC_SESSION="${MAC_SYNC_SESSION:-mac-repo}"
# Extra space-separated Mutagen ignore patterns, e.g. "Pods xcuserdata".
MAC_SYNC_IGNORES="${MAC_SYNC_IGNORES:-}"

MUTAGEN_VERSION="${MUTAGEN_VERSION:-0.18.1}"
MUTAGEN_HOME="${MUTAGEN_HOME:-$HOME/.local/share/ec2-mac/mutagen-$MUTAGEN_VERSION}"
MUTAGEN="$MUTAGEN_HOME/mutagen"
