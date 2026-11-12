#!/usr/bin/env bash
#
# Find (and optionally clean up) EC2 Mac resources left behind by deleted sandboxes.
#
# Every resource the Terraform module creates is tagged ManagedBy=crafting-sandbox,
# SandboxID=<id> and Name=crafting-mac-*. A resource is ORPHANED when its SandboxID
# no longer appears in `cs sandbox list`. Resources of live sandboxes are never
# touched -- if a sandbox is stuck deleting because its host was <24h old, retry the
# sandbox delete instead.
#
# Dry run by default: prints what it found and what it would do. With --apply it,
# for orphaned sandboxes only:
#   1. terminates instances (and waits for termination),
#   2. deletes data volumes and security groups,
#   3. releases Dedicated Hosts that are past the 24-hour minimum allocation.
# Hosts that are still too young (or still being scrubbed) are reported; re-run later.
#
# Requirements: aws CLI, jq, and `cs` logged in with access to every org whose
# sandboxes use this AWS account.
#
# Configure via environment variables:
#   AWS_CONFIG_FILE / AWS credentials   -- your AWS auth
#   REGION   (required, or AWS_REGION / AWS_DEFAULT_REGION)
#   ORGS     (optional) space-separated Crafting orgs sharing this AWS account;
#            defaults to the current `cs` org
#
# Usage:  REGION=us-west-2 bash examples/sweep-orphans.sh [--apply]
set -euo pipefail

apply=false
case "${1:-}" in
  "") ;;
  --apply) apply=true ;;
  *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac

REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
: "${REGION:?set REGION}"
MIN_HOST_AGE_SECONDS=$((24 * 3600))

aws_ec2() { aws ec2 --region "$REGION" --output json "$@"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "== listing live sandboxes =="
: >"$tmp/live"
if [ -n "${ORGS:-}" ]; then
  for org in $ORGS; do
    SANDBOX_ORG="$org" cs sandbox list -o json | jq -r '.[].meta.id' >>"$tmp/live"
  done
else
  cs sandbox list -o json | jq -r '.[].meta.id' >>"$tmp/live"
fi
echo "  $(wc -l <"$tmp/live" | tr -d ' ') live sandboxes"

# Empty fields become "-": tab is IFS whitespace, so `read` would collapse them.
tag_fn='def tag(k): ((.Tags // []) | map(select(.Key == k)) | first | .Value) // "";
  def row: map(tostring | if . == "" then "-" else . end) | @tsv;'
tag_filters=(Name=tag:ManagedBy,Values=crafting-sandbox "Name=tag:Name,Values=crafting-mac-*")

echo "== listing tagged EC2 Mac resources in $REGION =="
# One TSV row per resource: kind, id, sandbox id, sandbox name, state, host age (s).
{
  aws_ec2 describe-hosts --filter "${tag_filters[@]}" | jq -r "$tag_fn"'
    .Hosts[] | select(.State | startswith("released") | not)
    | ["host", .HostId, tag("SandboxID"), tag("Sandbox"), .State,
       (now - (.AllocationTime | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) | floor)]
    | row'
  aws_ec2 describe-instances --filters "${tag_filters[@]}" \
    Name=instance-state-name,Values=pending,running,stopping,stopped | jq -r "$tag_fn"'
    .Reservations[].Instances[]
    | ["instance", .InstanceId, tag("SandboxID"), tag("Sandbox"), .State.Name, ""] | row'
  aws_ec2 describe-volumes --filters "${tag_filters[@]}" | jq -r "$tag_fn"'
    .Volumes[] | ["volume", .VolumeId, tag("SandboxID"), tag("Sandbox"), .State, ""] | row'
  aws_ec2 describe-security-groups --filters "${tag_filters[@]}" | jq -r "$tag_fn"'
    .SecurityGroups[] | ["security-group", .GroupId, tag("SandboxID"), tag("Sandbox"), "", ""] | row'
} >"$tmp/resources"

if [ ! -s "$tmp/resources" ]; then
  echo "  nothing found"
  exit 0
fi

instances=() volumes=() groups=() hosts=() young_hosts=()
printf '%-10s %-16s %-24s %-22s %-14s %s\n' STATUS KIND ID SANDBOX STATE NOTE
while IFS=$'\t' read -r kind id sandbox_id sandbox_name state age; do
  note=""
  if [ "$sandbox_id" = "-" ]; then
    status=untagged
    note="no SandboxID tag; skipped"
  elif grep -qxF "$sandbox_id" "$tmp/live"; then
    status=live
  else
    status=orphaned
    case "$kind" in
      instance) instances+=("$id") ;;
      volume) volumes+=("$id") ;;
      security-group) groups+=("$id") ;;
      host)
        if [ "$age" -ge "$MIN_HOST_AGE_SECONDS" ]; then
          hosts+=("$id")
        else
          young_hosts+=("$id")
          note="releasable in $(((MIN_HOST_AGE_SECONDS - age + 3599) / 3600))h"
        fi
        ;;
    esac
  fi
  printf '%-10s %-16s %-24s %-22s %-14s %s\n' "$status" "$kind" "$id" "$sandbox_name" "$state" "$note"
done <"$tmp/resources"

total=$((${#instances[@]} + ${#volumes[@]} + ${#groups[@]} + ${#hosts[@]}))
echo
echo "Orphaned: ${#instances[@]} instance(s), ${#volumes[@]} volume(s), ${#groups[@]} security group(s), ${#hosts[@]} releasable host(s), ${#young_hosts[@]} host(s) under 24h"

if ! $apply; then
  [ "$total" -gt 0 ] && echo "Dry run. Re-run with --apply to clean up the orphaned resources above."
  exit 0
fi
if [ "$total" -eq 0 ]; then
  echo "Nothing to clean up yet."
  exit 0
fi

if [ ${#instances[@]} -gt 0 ]; then
  echo "== terminating instances: ${instances[*]} =="
  aws_ec2 terminate-instances --instance-ids "${instances[@]}" >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids "${instances[@]}"
fi

for id in ${volumes[@]+"${volumes[@]}"}; do
  echo "== deleting volume $id =="
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$id" &&
    aws_ec2 delete-volume --volume-id "$id" >/dev/null ||
    echo "  failed to delete $id; re-run later"
done

for id in ${groups[@]+"${groups[@]}"}; do
  echo "== deleting security group $id =="
  aws_ec2 delete-security-group --group-id "$id" >/dev/null ||
    echo "  failed to delete $id (network interfaces may still be detaching); re-run later"
done

if [ ${#hosts[@]} -gt 0 ]; then
  echo "== releasing Dedicated Hosts: ${hosts[*]} =="
  aws_ec2 release-hosts --host-ids "${hosts[@]}" | jq -r '
    (.Successful[]? | "  released \(.)"),
    (.Unsuccessful[]? | "  not released \(.ResourceId): \(.Error.Message) (re-run later; hosts are scrubbed after termination)")'
fi

if [ ${#young_hosts[@]} -gt 0 ]; then
  echo "Hosts under the 24-hour minimum were left in place: ${young_hosts[*]-}. Re-run after they age out."
fi
