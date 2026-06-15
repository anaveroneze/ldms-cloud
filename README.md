# LDMS Cluster Deployment on AWS

This repository provides scripts and configurations to deploy an LDMS (Lightweight Distributed Metric Service) telemetry cluster on AWS EC2: **1 aggregator + N samplers** (default 2; set `NUM_SAMPLERS` to scale). Samplers collect `meminfo` metrics every second, advertise themselves to the aggregator, and the aggregator pulls and stores the data as CSV.

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

# 2. Create S3 bucket for config files (if it doesn't exist) and upload config files to S3 (one shared sampler config for all samplers)
./create_s3.sh

# 4. Launch instances (creates VPC, security group, DNS, IAM role); ~3-5 min
#    Scale the cluster by setting NUM_SAMPLERS (default 2), e.g.:
#    NUM_SAMPLERS=3 ./launch_instances.sh
./launch_instances.sh

# 5. Start cluster (build + daemon startup); ~10-15 min (LDMS compiles from source)
./start_cluster.sh

# 6. Fetch collected CSV data to CloudShell (do this BEFORE terminating)
./fetch_data.sh

# 7. Tear down
./kill_instances.sh --stop    # Stop daemons only (instances keep running)
./kill_instances.sh           # Stop daemons and terminate all instances
```

If CloudShell times out from inactivity, just reconnect and `cd ~/ldms-cloud` — all state lives in AWS (see [CloudShell Considerations](#cloudshell-considerations)).

### Local Machine Deployment

Same steps as CloudShell, but requires:
- `aws configure` with your credentials 

## Repository Contents

- `launch_instances.sh` — provisions AWS infrastructure, launches the aggregator + `NUM_SAMPLERS` samplers, tags them by role
- `start_cluster.sh` — dispatches `setup.sh` via SSM, starts aggregator first, then samplers with readiness checks
- `setup.sh` — builds LDMS/OVIS from source on each node (run via SSM, no SSH)
- `fetch_data.sh` — copies the aggregator's collected CSV data to CloudShell via S3
- `kill_instances.sh` — gracefully stops daemons via SSM, optionally terminates instances
- `agg.conf`, `sampler.conf` — LDMS daemon configs (stored in S3, pulled at daemon start); `sampler.conf` is one shared template used by every sampler

## Detailed Workflow

### Step 1: Provision Infrastructure

Run `launch_instances.sh` to:
- Create a security group (`cluster-sg`)
- Set up Route 53 private hosted zone (`cluster.internal`)
- Launch `1 + NUM_SAMPLERS` EC2 instances (t2.medium, Ubuntu 22.04 LTS, 20 GiB storage)
- Tag instances by role: `LDMSRole=aggregator`, `LDMSRole=sampler`
- Create private DNS A records for internal connectivity

```bash
./launch_instances.sh              # default: 2 samplers
NUM_SAMPLERS=3 ./launch_instances.sh   # scale to 3 samplers
```

The script is idempotent — reuses existing security group, DNS zone, and instances if they exist.

**Instance details:**
- **Aggregator** (`aggregator.cluster.internal`): listens for sampler connections on port 10444
- **Samplers** (`samplerd-1`, `samplerd-2`, … `samplerd-N`): collect meminfo metrics every 1s

### Step 2: Configure Daemon Files

Edit `agg.conf` / `sampler.conf` locally if needed, then upload them to S3 (the upload commands are in Quick Start step 3). One shared `sampler.conf` is used by every sampler: it already targets the aggregator's private DNS name (`aggregator.cluster.internal`), and its `__NODE__` placeholder is replaced with each node's hostname at start time — so no per-launch edits are needed.

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

Use the commands in [Monitoring and Troubleshooting](#monitoring-and-troubleshooting) to check SSM command status and query metrics. When the cluster is healthy, `ldms_ls` on the aggregator shows one row per sampler:

```
Schema   Instance              Flags  Msize  Dsize
meminfo  samplerd-1/meminfo    CR     2976   544
meminfo  samplerd-2/meminfo    CR     2976   544
```

Data flows to `/home/ubuntu/ldms-csv/` on the aggregator as CSV files; use `./fetch_data.sh` to copy it to CloudShell.

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

- **`sampler.conf`** — one shared sampler configuration template used by every sampler
  - `producer=__NODE__ instance=__NODE__/meminfo`: at start time each node replaces `__NODE__` with its own `$(hostname)` (e.g. `samplerd-1`), so the metric sets are unique per sampler
  - Advertises to the aggregator on port 10444 and collects meminfo every 1s
  - The aggregator's `prdcr_listen` regex matches the advertising node's **hostname** (`samplerd-1`, `samplerd-2`, …), so it stays `sampler.*` regardless of how many samplers you run

## Scaling the Cluster

The number of samplers is a single knob: **`NUM_SAMPLERS`** (default `2`), defined at the top of `launch_instances.sh` and overridable from the environment. Everything else adapts automatically — `launch_instances.sh` generates `samplerd-1 … samplerd-N`, and `start_cluster.sh`, `kill_instances.sh`, and `fetch_data.sh` all target nodes by the `LDMSRole` tag / security group rather than a fixed count.

```bash
# Launch a cluster with 5 samplers
NUM_SAMPLERS=5 ./launch_instances.sh
./start_cluster.sh
```

Or set the default permanently by editing `launch_instances.sh`:

```bash
NUM_SAMPLERS="${NUM_SAMPLERS:-2}"   # change 2 to your preferred default
```

Because all samplers share the single `sampler.conf` (each substitutes its own hostname into `__NODE__` at start), adding more samplers needs **no new config files and no code changes** — only the `NUM_SAMPLERS` value. After launch, `ldms_ls` on the aggregator will show one `samplerd-N/meminfo` set per sampler.

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
