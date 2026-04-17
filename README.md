## **Step 1: Launch 3 EC2 Instances**

* AMI: Ubuntu Server 22.04 LTS  
* Instance Type: t2.medium (4 GiB Memory, 2 vCPU)  
* Storage: 20 GiB 
* Key Pair: [key_name]  
* All 3 instances assigned to same security group
* Names: connector1, connector2, aggregator

Added the following rules:

| Connection | Protocol | Port | Source 
| --- | --- | --- | --- |
| SSH | TCP | 22 | 0.0.0.0/0 |
| SSH | TCP | 10444 | 0.0.0.0/0 |
| All | All | All | 0.0.0.0/0 |  

Run: [launch_instances.sh](launch_instances.sh)

Check instances available:

```bash 
aws ec2 describe-instances \
  --instance-ids "${INSTANCE_IDS[@]}" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,InstanceId:InstanceId,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,State:State.Name}' \
  --output table
```

```
-----------------------------------------------------------------------------------
|                                DescribeInstances                                |
+----------------------+-------------+---------------+----------------+-----------+
|      InstanceId      |    Name     |   PrivateIP   |   PublicIP     |   State   |
+----------------------+-------------+---------------+----------------+-----------+
|  ------------------- |  aggregator |    <AGG_IP>   |  52.23.243.247 |  running  |
|  ------------------- |  connector2 |    <CONN1_IP> |  3.80.242.113  |  running  |
|  ------------------- |  connector1 |    <CONN2_IP> |  107.22.96.232 |  running  |
+----------------------+-------------+---------------+----------------+-----------+
```

Access as `ssh -i ~/"$KEY_NAME".pem ubuntu@<public-ip-node1>`

## **Step 2: LDMS Installation (all nodes)** 

Install in each node: [setup.sh](setup.sh)

Optional, create an AWS AMI 

```bash
aws ec2 create-image --instance-id <INSTANCE_ID> --name "ldms-ami-$(date +%s)" --no-reboot
```

## **Step 4: Configuration Files** 

To get each IP address:

```bash
AGG_IP=$(aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running Name=tag:Name,Values=aggregator \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

COMM1_IP=$(aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running Name=tag:Name,Values=connector1 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

COMM2_IP=$(aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running Name=tag:Name,Values=connector2 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "AGGREGATOR_IP=$AGGREGATOR_IP"
echo "COMM1_IP=$COMM1_IP"
echo "COMM2_IP=$COMM2_IP"
```

### **Communicator 1**

```bash
KEY_NAME="ana"
ssh -i ~/"$KEY_NAME".pem ubuntu@"$COMM1_IP"
```

Create file called `samplerd-1.conf`:

```bash
advertiser_add name=agg11 xprt=sock host=<AGG_IP> port=10444 reconnect=10s  
advertiser_start name=agg11

load name=meminfo  
config name=meminfo producer=samplerd-1 instance=samplerd-1/meminfo  
start name=meminfo interval=1s
```
  
- reconnect=10s: Retry connection every 10 seconds if disconnected  
- interval=1s: Collect meminfo metrics every 1 second

<!-- **With procnetdev2:**
advertiser_add name=agg11 xprt=sock host="$AGG_IP" port=10444 reconnect=10s advertiser\_start name=agg11 load name=meminfo config name=meminfo producer=samplerd-1 instance=samplerd-1/meminfo start name=meminfo interval=1s load name=procnetdev2 config name=procnetdev2 producer=samplerd-1 instance=samplerd-1/procnetdev2 start name=procnetdev2 interval=1s -->

### **Communicator 2**

Create file called `samplerd-2.conf`: 

```bash
advertiser_add name=agg11 xprt=sock host=<AGG_IP> port=10444 reconnect=10s  
advertiser_start name=agg11

load name=meminfo  
config name=meminfo producer=samplerd-2 instance=samplerd-2/meminfo  
start name=meminfo interval=1s
```
<!-- 
**With procnetdev2:**  
advertiser\_add name=agg11 xprt=sock host="$AGG_IP" port=10444 reconnect=10s advertiser\_start name=agg11 load name=meminfo config name=meminfo producer=samplerd-2 instance=samplerd-2/meminfo start name=meminfo interval=1s load name=procnetdev2 config name=procnetdev2 producer=samplerd-2 instance=samplerd-2/procnetdev2 start name=procnetdev2 interval=1s -->

### Aggregator

Create file called `agg.conf`:  
 
- updtr: Pulls data from all connected producers every 1 second  
- offset=100ms: Small offset to avoid simultaneous updates

