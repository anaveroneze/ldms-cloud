#!/bin/bash
# Shared configuration and SSM helpers, sourced by the local driver scripts.
# Not meant to be run directly.

BUCKET="${BUCKET:-ldms-telemetry}"                # must match arn:aws:s3:::ldms-* in the IAM policy
PREFIX="${PREFIX:-app}"                           # configs + node scripts
DATA_PREFIX="${DATA_PREFIX:-app-data}"            # the aggregator's collected CSV
RESULTS_PREFIX="${RESULTS_PREFIX:-app-results}"   # VPIC logs + run metadata
REGION="us-east-1"
SG_NAME="ldms-app-sg"
CLUSTER_TAG="ldms-app"
AGG_HOSTNAME="aggregator.app.internal"

# Absolute paths, because SSM runs commands as root with HOME unset: sourcing
# set-ldms-env.sh would resolve the library paths to /ovis/build and the 'sock'
# transport would fail to load. Both binaries live in sbin, not bin.
LDMS_ENV="export LD_LIBRARY_PATH=/home/ubuntu/ovis/build/lib && export ZAP_LIBPATH=/home/ubuntu/ovis/build/lib/ovis-ldms && export LDMSD_PLUGIN_LIBPATH=/home/ubuntu/ovis/build/lib/ovis-ldms"
LDMSD="/home/ubuntu/ovis/build/sbin/ldmsd"
LDMS_LS="/home/ubuntu/ovis/build/sbin/ldms_ls"

# --- SSM helpers ------------------------------------------------------------

# ssm_send <aggregator|sampler|all> <shell command>   ->  prints the command id
#
# Targets are ANDed, so filtering on LDMSCluster keeps these commands off the
# top-level meminfo cluster, which uses the same LDMSRole tag values.
# Full stdout also goes to s3://$BUCKET/ssm-logs/ because the SSM API truncates
# the inline output at 2500 characters - too short for a compiler log.
ssm_send() {
    local role=$1 cmd=$2
    local targets=("Key=tag:LDMSCluster,Values=$CLUSTER_TAG")
    [ "$role" != "all" ] && targets+=("Key=tag:LDMSRole,Values=$role")

    # The payload goes in a file and python3 does the JSON escaping. This avoids
    # the layered shell/JSON quoting that inline --parameters otherwise needs.
    local pfile
    pfile=$(mktemp)
    python3 -c 'import json,sys; json.dump({"commands":[sys.argv[1]]}, sys.stdout)' "$cmd" > "$pfile"

    aws ssm send-command \
        --region "$REGION" \
        --targets "${targets[@]}" \
        --document-name "AWS-RunShellScript" \
        --parameters "file://$pfile" \
        --output-s3-bucket-name "$BUCKET" \
        --output-s3-key-prefix "ssm-logs" \
        --query 'Command.CommandId' \
        --output text

    rm -f "$pfile"
}

# show_command_output <command id>
show_command_output() {
    aws ssm list-command-invocations \
        --region "$REGION" \
        --command-id "$1" \
        --details \
        --query 'CommandInvocations[*].[InstanceId,Status,CommandPlugins[0].Output]' \
        --output text
}

# poll_command_status <command id> [max wait seconds]
#
# Waits until every invocation has finished. Two differences from the version in
# the top-level repo: it counts all invocations rather than only the first (a
# failure on the second node used to be invisible), and it always sleeps - the
# original spun without sleeping while a command was still 'Pending'.
poll_command_status() {
    local command_id=$1 max_wait=${2:-600} elapsed=0
    local total ok bad

    echo "Monitoring command $command_id (max wait: ${max_wait}s)..."
    while [ "$elapsed" -lt "$max_wait" ]; do
        read -r total ok bad < <(aws ssm list-command-invocations \
            --region "$REGION" \
            --command-id "$command_id" \
            --query '[length(CommandInvocations), length(CommandInvocations[?Status==`Success`]), length(CommandInvocations[?Status==`Failed` || Status==`Cancelled` || Status==`TimedOut`])]' \
            --output text 2>/dev/null || echo "0 0 0")
        total=${total:-0}; ok=${ok:-0}; bad=${bad:-0}

        if [ "$bad" -gt 0 ]; then
            echo ""
            echo "✗ Command failed on $bad instance(s)"
            show_command_output "$command_id"
            return 1
        fi
        if [ "$total" -gt 0 ] && [ "$ok" -eq "$total" ]; then
            echo ""
            echo "✓ Command succeeded on $total instance(s)"
            return 0
        fi

        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    echo "⚠ Command timed out after ${max_wait}s"
    show_command_output "$command_id"
    return 2
}

# --- EC2 helpers ------------------------------------------------------------

# get_instances -> space-separated ids of this cluster's running instances
get_instances() {
    local sg_id
    sg_id=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=group-name,Values=$SG_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

    if [ -z "$sg_id" ] || [ "$sg_id" = "None" ]; then
        echo ""
        return
    fi

    # instance.group-id, not group-name: group-name only works in a default VPC
    aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=instance-state-name,Values=running" \
                  "Name=instance.group-id,Values=$sg_id" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text
}

# wait_for_ssm <expected count> - the agent registers 30-60 s after boot, and a
# tag-targeted send-command silently matches nothing until it does.
wait_for_ssm() {
    local expect=$1 n=0
    echo -n "Waiting for SSM agent registration"
    for _ in $(seq 1 60); do
        n=$(aws ssm describe-instance-information \
            --region "$REGION" \
            --filters "Key=tag:LDMSCluster,Values=$CLUSTER_TAG" \
            --query 'length(InstanceInformationList[?PingStatus==`Online`])' \
            --output text 2>/dev/null || echo 0)
        n=${n:-0}
        if [ "$n" -ge "$expect" ]; then
            echo " ($n online)"
            return 0
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    echo "⚠ Only $n/$expect instances registered with SSM"
    return 1
}
