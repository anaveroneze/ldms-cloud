#!/bin/bash
# Create the S3 bucket (if needed) and upload everything the nodes pull at runtime:
# the two LDMS daemon configs and the three scripts that run on the instances.

BUCKET="${BUCKET:-ldms-telemetry}"   # must match arn:aws:s3:::ldms-* in the IAM policy
PREFIX="app"                         # separate from the top-level repo's 'ldms/' prefix
REGION="us-east-1"

cd "$(dirname "$0")"

aws s3 mb "s3://$BUCKET" --region "$REGION" 2>/dev/null || echo "Bucket already exists"

for f in agg.conf sampler.conf setup_ldms.sh setup_vpic.sh run_vpic_node.sh; do
  aws s3 cp "$f" "s3://$BUCKET/$PREFIX/" --region "$REGION"
done

echo
echo "=== Contents of s3://$BUCKET/$PREFIX/ ==="
aws s3 ls "s3://$BUCKET/$PREFIX/" --region "$REGION"