```bash
prdcr_listen_add name=computes regex=ip-172-31-*
prdcr_listen_start name=computes

updtr_add name=all_sets interval=1s offset=100ms
updtr_prdcr_add name=all_sets regex=.*
updtr_start name=all_sets 
``` 

## **Step 5: Starting the Daemons** 

**Step 1: aggregator**

```bash
ldmsd -x sock:10444 -c agg.conf -l /tmp/agg11.log -v INFO -m 1g &
```

**Step 2: communicator 1**

```bash
ldmsd -x sock:10444 -c samplerd-1.conf -l /tmp/sampler1.log -v INFO &
```

**Step 3: communicator 2**

```bash
ldmsd -x sock:10444 -c samplerd-2.conf -l /tmp/sampler2.log -v INFO &
```

Flag -m 1g sets memory allocation to 1GB (vs default 512MB). This was one of the key fixes suggested by Sara and the LDMS team to resolve the buffer overflow crash.

## **Step 6: Verification** 

## **Process Check (node-3)**

```bash
ps aux | grep ldmsd | grep -v grep  
```

```
ubuntu  51862  0.0  0.1 1378244 7424 pts/0  Sl  02:59  0:00   
ldmsd -x sock:10444 -c /home/ubuntu/agg.conf -l /tmp/agg11.log -v INFO -m 1g
```
Aggregator log:

```
INFO: ldmsd: Listening on sock:10444 using `sock` transport and `none` authentication  
INFO: ldmsd: Processing the config file '/home/ubuntu/agg.conf' is done.  
INFO: ldmsd: Enabling in-band config  
INFO: producer: Producer ip-172-31-35-155:10444 is connected  
INFO: producer: Adding the metric set 'samplerd-1/meminfo'  
INFO: producer: Producer ip-172-31-36-162:10444 is connected  
INFO: producer: Adding the metric set 'samplerd-2/meminfo'  
INFO: updater: Set samplerd-1/meminfo is ready  
INFO: updater: Set samplerd-2/meminfo is ready
```
 
```bash
ldms_ls -x sock -p 10444 -h localhost -v  
```

```
Schema   Instance              Flags  Msize  Dsize  Hsize  UID   GID   Perm  
\-------- \--------------------- \------ \------ \------ \------ \----- \----- \----------  
meminfo  samplerd-1/meminfo    CR     2976   544    0      1000  1000  \-r--r-----  
meminfo  samplerd-2/meminfo    CR     2976   544    0      1000  1000  \-r--r-----

Total Sets: 2, Meta Data (kB): 5.95, Data (kB) 1.09, Memory (kB): 7.04   
```

After 2 Minutes (Stability Check)

```bash
sleep 120 && ldms_ls -x sock -p 10444 -h localhost -v 
```

```
Schema   Instance              Flags  Msize  Dsize  
\-------- \--------------------- \------ \------ \-----  
meminfo  samplerd-1/meminfo    CR     2976   544  
meminfo  samplerd-2/meminfo    CR     2976   544
```
 
Live Data Output (ldms_ls -v -l)

**samplerd-1/meminfo (node-1):**

MemTotal      4005964 KB (\~4GB)  
MemFree       2293704 KB (\~2.3GB)  
MemAvailable  3544900 KB  
SwapTotal     0  
SwapFree      0 

**samplerd-2/meminfo (node-2):**

MemTotal      4005960 KB (\~4GB)  
MemFree       2263600 KB  
MemAvailable  3515044 KB  
SwapTotal     0  
SwapFree      0

To terminate all run [kill_instances.sh](kill_instances.sh)

---

# **References**

* LDMS Documentation: [https://ovis-hpc.readthedocs.io/projects/ldms/en/latest/](https://ovis-hpc.readthedocs.io/projects/ldms/en/latest/)  
* OVIS GitHub: [https://github.com/ovis-hpc/ovis](https://github.com/ovis-hpc/ovis)  
* Peer Daemon Advertisement: [https://ovis-hpc.readthedocs.io/projects/ldms/en/latest/rst\_man/man/ldmsd\_peer\_daemon\_advertisement.html](https://ovis-hpc.readthedocs.io/projects/ldms/en/latest/rst_man/man/ldmsd_peer_daemon_advertisement.html)

*In collaboration between:*
*- Northeastern University: Uttapreksha Patel, Ana Solorzano, Devesh Tiwari*
*- Sandia National Laboratories: Sara Walton, Jim M. Brandt*