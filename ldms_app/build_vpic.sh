#!/bin/bash
# Build VPIC and compile the benchmark deck on the compute node.
#
# Usage:
#   ./build_vpic.sh                          full build (~10-15 min)
#   NUM_STEP=800 ./build_vpic.sh --deck-only recompile just the deck (~30 s)
#
# num_step is compiled into the deck, so changing the run length means
# recompiling. --deck-only skips the library build.
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

DECK_ONLY=""
MAX_WAIT=1800
if [ "${1:-}" = "--deck-only" ]; then
    DECK_ONLY=" --deck-only"
    MAX_WAIT=600
fi

NX="${NX:-256}"
NY="${NY:-256}"
NZ="${NZ:-1}"
NPPC="${NPPC:-100}"
NUM_STEP="${NUM_STEP:-200}"

echo "=== Building VPIC on the compute node ==="
echo "nx=$NX ny=$NY nz=$NZ nppc=$NPPC num_step=$NUM_STEP${DECK_ONLY}"
echo "Particles: $(( NPPC * NX * NY * NZ )) macroparticles total"
echo ""

# HOME is set explicitly: sudo's env_reset normally provides it, but the node
# script derives every path from $HOME so it is worth being unambiguous.
CMD="aws s3 cp s3://$BUCKET/$PREFIX/setup_vpic.sh /tmp/setup_vpic.sh --region $REGION"
CMD="$CMD && sudo -u ubuntu env HOME=/home/ubuntu NX=$NX NY=$NY NZ=$NZ NPPC=$NPPC NUM_STEP=$NUM_STEP bash /tmp/setup_vpic.sh$DECK_ONLY"

CID=$(ssm_send sampler "$CMD")
echo "Command ID: $CID"

if ! poll_command_status "$CID" "$MAX_WAIT"; then
    echo ""
    echo "✗ VPIC build failed. The inline output above is truncated at 2500 chars;"
    echo "  the full log is at s3://$BUCKET/ssm-logs/$CID/"
    exit 1
fi

echo ""
show_command_output "$CID"
