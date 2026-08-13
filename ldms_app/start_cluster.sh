#!/bin/bash
# Build OVIS/LDMS on both nodes, then start the aggregator and the sampler.
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

echo "=== LDMS application-monitoring cluster startup ==="
echo "Region:        $REGION"
echo "Cluster tag:   LDMSCluster=$CLUSTER_TAG"
echo "Config source: s3://$BUCKET/$PREFIX"
echo ""

INSTANCES=$(get_instances)
if [ -z "$INSTANCES" ]; then
    echo "✗ No running instances found in security group '$SG_NAME'"
    exit 1
fi
COUNT=$(echo "$INSTANCES" | wc -w)
echo "Found $COUNT running instance(s): $INSTANCES"

wait_for_ssm "$COUNT" || exit 1
echo ""

# Step 1: build OVIS/LDMS on every node (~10-15 min, compiles from source)
echo "Step 1: Building OVIS/LDMS on all nodes..."
CMD="aws s3 cp s3://$BUCKET/$PREFIX/setup_ldms.sh /tmp/setup_ldms.sh --region $REGION"
CMD="$CMD && sudo -u ubuntu bash /tmp/setup_ldms.sh"
CID=$(ssm_send all "$CMD")
echo "Command ID: $CID"
if ! poll_command_status "$CID" 2400; then
    echo "✗ OVIS build failed on one or more nodes"
    exit 1
fi
echo ""

# Step 2: start the aggregator.
# -m 1g is required: the 512 MB default overruns its buffer and the daemon crashes.
echo "Step 2: Starting aggregator..."
FETCH="sudo -u ubuntu bash -c '$LDMS_ENV && aws s3 cp s3://$BUCKET/$PREFIX/agg.conf /home/ubuntu/agg.conf --region $REGION'"
# The daemon is detached in a brace group with all three fds redirected, so the
# SSM invocation returns instead of hanging; pgrep then proves it survived.
START="sudo -u ubuntu bash -c '$LDMS_ENV && { $LDMSD -x sock:10444 -c /home/ubuntu/agg.conf -l /tmp/agg.log -v INFO -m 1g ; } > /tmp/agg.out 2>&1 < /dev/null & sleep 5; pgrep -x ldmsd'"
CID=$(ssm_send aggregator "$FETCH && $START")
echo "Command ID: $CID"
if ! poll_command_status "$CID" 300; then
    echo "✗ Aggregator startup failed"
    exit 1
fi
echo ""

echo "Waiting for aggregator to stabilize..."
sleep 5
echo ""

# Step 3: start the sampler on the compute node.
# It substitutes its own hostname into the __NODE__ placeholder, then waits until
# the aggregator answers before starting.
echo "Step 3: Starting sampler with readiness check..."
PREPARE="sudo -u ubuntu bash -c '$LDMS_ENV && aws s3 cp s3://$BUCKET/$PREFIX/sampler.conf /tmp/sampler.conf --region $REGION && sed s/__NODE__/\$(hostname)/g /tmp/sampler.conf > /home/ubuntu/samplerd.conf'"
START="sudo -u ubuntu bash -c '$LDMS_ENV && until $LDMS_LS -x sock -p 10444 -h $AGG_HOSTNAME &>/dev/null; do echo Waiting for aggregator...; sleep 2; done; { $LDMSD -x sock:10444 -c /home/ubuntu/samplerd.conf -l /tmp/sampler.log -v INFO ; } > /tmp/sampler.out 2>&1 < /dev/null & sleep 5; pgrep -x ldmsd'"
CID=$(ssm_send sampler "$PREPARE && $START")
echo "Command ID: $CID"
if ! poll_command_status "$CID" 600; then
    echo "✗ Sampler startup failed"
    exit 1
fi
echo ""

# Step 4: confirm all three metric sets reached the aggregator and are being stored
echo "Step 4: Verifying collection..."
sleep 10
VERIFY="sudo -u ubuntu bash -c '$LDMS_ENV && echo METRIC_SETS: && $LDMS_LS -x sock -p 10444 -h localhost; echo; echo CSV_FILES:; ls -l /home/ubuntu/ldms-csv/ldms_data/ 2>/dev/null || echo none yet'"
CID=$(ssm_send aggregator "$VERIFY")
poll_command_status "$CID" 120 >/dev/null || true
show_command_output "$CID"
echo ""

# Step 5: surface any plugin load errors on the sampler side
echo "Step 5: Checking the sampler log for plugin errors..."
CHECK="sudo -u ubuntu bash -c 'grep -iE \"error|fail|cannot|not found\" /tmp/sampler.log | tail -20 || echo \"no errors in /tmp/sampler.log\"'"
CID=$(ssm_send sampler "$CHECK")
poll_command_status "$CID" 120 >/dev/null || true
show_command_output "$CID"
echo ""

echo "=== What to look for ==="
echo "  METRIC_SETS should list three sets: compute-1/meminfo, compute-1/vmstat, compute-1/procstat"
echo "  CSV_FILES should list three files under /home/ubuntu/ldms-csv/ldms_data/"
echo "  If a set is missing, check the PLUGIN_ERRORS output above and see README.md"
