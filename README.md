# LDMS Cluster Deployment on AWS

This repository provides scripts and configurations to deploy a 3-node LDMS (Lightweight Distributed Metric Service) telemetry cluster on AWS EC2: **1 aggregator + 2 samplers**. Samplers collect `meminfo` metrics every second, advertise themselves to the aggregator, and the aggregator pulls and stores the data as CSV.

**A collaboration between Northeastern University and Sandia National Laboratories.**

## Quick Start

### Prerequisites

- AWS CLI configured with credentials
- AWS CloudShell (recommended) or local machine with AWS CLI
- S3 bucket for storing config files (e.g., `ldms-telemetry`)

### CloudShell Quick Start (Recommended)

CloudShell is ideal for this workflow — no setup needed, IAM credentials pre-configured, no SSH keys.

```bash
# 1. Clone repo to $HOME (persists across inactivity resets)
cd ~
git clone https://github.com/anaveroneze/ldms-cloud.git
cd ldms-cloud

# 2. Create S3 bucket for config files (if it doesn't exist)
BUCKET="ldms-telemetry"
aws s3 mb "s3://$BUCKET" --region us-east-1 2>/dev/null || echo "Bucket already exists"

# 3. Upload config files to S3
aws s3 cp agg.conf "s3://$BUCKET/ldms/"
aws s3 cp sampler1.conf "s3://$BUCKET/ldms/"
aws s3 cp sampler2.conf "s3://$BUCKET/ldms/"

# 4. Launch instances (creates VPC, security group, DNS, IAM role); ~3-5 min
./launch_instances.sh

# 5. Start cluster (build + daemon startup); ~10-15 min (LDMS compiles from source)
./start_cluster.sh

# 6. Fetch collected CSV data to CloudShell (do this BEFORE terminating)
./fetch_data.sh

# 7. Tear down
./kill_instances.sh --stop    # Stop daemons only (instances keep running)
./kill_instances.sh           # Stop daemons and terminate all instances
```

**If CloudShell times out (inactivity):**
```bash
# Just reconnect and resume
cd ~/ldms-cloud
aws ssm list-command-invocations --query '...' --output table
```

### Local Machine Deployment

Same steps as CloudShell, but requires:
- `aws configure` with your credentials
- SSH key available if you need manual access (`~/.ssh/ana.pem`)

## Repository Contents

- `launch_instances.sh` — provisions AWS infrastructure, launches 3 EC2 instances, tags them by role
- `start_cluster.sh` — dispatches `setup.sh` via SSM, starts aggregator first, then samplers with readiness checks
- `setup.sh` — builds LDMS/OVIS from source on each node (run via SSM, no SSH)
- `fetch_data.sh` — copies the aggregator's collected CSV data to CloudShell via S3
- `kill_instances.sh` — gracefully stops daemons via SSM, optionally terminates instances
- `agg.conf`, `sampler1.conf`, `sampler2.conf` — LDMS daemon configs (stored in S3, pulled at daemon start)

## Detailed Workflow

### Step 1: Provision Infrastructure

Run `launch_instances.sh` to:
- Create a security group (`cluster-sg`)
- Set up Route 53 private hosted zone (`cluster.internal`)
- Launch 3 EC2 instances (t2.medium, Ubuntu 22.04 LTS, 20 GiB storage)
- Tag instances by role: `LDMSRole=aggregator`, `LDMSRole=sampler`
- Create private DNS A records for internal connectivity

```bash
./launch_instances.sh
```

The script is idempotent — reuses existing security group, DNS zone, and instances if they exist.

**Instance details:**
- **Aggregator** (`aggregator.cluster.internal`): listens for sampler connections on port 10444
- **Samplers** (`sampler1.cluster.internal`, `sampler2.cluster.internal`): collect meminfo metrics every 1s

### Step 2: Configure Daemon Files

Before running `start_cluster.sh`, ensure config files are in S3:

```bash
# Edit config files locally as needed (see agg.conf, sampler*.conf)
# Then upload to S3

BUCKET="ldms-telemetry"
aws s3 cp agg.conf s3://$BUCKET/ldms/
aws s3 cp sampler1.conf s3://$BUCKET/ldms/
aws s3 cp sampler2.conf s3://$BUCKET/ldms/
```

The sampler configs already point at the aggregator's private DNS name (`aggregator.cluster.internal`), so no per-launch IP edits are needed.

### Step 3: Start Cluster

Run `start_cluster.sh` to:
1. **Setup** — dispatches `setup.sh` to all instances via SSM (builds LDMS/OVIS from source)
2. **Aggregator startup** — starts aggregator with `-m 1g` memory allocation
3. **Sampler startup** — starts samplers after aggregator readiness check
4. **Verification** — confirms all metric sets are connected

```bash
./start_cluster.sh
```

**Behind the scenes:**
- No SSH required — all commands dispatched via AWS Systems Manager (SSM)
- Aggregator starts first and listens on port 10444
- Samplers poll aggregator until it's reachable, then advertise themselves
- Config files pulled from S3 at daemon startup
- Logs stored locally: `/tmp/agg.log`, `/tmp/sampler.log`

### Step 4: Monitor and Verify

Check SSM command status:

