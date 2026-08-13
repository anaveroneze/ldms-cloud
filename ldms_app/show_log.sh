#!/bin/bash
# Print the full, untruncated output of a past SSM command.
#
# The inline output in the SSM API response is capped at 2500 characters, so the
# scripts also direct every command's output to s3://$BUCKET/ssm-logs/. This
# fetches it back.
#
# Usage: ./show_log.sh <command-id> [tail-lines]
set -uo pipefail
cd "$(dirname "$0")"
source ./common.sh

if [ $# -lt 1 ]; then
    echo "Usage: $0 <command-id> [tail-lines]"
    echo ""
    echo "The command ID is printed by every script, e.g. 'Command ID: 8c72740d-...'"
    exit 1
fi

CID=$1
LINES=${2:-200}

echo "=== Status ==="
aws ssm list-command-invocations \
    --region "$REGION" \
    --command-id "$CID" \
    --query 'CommandInvocations[*].[InstanceId,Status,CommandPlugins[0].ResponseCode]' \
    --output table

echo ""
echo "=== Full output from S3 ==="
fetch_ssm_log "$CID" "$LINES"
