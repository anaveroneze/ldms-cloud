#!/bin/bash
set -euo pipefail

# Configuration
SG_NAME="cluster-sg"
STOP_ONLY=false
export AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --stop) STOP_ONLY=true; shift ;;
        --help)
            cat <<EOF
Usage: $0 [OPTIONS]
Stop and/or terminate LDMS cluster instances in security group '$SG_NAME'.

OPTIONS:
  --stop        Stop LDMS daemons only (do not terminate instances)
  --help        Show this help message
EOF
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Get security group ID
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text)
[[ -z "$SG_ID" || "$SG_ID" == "None" ]] && { echo "✗ Security group '$SG_NAME' not found"; exit 1; }

# Get all running instances in the security group
INSTANCE_IDS=($(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=instance.group-id,Values=$SG_ID" --query 'Reservations[].Instances[].InstanceId' --output text))
[[ ${#INSTANCE_IDS[@]} -eq 0 ]] && { echo "No running instances found in security group '$SG_NAME'"; exit 0; }

echo -e "Found ${#INSTANCE_IDS[@]} running instance(s): ${INSTANCE_IDS[*]}\n"

# Step 1: Gracefully stop LDMS daemons via SSM
echo "Step 1: Stopping LDMS daemons via SSM..."
STOP_CMD_ID=$(aws ssm send-command --instance-ids "${INSTANCE_IDS[@]}" --document-name "AWS-RunShellScript" --parameters 'commands=["pkill -x ldmsd || true"]' --query 'Command.CommandId' --output text)
echo "Stop command ID: $STOP_CMD_ID"

# Poll for completion (max 60 seconds)
for _ in {1..30}; do
    STATUS=$(aws ssm list-command-invocations --command-id "$STOP_CMD_ID" --query 'CommandInvocations[0].Status' --output text 2>/dev/null || echo "")
    [[ "$STATUS" =~ ^(Success|Failed)$ ]] && break || { echo -n "."; sleep 2; }
done
echo -e "\n✓ Daemon stop command completed (status: ${STATUS:-Timed Out})\n"

$STOP_ONLY && { echo "✓ LDMS daemons stopped. Instances remain running."; exit 0; }

# Step 2: Terminate instances
echo -e "Step 2: Terminating instances...\nTerminating: ${INSTANCE_IDS[*]}"
aws ec2 terminate-instances --instance-ids "${INSTANCE_IDS[@]}" >/dev/null
aws ec2 wait instance-terminated --instance-ids "${INSTANCE_IDS[@]}"
echo "✓ All instances terminated"