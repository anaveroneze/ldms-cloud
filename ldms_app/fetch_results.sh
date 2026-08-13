#!/bin/bash
# Copy the aggregator's collected CSV and the VPIC run logs/metadata to the local
# machine, via S3. Run this BEFORE terminating the instances.
set -uo pipefail
cd "$(dirname "$0")"
source ./common.sh

OUT="results"

echo "=== Pushing the aggregator's CSV to S3 ==="
CMD="$NODE_BOOTSTRAP"
CMD="$CMD && sudo -u ubuntu bash -c 'aws s3 cp /home/ubuntu/ldms-csv s3://$BUCKET/$DATA_PREFIX/ --recursive --region $REGION'"
CID=$(ssm_send aggregator "$CMD")
echo "Command ID: $CID"
poll_command_status "$CID" 600 || echo "⚠ Continuing anyway - some data may be missing"

echo ""
echo "=== Downloading to ./$OUT ==="
mkdir -p "$OUT/csv" "$OUT/runs"
aws s3 cp "s3://$BUCKET/$DATA_PREFIX/"    "./$OUT/csv/"  --recursive --region "$REGION"
aws s3 cp "s3://$BUCKET/$RESULTS_PREFIX/" "./$OUT/runs/" --recursive --region "$REGION"

echo ""
echo "=== Local files ==="
find "$OUT" -type f -exec ls -lh {} \; | awk '{print $5, $9}'

echo ""
echo "Next: python3 analyze.py $OUT"
