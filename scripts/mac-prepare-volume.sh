#!/bin/bash
# Prepare the persistent EBS data volume on the Mac. Safe to run repeatedly.
#
# - Finds the volume by its NVMe serial (the EBS volume ID without the dash),
#   not by size: the root EBS volume also shows up as an external disk.
# - Formats it as APFS only if it has no partitions at all, and refuses to touch
#   a disk with unexpected partitions.
# - Mounts it at $MAC_DATA_MOUNT, creates the repo and DerivedData directories,
#   and links ~/<repo> to the synced copy so `cs mac` paths keep working.
#
# Set MAC_DATA_DISK=diskN to skip the serial lookup.
set -euo pipefail

source "$(dirname "$0")/mac-env.sh"

volume_id=$(jq -r '.data_volume_id // empty' "$MAC_STATE")
if [ -z "$volume_id" ]; then
  echo "No data_volume_id in $MAC_STATE. Is the macos Terraform resource up to date?" >&2
  exit 1
fi
serial="vol${volume_id#vol-}"

args=$(printf '%q ' "$serial" "$MAC_DATA_MOUNT" "$MAC_REPO_NAME" "${MAC_DATA_DISK:-}")
ssh "$MAC_HOST_ALIAS" "bash -s -- $args" <<'REMOTE'
set -euo pipefail
serial="$1"
mount_point="$2"
repo_name="$3"
disk="${4:-}"

label=$(basename "$mount_point")
if [ "$(dirname "$mount_point")" != "/Volumes" ]; then
  echo "MAC_DATA_MOUNT must be /Volumes/<name>, got $mount_point" >&2
  exit 1
fi

find_disk() {
  system_profiler SPNVMeDataType 2>/dev/null | awk -v want="$serial" '
    /Serial Number:/ { found = ($3 == want); next }
    found && !done && /BSD Name:/ { print $3; done = 1 }
  '
}

is_mounted() {
  mount | grep -F " on $mount_point (" >/dev/null
}

# The attachment can lag a little behind Terraform reporting it as attached.
if [ -z "$disk" ]; then
  for _ in $(seq 1 30); do
    disk=$(find_disk)
    [ -n "$disk" ] && break
    sleep 2
  done
fi
if [ -z "$disk" ]; then
  echo "No NVMe disk with serial $serial. Check the volume attachment, or set MAC_DATA_DISK." >&2
  exit 1
fi

store_of() {
  diskutil info "$1" 2>/dev/null | awk -F': *' '/APFS Physical Store/ { sub(/s[0-9]+$/, "", $2); print $2 }'
}

container_of() {
  diskutil list "$1" | awk '/Apple_APFS/ { for (i = 1; i <= NF; i++) if ($i == "Container") print $(i + 1) }'
}

if ! is_mounted; then
  container=$(container_of "$disk")
  layout=$(diskutil list "$disk")
  if [ -n "$container" ]; then
    echo "Mounting existing APFS container $container from $disk"
    sudo diskutil mountDisk "$container" >/dev/null
  elif ! printf '%s\n' "$layout" | awk '/^ +[1-9][0-9]*:/ { p = 1 } END { exit !p }'; then
    echo "Formatting blank data volume $disk as APFS ($label)"
    sudo diskutil eraseDisk APFS "$label" GPT "$disk" >/dev/null
  else
    echo "$disk has partitions but no APFS container; refusing to erase it." >&2
    printf '%s\n' "$layout" >&2
    exit 1
  fi
fi

if ! is_mounted; then
  echo "Data volume from $disk did not mount at $mount_point (is the APFS volume named $label?)" >&2
  exit 1
fi
if [ "$(store_of "$mount_point")" != "$disk" ]; then
  echo "$mount_point is mounted from $(store_of "$mount_point"), not the data volume $disk" >&2
  exit 1
fi

# EC2 Macs usually have no logged-in GUI user; mount external disks at boot anyway.
sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount \
  AutomountDisksWithoutUserLogin -bool true

sudo mkdir -p "$mount_point/$repo_name" "$mount_point/DerivedData"
sudo chown "$(id -un):staff" "$mount_point/$repo_name" "$mount_point/DerivedData"

link="$HOME/$repo_name"
if [ -e "$link" ] && [ ! -L "$link" ]; then
  backup="$link.pre-sync.$(date +%Y%m%d%H%M%S)"
  echo "Moving existing $link to $backup"
  mv "$link" "$backup"
fi
ln -sfn "$mount_point/$repo_name" "$link"

defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation "$mount_point/DerivedData"

echo "Data volume ready: $disk mounted at $mount_point, $link -> $mount_point/$repo_name"
REMOTE
