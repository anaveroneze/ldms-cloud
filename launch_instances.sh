#!/usr/bin/env bash 

# ----------------------------
# Variables
# ----------------------------
KEY_NAME="ana"
INSTANCE_TYPE="t2.medium"
SG_NAME="cluster-sg"
NUM_INSTANCES=3

# ----------------------------
# Get latest Ubuntu 22.04 AMI
# ----------------------------
AMI_PARAM="/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"

AMI_ID=$(aws ssm get-parameter \
  --name "$AMI_PARAM" \
  --query 'Parameter.Value' \
  --output text)

echo "AMI_ID: $AMI_ID"

# ----------------------------
# Use default VPC + one default subnet
# ----------------------------
VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' \
  --output text)

echo "VPC_ID: $VPC_ID"

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' \
  --output text)

echo "SUBNET_ID: $SUBNET_ID"

# ----------------------------
# Create or reuse security group
# ----------------------------
SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Security group for EC2 cluster nodes" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text)
fi

echo "Using Security Group: $SG_ID"

# ----------------------------
# Inbound rules
# ----------------------------
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 10444 \
  --cidr 0.0.0.0/0 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' 2>/dev/null || true

# ----------------------------
# Launch instances
# ----------------------------
INSTANCE_IDS=()

for N in $(seq 1 "$NUM_INSTANCES"); do
  if [ "$N" -eq 1 ]; then
    INSTANCE_NAME="aggregator"
  else
    INSTANCE_NAME="connector$((N - 1))"
  fi

  ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --count 1 \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

  INSTANCE_IDS+=("$ID")
  echo "Launched $INSTANCE_NAME: $ID"
done

echo "Launched instances: ${INSTANCE_IDS[*]}"

# ----------------------------
# Wait until running
# ----------------------------
aws ec2 wait instance-running --instance-ids "${INSTANCE_IDS[@]}"

# ----------------------------
# Show IDs and IPs
# ----------------------------
aws ec2 describe-instances \
  --instance-ids "${INSTANCE_IDS[@]}" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,InstanceId:InstanceId,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,State:State.Name}' \
  --output table