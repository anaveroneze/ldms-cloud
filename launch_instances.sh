#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Variables
# ----------------------------
INSTANCE_TYPE="t2.medium"
SG_NAME="cluster-sg"
HOSTED_ZONE_NAME="cluster.internal"
NUM_SAMPLERS="${NUM_SAMPLERS:-2}"   # number of sampler nodes; scale here (or via env)

# 1 aggregator + NUM_SAMPLERS samplers (samplerd-1 .. samplerd-N)
INSTANCE_NAMES=("aggregator")
for i in $(seq 1 "$NUM_SAMPLERS"); do INSTANCE_NAMES+=("samplerd-$i"); done

# ----------------------------
# Region
# ----------------------------
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}"
if [ -z "${REGION}" ] || [ "${REGION}" = "None" ]; then
  echo "Could not determine AWS region."
  exit 1
fi

echo "REGION: $REGION"

# ----------------------------
# Get latest Ubuntu 22.04 AMI
# ----------------------------
AMI_PARAM="/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"

AMI_ID=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "$AMI_PARAM" \
  --query 'Parameter.Value' \
  --output text)

echo "AMI_ID: $AMI_ID"

# ----------------------------
# Use default VPC + one default subnet
# ----------------------------
VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' \
  --output text)

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "No default VPC found."
  exit 1
fi

echo "VPC_ID: $VPC_ID"

SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' \
  --output text)

if [ "$SUBNET_ID" = "None" ] || [ -z "$SUBNET_ID" ]; then
  echo "No default subnet found in VPC $VPC_ID."
  exit 1
fi

echo "SUBNET_ID: $SUBNET_ID"

# ----------------------------
# Ensure VPC DNS attributes are enabled
# ----------------------------
aws ec2 modify-vpc-attribute \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --enable-dns-support "{\"Value\":true}"

aws ec2 modify-vpc-attribute \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames "{\"Value\":true}"

echo "Enabled VPC DNS support and DNS hostnames"

# ----------------------------
# Create or reuse security group
# ----------------------------
SG_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "$SG_NAME" \
    --description "Security group for EC2 cluster nodes" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text)
fi

echo "Using Security Group: $SG_ID"

# LDMS daemon port 10444 - internal to cluster members only
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$SG_ID" \
  --ip-permissions "[
    {
      \"IpProtocol\": \"tcp\",
      \"FromPort\": 10444,
      \"ToPort\": 10444,
      \"UserIdGroupPairs\": [{\"GroupId\": \"$SG_ID\"}]
    }
  ]" 2>/dev/null || true

# All traffic between cluster members only
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$SG_ID" \
  --ip-permissions "[
    {
      \"IpProtocol\": \"-1\",
      \"UserIdGroupPairs\": [{\"GroupId\": \"$SG_ID\"}]
    }
  ]" 2>/dev/null || true

