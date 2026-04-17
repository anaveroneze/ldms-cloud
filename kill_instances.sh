#!/usr/bin/env 
mapfile -t SG_IDS < <(
  aws ec2 describe-instances \
    --instance-ids "${INSTANCE_IDS[@]}" \
    --query 'Reservations[].Instances[].SecurityGroups[].GroupId' \
    --output text | tr '\t' '\n' | sort -u
)

if [ ${#SG_IDS[@]} -ne 1 ]; then
  echo "Expected exactly one shared security group, found: ${SG_IDS[*]}"
  exit 1
fi

SG_ID="${SG_IDS[0]}" 

mapfile -t INSTANCE_IDS < <(
  aws ec2 describe-instances \
    --filters Name=instance.group-id,Values="$SG_ID" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text | tr '\t' '\n'
) 
printf '%s\n' "${INSTANCE_IDS[@]}" 

if [ ${#INSTANCE_IDS[@]} -eq 0 ]; then
  echo "No running instances found in $SG_ID"
  exit 0
fi
 
echo "Terminating: ${INSTANCE_IDS[*]}"
aws ec2 terminate-instances --instance-ids "${INSTANCE_IDS[@]}" >/dev/null
aws ec2 wait instance-terminated --instance-ids "${INSTANCE_IDS[@]}" 