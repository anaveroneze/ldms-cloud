#!/bin/bash

set -euo pipefail

# Configuration
SG_NAME="cluster-sg"
S3_BUCKET="${S3_BUCKET:-ldms-telemetry}"
S3_PREFIX="ldms"
AGG_HOSTNAME="aggregator.cluster.internal"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}"

# Helper function to get security group ID
get_sg_id() {
    aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=group-name,Values=$SG_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text
}

# Helper function to get instances in the security group
get_instances() {
    local sg_id=$1
    aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=instance-state-name,Values=running" \
                  "Name=instance.group-id,Values=$sg_id" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text
}

# Helper function to poll SSM command status
poll_command_status() {
    local command_id=$1
    local max_wait=${2:-600}  # 10 minutes default
    local elapsed=0

    echo "Monitoring command $command_id (max wait: ${max_wait}s)..."

    while [[ $elapsed -lt $max_wait ]]; do
        local status=$(aws ssm list-command-invocations \
            --region "$REGION" \
            --command-id "$command_id" \
            --query 'CommandInvocations[0].Status' \
            --output text 2>/dev/null || echo "")

        if [[ "$status" == "Success" ]]; then
            echo "✓ Command succeeded"
            return 0
        elif [[ "$status" == "Failed" ]]; then
            echo "✗ Command failed"
            # Display error output
            aws ssm list-command-invocations \
                --region "$REGION" \
                --command-id "$command_id" \
                --details \
                --query 'CommandInvocations[*].[InstanceId,Status,CommandPlugins[0].Output]' \
                --output table
            return 1
        elif [[ "$status" == "InProgress" ]]; then
            echo -n "."
            sleep 5
            ((elapsed += 5))
        fi
    done

    echo ""
    echo "⚠ Command timed out after ${max_wait}s"
    return 2
}

# Main script starts here
echo "=== LDMS Cluster Startup ==="
echo "Region: $REGION"
echo "Security group: $SG_NAME"
echo "S3 bucket: s3://$S3_BUCKET/$S3_PREFIX"

# Get security group ID
SG_ID=$(get_sg_id)
if [[ -z "$SG_ID" ]] || [[ "$SG_ID" == "None" ]]; then
    echo "✗ Security group '$SG_NAME' not found"
    exit 1
fi
echo "Security group ID: $SG_ID"

# Get instance IDs
INSTANCES=$(get_instances "$SG_ID")
if [[ -z "$INSTANCES" ]]; then
    echo "✗ No running instances found in security group '$SG_NAME'"
    exit 1
fi

INSTANCE_COUNT=$(echo "$INSTANCES" | wc -w)
echo "Found $INSTANCE_COUNT running instance(s): $INSTANCES"
echo ""

# Step 1: Run setup.sh on all instances via SSM
echo "Step 1: Running setup.sh on all instances..."
SETUP_CMD_ID=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids $INSTANCES \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["cd /tmp && curl -o setup.sh https://raw.githubusercontent.com/anaveroneze/ldms-cloud/main/setup.sh && sudo -u ubuntu bash setup.sh"]' \
    --query 'Command.CommandId' \
    --output text)

echo "Setup command ID: $SETUP_CMD_ID"
if ! poll_command_status "$SETUP_CMD_ID" 1800; then
    echo "✗ Setup failed on one or more instances"
    exit 1
fi
echo "✓ Setup complete on all instances"
echo ""

