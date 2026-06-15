#!/bin/bash

set -euo pipefail

# Configuration
SG_NAME="cluster-sg"
STOP_ONLY=false
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --stop)
            STOP_ONLY=true
            shift
            ;;
        --help)
            cat <<EOF
Usage: $0 [OPTIONS]

Stop and/or terminate LDMS cluster instances in security group '$SG_NAME'.

OPTIONS:
  --stop        Stop LDMS daemons only (do not terminate instances)
  --help        Show this help message

Default behavior: Stop daemons gracefully, then terminate instances.
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Get security group ID
SG_ID=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

if [[ -z "$SG_ID" ]] || [[ "$SG_ID" == "None" ]]; then
    echo "✗ Security group '$SG_NAME' not found"
    exit 1
fi

# Get all running instances in the security group
mapfile -t INSTANCE_IDS < <(
    aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=instance-state-name,Values=running" \
                  "Name=instance.group-id,Values=$SG_ID" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text | tr ' ' '\n'
)

if [ ${#INSTANCE_IDS[@]} -eq 0 ]; then
    echo "No running instances found in security group '$SG_NAME'"
    exit 0
fi

echo "Found ${#INSTANCE_IDS[@]} running instance(s): ${INSTANCE_IDS[*]}"
echo ""

# Step 1: Gracefully stop LDMS daemons via SSM (pkill -x avoids matching this command's own wrapper)
echo "Step 1: Stopping LDMS daemons via SSM..."
STOP_CMD_ID=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "${INSTANCE_IDS[@]}" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["pkill -x ldmsd || true"]' \
    --query 'Command.CommandId' \
    --output text)

echo "Stop command ID: $STOP_CMD_ID"

# Poll for completion
ELAPSED=0
MAX_WAIT=60
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    STATUS=$(aws ssm list-command-invocations \
        --region "$REGION" \
        --command-id "$STOP_CMD_ID" \
        --query 'CommandInvocations[0].Status' \
        --output text 2>/dev/null || echo "")

    if [[ "$STATUS" == "Success" ]] || [[ "$STATUS" == "Failed" ]]; then
        echo "✓ Daemon stop command completed (status: $STATUS)"
        break
    fi

    echo -n "."
    sleep 2
    ((ELAPSED += 2))
done

echo ""
sleep 2

if [ "$STOP_ONLY" = true ]; then
    echo "✓ LDMS daemons stopped. Instances remain running."
    exit 0
fi

# Step 2: Terminate instances
echo "Step 2: Terminating instances..."
echo "Terminating: ${INSTANCE_IDS[*]}"
aws ec2 terminate-instances --region "$REGION" --instance-ids "${INSTANCE_IDS[@]}" >/dev/null
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "${INSTANCE_IDS[@]}"
echo "✓ All instances terminated" 