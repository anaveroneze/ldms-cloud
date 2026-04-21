#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Variables
# ----------------------------
KEY_NAME="ana"
INSTANCE_TYPE="t2.medium"
SG_NAME="cluster-sg"
HOSTED_ZONE_NAME="cluster.internal"
DHCP_OPTIONS_NAME="cluster-dhcp-options"
INSTANCE_NAMES=("aggregator" "connector1" "connector2")

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
# Create or reuse DHCP options set
# This makes short names like 'aggregator' expand to '.cluster.internal'
# ----------------------------
DHCP_OPTIONS_ID=$(aws ec2 describe-dhcp-options \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=$DHCP_OPTIONS_NAME" \
  --query 'DhcpOptions[0].DhcpOptionsId' \
  --output text)

if [ "$DHCP_OPTIONS_ID" = "None" ] || [ -z "$DHCP_OPTIONS_ID" ]; then
  DHCP_OPTIONS_ID=$(aws ec2 create-dhcp-options \
    --region "$REGION" \
    --dhcp-configurations \
      "Key=domain-name,Values=$HOSTED_ZONE_NAME" \
      "Key=domain-name-servers,Values=AmazonProvidedDNS" \
    --query 'DhcpOptions.DhcpOptionsId' \
    --output text)

  aws ec2 create-tags \
    --region "$REGION" \
    --resources "$DHCP_OPTIONS_ID" \
    --tags "Key=Name,Value=$DHCP_OPTIONS_NAME"
fi

aws ec2 associate-dhcp-options \
  --region "$REGION" \
  --dhcp-options-id "$DHCP_OPTIONS_ID" \
  --vpc-id "$VPC_ID"

echo "Using DHCP options: $DHCP_OPTIONS_ID"

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

# SSH from anywhere (kept for convenience if you need to log in from outside)
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 2>/dev/null || true

# Example service port - internal only
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
  ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --count 1 \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
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