# Step 2: Start the aggregator
echo "Step 2: Starting aggregator..."
AGG_CMD_ID=$(aws ssm send-command \
    --region "$REGION" \
    --targets "Key=tag:LDMSRole,Values=aggregator" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["sudo -u ubuntu bash -c \"{ export LD_LIBRARY_PATH=/home/ubuntu/ovis/build/lib && export ZAP_LIBPATH=/home/ubuntu/ovis/build/lib/ovis-ldms && export LDMSD_PLUGIN_LIBPATH=/home/ubuntu/ovis/build/lib/ovis-ldms && aws s3 cp s3://'$S3_BUCKET'/'$S3_PREFIX'/agg.conf /home/ubuntu/agg.conf && /home/ubuntu/ovis/build/sbin/ldmsd -x sock:10444 -c /home/ubuntu/agg.conf -l /tmp/agg.log -v INFO -m 1g ; } > /tmp/agg.out 2>&1 < /dev/null & sleep 5; pgrep -f ldmsd\""]' \
    --query 'Command.CommandId' \
    --output text)

echo "Aggregator command ID: $AGG_CMD_ID"
if ! poll_command_status "$AGG_CMD_ID"; then
    echo "✗ Aggregator startup failed"
    exit 1
fi
echo "✓ Aggregator started"
echo ""

# Step 3: Wait a bit for aggregator to stabilize
echo "Waiting for aggregator to stabilize..."
sleep 5

# Step 4: Start the connectors
echo "Step 3: Starting connectors with readiness check..."
CONN_CMD_ID=$(aws ssm send-command \
    --region "$REGION" \
    --targets "Key=tag:LDMSRole,Values=connector" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["sudo -u ubuntu bash -c \"export LD_LIBRARY_PATH=/home/ubuntu/ovis/build/lib && export ZAP_LIBPATH=/home/ubuntu/ovis/build/lib/ovis-ldms && export LDMSD_PLUGIN_LIBPATH=/home/ubuntu/ovis/build/lib/ovis-ldms && aws s3 cp s3://'$S3_BUCKET'/'$S3_PREFIX'/samplerd-\\$(hostname).conf /home/ubuntu/samplerd.conf && until /home/ubuntu/ovis/build/sbin/ldms_ls -x sock -p 10444 -h '$AGG_HOSTNAME' &>/dev/null; do echo Waiting for aggregator...; sleep 2; done; { /home/ubuntu/ovis/build/sbin/ldmsd -x sock:10444 -c /home/ubuntu/samplerd.conf -l /tmp/sampler.log -v INFO ; } > /tmp/sampler.out 2>&1 < /dev/null & sleep 5; pgrep -f ldmsd\""]' \
    --query 'Command.CommandId' \
    --output text)

echo "Connector command ID: $CONN_CMD_ID"
if ! poll_command_status "$CONN_CMD_ID"; then
    echo "✗ Connector startup failed"
    exit 1
fi
echo "✓ Connectors started"
echo ""

# Step 5: Verify cluster is healthy
echo "Step 4: Verifying cluster health..."
VERIFY_CMD_ID=$(aws ssm send-command \
    --region "$REGION" \
    --targets "Key=tag:LDMSRole,Values=aggregator" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["sudo -u ubuntu bash -c \"export LD_LIBRARY_PATH=/home/ubuntu/ovis/build/lib && export ZAP_LIBPATH=/home/ubuntu/ovis/build/lib/ovis-ldms && export LDMSD_PLUGIN_LIBPATH=/home/ubuntu/ovis/build/lib/ovis-ldms && echo METRIC_SETS: && /home/ubuntu/ovis/build/sbin/ldms_ls -x sock -p 10444 -h localhost -v; echo; echo LDMSD_PROCESSES:; ps aux | grep ldmsd | grep -v grep\""]' \
    --query 'Command.CommandId' \
    --output text)

echo "Verification command ID: $VERIFY_CMD_ID"
sleep 2
aws ssm list-command-invocations \
    --command-id "$VERIFY_CMD_ID" \
    --details \
    --query 'CommandInvocations[*].[InstanceId,CommandPlugins[0].Output]' \
    --output text

echo ""
echo "=== LDMS Cluster Started Successfully ==="
echo ""
echo "Next steps:"
echo "  - Monitor via: aws ssm list-command-invocations --command-id <id> --details"
echo "  - SSH to aggregator: ssh -i ~/.ssh/ana.pem ubuntu@<AGG_PUBLIC_IP>"
echo "  - Query metrics: ldms_ls -x sock -p 10444 -h $AGG_HOSTNAME -v"
echo "  - Stop cluster: $0 --stop"
echo ""
