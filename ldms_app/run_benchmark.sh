#!/bin/bash
# Run the VPIC benchmark on the compute node: idle baseline, VPIC, idle baseline.
# LDMS keeps sampling throughout; the phase timestamps let analyze.py slice the
# time series afterwards.
#
# Usage:
#   ./run_benchmark.sh              60 s idle on each side, 4 MPI ranks
#   IDLE=0 ./run_benchmark.sh       calibration run, no idle padding
#   NP=8 ./run_benchmark.sh         8 ranks (keep NP a divisor of NY)
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

NP="${NP:-4}"
IDLE="${IDLE:-60}"
RUN_ID="${RUN_ID:-$(date +%Y%m%dT%H%M%S)}"

echo "=== VPIC benchmark run $RUN_ID ==="
echo "MPI ranks:      $NP"
echo "Idle baseline:  ${IDLE}s before and after"
echo ""

CMD="aws s3 cp s3://$BUCKET/$PREFIX/run_vpic_node.sh /tmp/run_vpic_node.sh --region $REGION"
CMD="$CMD && sudo -u ubuntu env HOME=/home/ubuntu NP=$NP IDLE=$IDLE RUN_ID=$RUN_ID"
CMD="$CMD BUCKET=$BUCKET RESULTS_PREFIX=$RESULTS_PREFIX REGION=$REGION"
CMD="$CMD bash /tmp/run_vpic_node.sh"

CID=$(ssm_send sampler "$CMD")
echo "Command ID: $CID"

# 2 x idle + up to 40 min of simulation
MAX_WAIT=$(( 2 * IDLE + 2400 ))
if ! poll_command_status "$CID" "$MAX_WAIT"; then
    echo ""
    echo "✗ Benchmark run failed. Full log: s3://$BUCKET/ssm-logs/$CID/"
    exit 1
fi

echo ""
show_command_output "$CID"
echo ""
echo "Run metadata and VPIC log are in s3://$BUCKET/$RESULTS_PREFIX/"
echo "Next: ./fetch_results.sh"