```bash
aws ssm list-command-invocations \
  --query 'CommandInvocations[*].[InstanceId,Status,CommandId]' \
  --output table
```

Query metrics from the aggregator:

Run `ldms_ls` on the aggregator via SSM (the private DNS name isn't reachable from CloudShell):

```bash
aws ssm send-command \
  --targets "Key=tag:LDMSRole,Values=aggregator" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo -u ubuntu /home/ubuntu/ovis/build/sbin/ldms_ls -x sock -p 10444 -h localhost -v"]'
```

Expected output (when healthy):

```
Schema   Instance              Flags  Msize  Dsize
meminfo  samplerd-1/meminfo    CR     2976   544
meminfo  samplerd-2/meminfo    CR     2976   544
```

Data flows to `/home/ubuntu/ldms-csv/` on the aggregator as CSV files. Use `./fetch_data.sh` to copy it to CloudShell.

### Step 5: Cleanup

⚠️ **Fetch your data first** — the CSV lives only on the aggregator's local disk and is lost on termination:

```bash
./fetch_data.sh    # aggregator -> S3 -> ./ldms-data/ in CloudShell
```

**Stop daemons only** (keep instances running):

```bash
./kill_instances.sh --stop
```

**Terminate all instances** (stops daemons via SSM first, then terminates):

```bash
./kill_instances.sh
```

## Configuration Files

- **`agg.conf`** — aggregator configuration
  - Listens for advertising nodes whose hostname matches `sampler.*` regex
  - Pulls metrics every 1s with 100ms offset
  - Stores CSV to `/home/ubuntu/ldms-csv`

- **`sampler1.conf`, `sampler2.conf`** — sampler configurations
  - Named to match each node's hostname (`sampler1`, `sampler2`) so each node fetches `$(hostname).conf`
  - Advertise to aggregator on port 10444
  - Collect meminfo metrics every 1s
  - The aggregator's `prdcr_listen` regex matches the advertising node's **hostname** (`sampler1`/`sampler2`), so it must stay `sampler.*`

## Monitoring and Troubleshooting

### Check SSM Command Status

```bash
# Show all commands (latest first)
aws ssm list-command-invocations \
  --query 'CommandInvocations[*].[InstanceId,Status,CommandId]' \
  --output table | head -20

# Show detailed output of a specific command
aws ssm list-command-invocations \
  --command-id <COMMAND_ID> \
  --details \
  --query 'CommandInvocations[*].[InstanceId,Status,CommandPlugins[0].Output]' \
  --output text
```

### Check Instance Status

```bash
# Show all cluster instances
aws ec2 describe-instances \
  --filters "Name=tag:LDMSRole,Values=aggregator,sampler" Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name,PrivateIpAddress,PublicIpAddress]' \
  --output table
```

### Query LDMS Metrics (Once Cluster is Running)

```bash
# Run ldms_ls on the aggregator via SSM (port 10444 is not reachable from CloudShell)
aws ssm send-command \
  --targets "Key=tag:LDMSRole,Values=aggregator" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo -u ubuntu /home/ubuntu/ovis/build/sbin/ldms_ls -x sock -p 10444 -h localhost -v"]'
```

### Tail Logs (Via SSM)

```bash
# Check aggregator log
aws ssm send-command \
  --targets "Key=tag:LDMSRole,Values=aggregator" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["tail -50 /tmp/agg.log"]'

# Check sampler logs
aws ssm send-command \
  --targets "Key=tag:LDMSRole,Values=sampler" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["tail -50 /tmp/sampler.log"]'
```

### Common Issues

- **"No running instances found"** → Check `./launch_instances.sh` completed successfully
- **"Command failed" in SSM** → Instance may not have IAM permissions; verify `ldms-cluster-role` was created
- **"S3 access denied"** → Check S3 bucket exists and config files uploaded to `s3://ldms-telemetry/ldms/`
- **LDMS daemons won't start** → Check setup.sh succeeded (see SSM logs); OVIS build can take 10+ minutes

## CloudShell Considerations

- **1 GB persistent storage** in `$HOME` — store the cloned repo here
- **20-minute inactivity timeout** — session resets if idle, but all state lives in AWS (instances, S3, SSM), so just reconnect and `git clone` again
- **No SSH keys** — IAM credentials are pre-configured; everything runs through SSM
- Keep configs and collected data in S3 so they survive a session reset

## References

- **LDMS Documentation:** https://ovis-hpc.readthedocs.io/projects/ldms/en/latest/
- **OVIS GitHub:** https://github.com/ovis-hpc/ovis
- **Peer Daemon Advertisement:** https://ovis-hpc.readthedocs.io/projects/ldms/en/latest/rst_man/man/ldmsd_peer_daemon_advertisement.html
- **AWS CloudShell:** https://docs.aws.amazon.com/cloudshell/latest/userguide/
- **AWS Systems Manager Send-Command:** https://docs.aws.amazon.com/systems-manager/latest/userguide/send-commands.html

## Contributors

*In collaboration between:*
- Northeastern University: Uttapreksha Patel, Ana Solorzano, Devesh Tiwari
- Sandia National Laboratories: Sara Walton, Jim M. Brandt
