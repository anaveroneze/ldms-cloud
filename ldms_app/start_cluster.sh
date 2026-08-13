#!/bin/bash
# Build OVIS/LDMS on both nodes, then start the aggregator and the sampler.
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

SKIP_BUILD=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --help)
            cat <<EOF
Usage: $0 [--skip-build]

  (no flags)     build OVIS/LDMS on both nodes, then start the daemons
  --skip-build   skip the OVIS build and only (re)start the daemons

Restarting is safe either way: any running ldmsd is stopped first.
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

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
#
# Ubuntu cloud images do not ship the AWS CLI (Amazon Linux does), so it has to
# be installed before anything can be pulled from S3. Waiting on cloud-init
# first avoids racing it for the dpkg lock, and also guarantees the hostname
# from user-data has been applied - the aggregator matches advertising nodes on
# their hostname, so starting before that lands would break discovery.
if $SKIP_BUILD; then
    echo "Step 1: Skipped (--skip-build)"
else
    echo "Step 1: Building OVIS/LDMS on all nodes..."
    CMD="cloud-init status --wait || true"
    CMD="$CMD; export DEBIAN_FRONTEND=noninteractive"
    CMD="$CMD; apt-get update -qq && apt-get install -y -qq awscli"
    CMD="$CMD && aws s3 cp s3://$BUCKET/$PREFIX/setup_ldms.sh /tmp/setup_ldms.sh --region $REGION"
    CMD="$CMD && sudo -u ubuntu bash /tmp/setup_ldms.sh"
    CID=$(ssm_send all "$CMD")
    echo "Command ID: $CID"
    if ! poll_command_status "$CID" 2400; then
        echo "✗ OVIS build failed on one or more nodes"
        exit 1
    fi
fi
echo ""

# Step 2: start the aggregator.
# -m 1g is required: the 512 MB default overruns its buffer and the daemon crashes.
echo "Step 2: Starting aggregator..."
FETCH="sudo -u ubuntu bash -c '$LDMS_ENV && aws s3 cp s3://$BUCKET/$PREFIX/agg.conf /home/ubuntu/agg.conf --region $REGION'"
# The daemon is detached in a brace group with all three fds redirected, so the
# SSM invocation returns instead of hanging; pgrep then proves it survived.
#
# The exports MUST sit inside the brace group. '&&' binds tighter than '&', so
# writing 'EXPORTS && { ldmsd; } > file &' backgrounds the whole list and forks
# before the redirection reaches the brace group - the background subshell then
# keeps SSM's stdout/stderr pipes open for as long as ldmsd lives, and SSM waits
# for those pipes to close, so the invocation sits in InProgress until it times out.
START="sudo -u ubuntu bash -c 'pkill -x ldmsd || true; sleep 1; { $LDMS_ENV && $LDMSD -x sock:10444 -c /home/ubuntu/agg.conf -l /tmp/agg.log -v INFO -m 1g ; } > /tmp/agg.out 2>&1 < /dev/null & sleep 5; pgrep -x ldmsd'"
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
# Here the readiness loop runs in the foreground and only the redirected brace
# group is backgrounded (note the ';' before '{'), so no SSM pipe is held open.
START="sudo -u ubuntu bash -c 'pkill -x ldmsd || true; sleep 1; $LDMS_ENV && until $LDMS_LS -x sock -p 10444 -h $AGG_HOSTNAME &>/dev/null; do echo Waiting for aggregator...; sleep 2; done; { $LDMSD -x sock:10444 -c /home/ubuntu/samplerd.conf -l /tmp/sampler.log -v INFO ; } > /tmp/sampler.out 2>&1 < /dev/null & sleep 5; pgrep -x ldmsd'"
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
