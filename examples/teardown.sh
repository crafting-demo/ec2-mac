#!/usr/bin/env bash
#
# Tear down an EC2 Mac that was provisioned via the AWS CLI.
#
# IMPORTANT: an EC2 Mac Dedicated Host has a 24-HOUR MINIMUM allocation. `release-hosts`
# FAILS until the host is >24h old. The instance can be terminated any time, but the host
# keeps billing (~$1.08/hr for mac2.metal) until it is released.
#
# Configure via environment variables (no values are hard-coded):
#   AWS_CONFIG_FILE / AWS credentials   -- your AWS auth
#   REGION       (default us-west-2)
#   INSTANCE_ID  (required)
#   HOST_ID      (required)
#   SG_ID        (optional -- security group to delete)
#   KEY_NAME     (optional -- EC2 key pair to delete)
#
# Usage:  REGION=us-west-2 INSTANCE_ID=i-... HOST_ID=h-... SG_ID=sg-... KEY_NAME=mykey \
#           bash examples/teardown.sh
set -uo pipefail

REGION="${REGION:-us-west-2}"
: "${INSTANCE_ID:?set INSTANCE_ID}"
: "${HOST_ID:?set HOST_ID}"

echo "== terminating instance $INSTANCE_ID ($REGION) =="
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'TerminatingInstances[0].CurrentState.Name' --output text
echo "== waiting for terminated =="
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"

echo "== releasing Dedicated Host $HOST_ID (fails if <24h old) =="
aws ec2 release-hosts --region "$REGION" --host-ids "$HOST_ID" || \
  echo "  release-hosts failed (likely <24h). Retry after the 24h minimum elapses."

if [ -n "${SG_ID:-}" ]; then
  echo "== deleting security group $SG_ID =="
  aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" || true
fi
if [ -n "${KEY_NAME:-}" ]; then
  echo "== deleting key pair $KEY_NAME =="
  aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME" || true
fi

echo "Done. Remember to remove the jumpbox sandbox and (optionally) 'cs mac reset' locally."
