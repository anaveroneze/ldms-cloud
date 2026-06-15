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
BUCKET=”ldms-telemetry”
aws s3 mb “s3://$BUCKET” --region us-east-1 2>/dev/null || echo “Bucket already exists”

# 3. Upload config files to S3
aws s3 cp agg.conf “s3://$BUCKET/ldms/”
aws s3 cp samplerd-1.conf “s3://$BUCKET/ldms/”
aws s3 cp samplerd-2.conf “s3://$BUCKET/ldms/”

# 4. Verify configs are in S3
aws s3 ls “s3://$BUCKET/ldms/”

# 5. Launch instances (creates VPC, security group, DNS, IAM role)
./launch_instances.sh
# Takes ~3-5 minutes, shows instance details

# 6. Start cluster (setup + daemon startup)
./start_cluster.sh
# Takes ~10-15 minutes (15min for LDMS compile, ~2min for daemons)

# 7. Monitor deployment
aws ssm list-command-invocations \
  --query 'CommandInvocations[*].[InstanceId,Status,CommandId]' \
  --output table

# 8. When done, stop daemons or terminate
./kill_instances.sh --stop    # Stop daemons only
./kill_instances.sh           # Terminate instances
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
- `start_cluster.sh` — dispatches `setup.sh` via SSM, starts aggregator first, then connectors with readiness checks
- `setup.sh` — builds LDMS/OVIS from source on each node (run via SSM, no SSH)
- `kill_instances.sh` — gracefully stops daemons via SSM, optionally terminates instances
- `agg.conf`, `samplerd-1.conf`, `samplerd-2.conf` — LDMS daemon configs (stored in S3, pulled at daemon start)
- `CLAUDE.md` — implementation guidance for Claude Code

## Detailed Workflow

### Step 1: Provision Infrastructure

Run `launch_instances.sh` to:
- Create a security group (`cluster-sg`)
- Set up Route 53 private hosted zone (`cluster.internal`)
- Launch 3 EC2 instances (t2.medium, Ubuntu 22.04 LTS, 20 GiB storage)
- Tag instances by role: `LDMSRole=aggregator`, `LDMSRole=connector`
- Create private DNS A records for internal connectivity

```bash
./launch_instances.sh
```

The script is idempotent — reuses existing security group, DNS zone, and instances if they exist.

**Instance details:**
- **Aggregator** (`aggregator.cluster.internal`): listens for sampler connections on port 10444
- **Connectors** (`connector1.cluster.internal`, `connector2.cluster.internal`): collect meminfo metrics every 1s

### Step 2: Configure Daemon Files

Before running `start_cluster.sh`, ensure config files are in S3:

```bash
# Edit config files locally as needed (see agg.conf, samplerd-*.conf)
# Then upload to S3

BUCKET="ldms-telemetry"
aws s3 cp agg.conf s3://$BUCKET/ldms/
aws s3 cp samplerd-1.conf s3://$BUCKET/ldms/
aws s3 cp samplerd-2.conf s3://$BUCKET/ldms/
```

**Important:** Replace `<AGG_IP>` placeholder in sampler configs with `aggregator.cluster.internal` (private DNS name).

### Step 3: Start Cluster

Run `start_cluster.sh` to:
1. **Setup** — dispatches `setup.sh` to all instances via SSM (builds LDMS/OVIS from source)
2. **Aggregator startup** — starts aggregator with `-m 1g` memory allocation
3. **Connector startup** — starts connectors after aggregator readiness check
4. **Verification** — confirms all metric sets are connected

```bash
./start_cluster.sh
```

**Behind the scenes:**
- No SSH required — all commands dispatched via AWS Systems Manager (SSM)
- Aggregator starts first and listens on port 10444
- Connectors poll aggregator until it's reachable, then advertise themselves
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

```bash
# List all metric sets
ldms_ls -x sock -p 10444 -h aggregator.cluster.internal -v

# View live data (example: meminfo from connector1)
ldms_ls -x sock -p 10444 -h aggregator.cluster.internal -v meminfo
```

Expected output (when healthy):

```
Schema   Instance              Flags  Msize  Dsize
meminfo  connector1/meminfo    CR     2976   544
meminfo  connector2/meminfo    CR     2976   544
```

Data flows to `/home/ubuntu/ldms-csv/` on the aggregator as CSV files.

### Step 5: Cleanup

**Stop daemons only** (keep instances running):

```bash
./kill_instances.sh --stop
```

**Terminate all instances:**

```bash
./kill_instances.sh
```

This gracefully stops LDMS daemons via SSM before terminating instances.

## Configuration Files

- **`agg.conf`** — aggregator configuration
  - Listens for producers matching `connector.*` regex
  - Pulls metrics every 1s with 100ms offset
  - Stores CSV to `/home/ubuntu/ldms-csv`

- **`samplerd-1.conf`, `samplerd-2.conf`** — sampler configurations
  - Advertise to aggregator on port 10444
  - Collect meminfo metrics every 1s
  - Producer names must be unique and match aggregator's listener pattern

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
  --filters "Name=tag:LDMSRole,Values=aggregator,connector" Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name,PrivateIpAddress,PublicIpAddress]' \
  --output table
```

### Query LDMS Metrics (Once Cluster is Running)

```bash
# Get aggregator private IP
AGG_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:LDMSRole,Values=aggregator" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

# Query metric sets (requires ldms_ls from your local machine, or SSH to aggregator)
ldms_ls -x sock -p 10444 -h "$AGG_IP" -v
```

### Tail Logs (Via SSM)

```bash
# Check aggregator log
aws ssm send-command \
  --targets "Key=tag:LDMSRole,Values=aggregator" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["tail -50 /tmp/agg.log"]'

# Check connector logs
aws ssm send-command \
  --targets "Key=tag:LDMSRole,Values=connector" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["tail -50 /tmp/sampler.log"]'
```

### Common Issues

- **"No running instances found"** → Check `./launch_instances.sh` completed successfully
- **"Command failed" in SSM** → Instance may not have IAM permissions; verify `ldms-cluster-role` was created
- **"S3 access denied"** → Check S3 bucket exists and config files uploaded to `s3://ldms-telemetry/ldms/`
- **LDMS daemons won't start** → Check setup.sh succeeded (see SSM logs); OVIS build can take 10+ minutes

## CloudShell Considerations

When using AWS CloudShell:

- **1 GB persistent storage** in `$HOME` — store code here
- **20-minute inactivity timeout** — session resets if idle; keep scripts and config in S3 or Git
- **No SSH keys** — use IAM credentials instead (already configured)
- **Ideal for:** running provisioning/startup scripts, monitoring
- **Not ideal for:** long-running interactive sessions (use EC2 instead)

Recommended workflow in CloudShell:

```bash
# Clone repo (stored in $HOME for persistence)
git clone https://github.com/anaveroneze/ldms-cloud.git
cd ldms-cloud

# Configs in S3 (survives session reset)
aws s3 ls s3://ldms-telemetry/ldms/

# Run provisioning scripts
./launch_instances.sh
./start_cluster.sh

# Monitor via CloudShell or from local machine
aws ssm list-command-invocations --query '...' --output table
```

If CloudShell times out, simply reconnect and clone the repo again — all state is in AWS (instances, S3, SSM commands).

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
