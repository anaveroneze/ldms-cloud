#!/bin/bash

BUCKET="ldms-telemetry"
REGION="us-east-1"

aws s3 mb "s3://$BUCKET" --region $REGION 2>/dev/null || echo "Bucket already exists"
aws s3 cp agg.conf "s3://$BUCKET/ldms/"
aws s3 cp sampler.conf "s3://$BUCKET/ldms/"