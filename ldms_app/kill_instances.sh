#!/bin/bash
# Stop the LDMS daemons and any running VPIC process, then terminate the
# instances of this cluster only (matched by the ldms-app security group).
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

STOP_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --stop)
            STOP_ONLY=true
            shift
            ;;
        --help)
            cat <<EOF
Usage: $0 [--stop]

  (no flags)  stop the daemons, then terminate the instances
  --stop      stop the LDMS daemons and any VPIC run, leave the instances up
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

INSTANCE_IDS=($(get_instances))
if [ ${#INSTANCE_IDS[@]} -eq 0 ]; then
    echo "No running instances found in security group '$SG_NAME'"
    exit 0
fi
echo "Instances in this cluster: ${INSTANCE_IDS[*]}"
echo ""

echo "=== Stopping LDMS daemons and any VPIC run ==="
# The bracketed first character keeps each pattern from matching the shell that
# is running this very command line, which would make pkill kill itself.
CID=$(ssm_send all "pkill -x ldmsd || true; pkill -f '[h]arris_bench' || true; pkill -f '[m]pirun' || true; echo stopped")
poll_command_status "$CID" 120 || echo "⚠ Daemon stop did not confirm cleanly"
echo ""

if $STOP_ONLY; then
    echo "✓ Daemons stopped. Instances left running (re-run start_cluster.sh to restart)."
    exit 0
fi

echo "=== Terminating instances ==="
aws ec2 terminate-instances \
    --region "$REGION" \
    --instance-ids "${INSTANCE_IDS[@]}" \
    --query 'TerminatingInstances[].{InstanceId:InstanceId,State:CurrentState.Name}' \
    --output table

aws ec2 wait instance-terminated \
    --region "$REGION" \
    --instance-ids "${INSTANCE_IDS[@]}"

echo "✓ All instances terminated"