# ----------------------------
# Create or reuse Route 53 private hosted zone
# ----------------------------
HZ_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$HOSTED_ZONE_NAME" \
  --query "HostedZones[?Name == '${HOSTED_ZONE_NAME}.'] | [?Config.PrivateZone == \`true\`] | [0].Id" \
  --output text)

if [ "$HZ_ID" = "None" ] || [ -z "$HZ_ID" ]; then
  HZ_ID=$(aws route53 create-hosted-zone \
    --name "$HOSTED_ZONE_NAME" \
    --caller-reference "$(date +%s)" \
    --hosted-zone-config "Comment=Private zone for EC2 cluster,PrivateZone=true" \
    --vpc "VPCRegion=$REGION,VPCId=$VPC_ID" \
    --query 'HostedZone.Id' \
    --output text)
else
  # Associate the VPC in case the zone exists but is not yet attached
  aws route53 associate-vpc-with-hosted-zone \
    --hosted-zone-id "$HZ_ID" \
    --vpc "VPCRegion=$REGION,VPCId=$VPC_ID" 2>/dev/null || true
fi

HZ_ID="${HZ_ID##*/}"
echo "Using Hosted Zone: $HZ_ID ($HOSTED_ZONE_NAME)"

# ----------------------------
# Create or reuse IAM role for SSM and S3 access
# ----------------------------
ROLE_NAME="ldms-cluster-role"
INSTANCE_PROFILE_NAME="ldms-cluster-profile"

echo "Setting up IAM role and instance profile..."

# Check if role exists
if ! aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "Creating IAM role: $ROLE_NAME"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "Service": "ec2.amazonaws.com"
          },
          "Action": "sts:AssumeRole"
        }
      ]
    }' >/dev/null

  # Attach SSM managed policy
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

  # Attach S3 policy: read configs + write collected CSV data back to S3
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "ldms-s3-access" \
    --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": ["s3:GetObject", "s3:PutObject"],
          "Resource": "arn:aws:s3:::ldms-*/*"
        },
        {
          "Effect": "Allow",
          "Action": ["s3:ListBucket"],
          "Resource": "arn:aws:s3:::ldms-*"
        }
      ]
    }' >/dev/null

  echo "Waiting for role propagation (10s)..."
  sleep 10
fi

# Create instance profile if it doesn't exist
if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &>/dev/null; then
  echo "Creating instance profile: $INSTANCE_PROFILE_NAME"
  aws iam create-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null

  aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$ROLE_NAME" >/dev/null

  echo "Waiting for instance profile propagation (10s)..."
  sleep 10
fi

echo "✓ Using IAM instance profile: $INSTANCE_PROFILE_NAME"

# ----------------------------
# Launch instances
# Configure OS hostname when the instances boot to set the short and the
# full hostname (fqdn), and use the file info when launching the instances
# ----------------------------
INSTANCE_IDS=()

for INSTANCE_NAME in "${INSTANCE_NAMES[@]}"; do

  USER_DATA_FILE=$(mktemp)
  cat > "$USER_DATA_FILE" <<EOF
#cloud-config
preserve_hostname: false
hostname: ${INSTANCE_NAME}
fqdn: ${INSTANCE_NAME}.${HOSTED_ZONE_NAME}
manage_etc_hosts: true
EOF
  # Determine role from instance name
  ROLE="sampler"
  if [ "$INSTANCE_NAME" = "aggregator" ]; then
    ROLE="aggregator"
  fi

  ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --count 1 \
    --instance-type "$INSTANCE_TYPE" \
    --security-group-ids "$SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=LDMSRole,Value=$ROLE}]" \
    --user-data "file://$USER_DATA_FILE" \
    --query 'Instances[0].InstanceId' \
    --output text)

  rm -f "$USER_DATA_FILE"
  INSTANCE_IDS+=("$ID")
  echo "Launched $INSTANCE_NAME: $ID"

done

echo "Launched instances: ${INSTANCE_IDS[*]}"

# ----------------------------
# Wait until running
# ----------------------------
aws ec2 wait instance-running \
  --region "$REGION" \
  --instance-ids "${INSTANCE_IDS[@]}"

# ----------------------------
# Create private DNS records from private IPs
# ----------------------------
for ID in "${INSTANCE_IDS[@]}"; do
  INSTANCE_NAME=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$ID" \
    --query 'Reservations[0].Instances[0].Tags[?Key==`Name`]|[0].Value' \
    --output text)

  PRIVATE_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

  CHANGE_BATCH_FILE=$(mktemp)

  cat > "$CHANGE_BATCH_FILE" <<EOF
{
  "Comment": "Upsert private DNS record for ${INSTANCE_NAME}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${INSTANCE_NAME}.${HOSTED_ZONE_NAME}",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [
          { "Value": "${PRIVATE_IP}" }
        ]
      }
    }
  ]
}
EOF

  aws route53 change-resource-record-sets \
    --hosted-zone-id "$HZ_ID" \
    --change-batch "file://$CHANGE_BATCH_FILE" >/dev/null

  rm -f "$CHANGE_BATCH_FILE"

  echo "Created DNS: ${INSTANCE_NAME}.${HOSTED_ZONE_NAME} -> ${PRIVATE_IP}"
done

# ----------------------------
# Show IDs and IPs
# ----------------------------
aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "${INSTANCE_IDS[@]}" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,InstanceId:InstanceId,PrivateDNS:PrivateDnsName,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,State:State.Name}' \
  --output table

echo
echo "Internal DNS names created:"
for INSTANCE_NAME in "${INSTANCE_NAMES[@]}"; do
  echo "  ${INSTANCE_NAME}.${HOSTED_ZONE_NAME}"
done