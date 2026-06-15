#!/bin/bash
# Copy the aggregator's CSV output to CloudShell via S3 (no SSH needed).
#   aggregator:/home/ubuntu/ldms-csv  ->  s3://$BUCKET/ldms-data/  ->  ./ldms-data/

set -uo pipefail

REGION="us-east-1"
BUCKET="ldms-telemetry"

echo "=== Pushing aggregator CSV to S3 ==="
CID=$(aws ssm send-command --region "$REGION" \
  --targets "Key=tag:LDMSRole,Values=aggregator" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo -u ubuntu bash -c \"aws s3 cp /home/ubuntu/ldms-csv s3://'"$BUCKET"'/ldms-data/ --recursive\""]' \
  --query Command.CommandId --output text)
echo "cmd: $CID"

st=""
for _ in $(seq 1 60); do
  st=$(aws ssm list-command-invocations --region "$REGION" --command-id "$CID" \
    --query 'CommandInvocations[0].Status' --output text 2>/dev/null || echo "")
  [[ "$st" == Success || "$st" == Failed ]] && break
  sleep 2
done
echo "status: $st"
aws ssm list-command-invocations --region "$REGION" --command-id "$CID" --details \
  --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text

echo ""
echo "=== Downloading from S3 to CloudShell (./ldms-data) ==="
mkdir -p ldms-data
aws s3 cp "s3://$BUCKET/ldms-data/" ./ldms-data/ --recursive

echo ""
echo "=== Local files ==="
ls -R ldms-data
