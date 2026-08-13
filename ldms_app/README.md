# Application Monitoring with LDMS on AWS

This directory deploys a 2-node cluster that runs the [VPIC](https://github.com/lanl/vpic)
particle-in-cell plasma simulation on one EC2 instance while a second instance collects and stores
the system-usage telemetry: **1 compute node + 1 aggregator**. The compute node samples `meminfo`,
`vmstat` and `procstat` every second; the aggregator pulls those metric sets over the network and
writes them as CSV. The benchmark wrapper records the start and end of each phase, so the resource
usage during the simulation can be separated from an idle baseline.

**A collaboration between Northeastern University and Sandia National Laboratories.**

It is self-contained: its own scripts, security group (`ldms-app-sg`), hosted zone (`app.internal`)
and cluster tag (`LDMSCluster=ldms-app`). Nothing here touches the top-level `meminfo` workflow, and
both can run at the same time.

**Where the sampler runs:** the LDMS *sampler daemon* has to run on the compute node, because it
reads that node's `/proc`. What lives on the second instance is the aggregator — it pulls the metric
sets, stores them, and holds all collected data. The sampler's own footprint is about 0.1% of one
core, and it is running during the idle baseline too, so it cancels out of every before/after
comparison.

## Quick Start

### Prerequisites

- AWS CloudShell (recommended) or a local machine with the AWS CLI configured
- Python 3 for `analyze.py` (standard library only — no pandas, no matplotlib)
- ~$0.38/hr while the instances are running (`t3.medium` + `c5.2xlarge`)

### CloudShell Quick Start

```bash
# 1. Clone the repo to $HOME (persists across CloudShell inactivity resets)
cd ~
git clone https://github.com/anaveroneze/ldms-cloud.git
cd ldms-cloud/ldms_app

# 2. Create the S3 bucket and upload the configs + node scripts; instant
bash create_s3.sh

# 3. Launch the two instances (security group, DNS, IAM role); ~3-5 min
bash launch_instances.sh

# 4. Build OVIS/LDMS on both nodes and start collection; ~15-20 min
bash start_cluster.sh
#    Check the output: METRIC_SETS must list three sets
#      compute-1/meminfo  compute-1/vmstat  compute-1/procstat

# 5. Build VPIC with a short run length, for calibration; ~10-15 min
NUM_STEP=25 bash build_vpic.sh

# 6. Calibration run, no idle padding; ~1 min. Note the reported wall_seconds.
IDLE=0 bash run_benchmark.sh

# 7. Recompile just the deck, scaled to a ~240 s run; ~30 s
#    NUM_STEP = 25 * 240 / wall_seconds     (e.g. wall_seconds=6  ->  NUM_STEP=1000)
NUM_STEP=<computed> bash build_vpic.sh --deck-only

# 8. Full benchmark: 60 s idle, VPIC, 60 s idle; ~6 min
bash run_benchmark.sh

# 9. Fetch the CSV and the VPIC log to CloudShell (do this BEFORE terminating)
bash fetch_results.sh

# 10. Print the summary
python3 analyze.py results

# 11. Finish
bash kill_instances.sh --stop    # stop daemons only, keep the instances
bash kill_instances.sh           # stop daemons and terminate the instances
```

The flow is: create_s3 → launch_instances → start_cluster → build_vpic → run_benchmark →
fetch_results → analyze → kill_instances.

**Why the calibration step:** `num_step` is compiled into the VPIC input deck, not read from a config
file, so changing the run length means recompiling. There is no published per-core VPIC throughput
figure to size it from, so the honest approach is to measure a short run on the actual instance and
scale. `--deck-only` recompiles the deck in ~30 s without rebuilding the library.

## Repository Contents

Local scripts, run from CloudShell:

- `create_s3.sh` — creates the S3 bucket and uploads the configs and the two node-side scripts
- `launch_instances.sh` — provisions the aggregator and the compute node, tags them by role
- `start_cluster.sh` — builds OVIS on both nodes, starts the aggregator, then the sampler
- `build_vpic.sh` — builds VPIC and compiles the benchmark deck on the compute node
- `run_benchmark.sh` — runs the benchmark with an idle baseline on each side
- `fetch_results.sh` — copies the collected CSV and the VPIC log to the local machine via S3
- `kill_instances.sh` — stops the daemons and any VPIC run, optionally terminates the instances
- `analyze.py` — prints per-phase memory, CPU and paging figures
- `common.sh` — shared configuration and SSM helpers, sourced by the scripts above

Delivered to the instances via S3 and run there:

- `setup_ldms.sh` — builds OVIS/LDMS from source (both nodes)
- `setup_vpic.sh` — builds VPIC and patches/compiles the deck (compute node)
- `run_vpic_node.sh` — runs the three phases and records the timestamps (compute node)

Daemon configs, stored in S3 and pulled at daemon start:

- `agg.conf` — aggregator: accepts advertising nodes, one storage policy per schema
- `sampler.conf` — compute node: three sampler plugins at 1 s (`__NODE__` template)

Node-side scripts travel through S3 rather than `raw.githubusercontent.com`, so editing them locally
and re-running `create_s3.sh` is enough — no `git push` needed for a change to take effect.

## Detailed Workflow

### Step 1: Upload Configs and Scripts

Run `create_s3.sh` to:
- Create `s3://ldms-telemetry` if it does not exist
- Upload the two `.conf` files and the three node-side scripts to `s3://ldms-telemetry/app/`

The bucket name must start with `ldms-` — the IAM policy attached to the instances is scoped to
`arn:aws:s3:::ldms-*`.

### Step 2: Provision Infrastructure

Run `launch_instances.sh` to:
- Create the security group `ldms-app-sg` (port 10444 between cluster members only, no public SSH)
- Create the Route 53 private hosted zone `app.internal` and an A record per node
- Create or reuse the IAM role `ldms-cluster-role` (SSM + S3 on `ldms-*`)
- Launch both instances, setting each hostname at boot via cloud-init

**Instance details:**

| | Name | Type | Role tags |
|---|---|---|---|
| Aggregator | `aggregator` | `t3.medium` | `LDMSRole=aggregator`, `LDMSCluster=ldms-app` |
| Compute | `compute-1` | `c5.2xlarge` | `LDMSRole=sampler`, `LDMSCluster=ldms-app` |

`c5.2xlarge` reports 8 vCPUs but has 4 physical cores, which is why the benchmark defaults to 4 MPI
ranks. Override any of these:

```bash
COMPUTE_INSTANCE_TYPE=c5.4xlarge AGG_INSTANCE_TYPE=t3.small VOLUME_SIZE=40 bash launch_instances.sh
```

**Behind the scenes:** every SSM command in this directory targets both `LDMSCluster=ldms-app` and
`LDMSRole=...`. The two filters are ANDed, which is what keeps these commands off the top-level
cluster — it uses the same `LDMSRole` values.

### Step 3: Start Collection

Run `start_cluster.sh` to:
- Wait for both nodes to register with SSM (the agent comes up 30–60 s after boot)
- Wait for cloud-init, then install the AWS CLI on both nodes
- Build OVIS/LDMS from source on both nodes (~15 min — this is the slow step)
- Start the aggregator, then the sampler once the aggregator answers
- Print the metric sets, the CSV files being written, and any plugin errors in the sampler log

**Why the CLI is installed first:** Ubuntu cloud images do not ship the AWS CLI (Amazon Linux does),
and everything else in this directory is delivered from S3, so `aws` has to exist before the first
`s3 cp`. Waiting on `cloud-init status --wait` first avoids racing cloud-init for the dpkg lock, and
also guarantees the hostname from user-data has been applied — the aggregator matches advertising
nodes on their hostname, so starting before that lands would break discovery.

This bootstrap is the `NODE_BOOTSTRAP` prefix in `common.sh`, and every script that fetches from S3
uses it — `start_cluster.sh`, `build_vpic.sh`, `run_benchmark.sh` and `fetch_results.sh`. Any of them
can therefore be the first thing to touch a fresh node. `command -v aws` makes it a no-op once the
CLI is installed, so the apt cost is paid once per node, not once per invocation.

Expected output from the verification step:

```
METRIC_SETS:
compute-1/meminfo
compute-1/procstat
compute-1/vmstat

CSV_FILES:
-rw-rw-r-- 1 ubuntu ubuntu 12043 meminfo
-rw-rw-r-- 1 ubuntu ubuntu 31877 procstat
-rw-rw-r-- 1 ubuntu ubuntu  9120 vmstat
```

If a set is missing, stop here and check Common Issues — running the benchmark without it just
produces an incomplete time series.

The script is re-runnable: it stops any running `ldmsd` before starting, so a failed attempt can be
retried directly. Use `--skip-build` to restart the daemons without rebuilding OVIS:

```bash
bash start_cluster.sh --skip-build
```

### Step 4: Build VPIC

Run `build_vpic.sh` to:
- Install `build-essential cmake git libopenmpi-dev openmpi-bin`
- Clone `lanl/vpic` (branch `devel`) and build the library
- Copy `sample/harris`, patch it, verify every substitution, and compile it

**Which VPIC:** `lanl/vpic`, the legacy version, whose only dependencies are a C++11 compiler and
MPI. The Kokkos version (`lanl/vpic-kokkos`) additionally needs Kokkos and has a documented OpenMP
deck-linking bug.

**Deck parameters,** all overridable per invocation:

| Variable | Default | Meaning |
|---|---|---|
| `NX`, `NY`, `NZ` | 256, 256, 1 | Grid cells. `NZ=1` is 2D. Keep `NP` a divisor of `NY`. |
| `NPPC` | 100 | Macroparticles per cell, both species combined |
| `NUM_STEP` | 200 | Timesteps. Set by calibration; see Quick Start. |

The defaults give 6,553,600 macroparticles and about 0.7 GB of resident memory.

### Step 5: Run the Benchmark

Run `run_benchmark.sh` to execute three phases on the compute node while LDMS keeps sampling:

1. `IDLE` seconds of idle baseline (default 60)
2. `mpirun -np $NP --bind-to core --map-by core ./harris_bench.Linux`
3. `IDLE` seconds of idle baseline

It writes `run_<RUN_ID>.json` with the epoch start/end of each phase, plus `vpic_<RUN_ID>.log`, and
uploads both to S3. Each invocation gets its own `RUN_ID`, so repeated runs accumulate and
`analyze.py` reports each separately.

`date +%s` is epoch-UTC, the same clock LDMS writes into the CSV `#Time` column, so the markers slice
the time series directly — there is no timezone conversion anywhere in the pipeline.

**Varying the run:**

```bash
NP=2 bash run_benchmark.sh              # 2 ranks instead of 4
IDLE=120 bash run_benchmark.sh          # longer baseline
NP=8 bash run_benchmark.sh              # 8 ranks (uses the hyperthread siblings)
```

One rank per *physical* core is the default because the particle push is memory-bandwidth-bound, so
hyperthread siblings mostly contend rather than add throughput. `NP=8` versus `NP=4` is a reasonable
experiment to run, not a free speedup.

### Step 6: Fetch and Analyze

`fetch_results.sh` has the aggregator push `/home/ubuntu/ldms-csv` to S3, then downloads it along
with the run logs into `./results/`:

```
results/
  csv/ldms_data/{meminfo,vmstat,procstat}
  runs/run_<RUN_ID>.json
  runs/vpic_<RUN_ID>.log
```

`analyze.py` joins the two and prints, per phase:

- **Memory** — mean and peak of `MemTotal - MemAvailable`, in MiB, plus the run-minus-idle delta
- **CPU** — utilization as a percentage of all vCPUs, derived from the cumulative jiffy counters as
  `1 - Δidle / Δtotal`, and the equivalent number of busy vCPUs
- **Paging** — phase totals and per-second rates for `pgfault`, `pgmajfault`, `pswpin`, `pswpout`

```bash
python3 analyze.py results                      # print the summary
python3 analyze.py results --out summary.csv    # also write a tidy CSV
```

It prints the column names it used for each derived quantity, so if a plugin in this OVIS build names
its metrics differently the mismatch is visible rather than silently producing zeros.

### Step 7: Cleanup

⚠️ **Fetch your data first** — terminating the instances deletes the root volumes and the collected
CSV with them.

```bash
bash kill_instances.sh --stop    # stop the daemons and any VPIC run, keep the instances
bash kill_instances.sh           # stop everything, then terminate
```

`kill_instances.sh` matches only instances in `ldms-app-sg`, so it will not touch the top-level
cluster. Stopping kills `ldmsd`, `harris_bench` and `mpirun`.

## Configuration Files

`sampler.conf` advertises to the aggregator and starts three plugins at a 1 s interval. It is a
template: `start_cluster.sh` substitutes the node's own `$(hostname)` into the `__NODE__` placeholder
at start time, so `producer=` and `instance=` become `compute-1`, `compute-1/meminfo`, and so on.

`agg.conf` auto-accepts any advertising node whose **hostname** matches `compute.*`, updates every
metric set every second, and declares one `store_csv` storage policy per schema — `store_csv` needs
a separate `strgp` for each. Output goes to `/home/ubuntu/ldms-csv/ldms_data/<schema>`.

The `compute.*` regex matches the advertiser's hostname, not its `producer=` name. Renaming the
compute nodes to something that does not start with `compute` breaks discovery silently.

After editing either file, re-upload before restarting: `bash create_s3.sh`.

## What the Deck Patch Changes, and Why

VPIC input decks are C++ that gets `#include`d into `deck/main.cc`, so parameters are edited in
source and compiled in. `setup_vpic.sh` copies `sample/harris` and makes three changes:

1. **Scales `nx`, `ny`, `nz`, `nppc`** to fill the instance. The shipped deck is 64×64×1 with
   `nppc=64` — 262,144 particles, which barely registers.
2. **Pins `num_step` to a literal.** The deck derives it from the physics
   (`num_step = int(0.2*taui/(wci*dt))`), giving about 484 steps — a few seconds of work.
3. **Zeroes the six binary dump intervals.** Unmodified, this deck writes roughly 1 GB per run, and
   the benchmark would measure EBS throughput rather than VPIC. The deck's own `should_dump()` guard
   tests `interval > 0`, so 0 disables cleanly. `energies_interval` is deliberately left alone: it is
   rank-0 text only and is a cheap correctness signal.

Every substitution is verified with `grep` and the script exits non-zero if any failed — a silently
unpatched deck would run the wrong benchmark and fill the disk.

Two build flags are worth knowing about:

- `-O3` is passed in `CMAKE_CXX_FLAGS` rather than left to `CMAKE_BUILD_TYPE=Release`. VPIC's
  `CMakeLists.txt` appends only the Debug and RelWithDebInfo flag sets to the flags used to compile
  the deck, never `CMAKE_CXX_FLAGS_RELEASE`, so a plain `Release` build compiles the deck at `-O0`.
- `USE_V4_SSE` is the only vector option that is safe without `-march`: `v4_sse.h` uses baseline
  SSE1/SSE2 intrinsics and the build system adds no `-march` anywhere. An AVX2 build
  (`-DUSE_V4_AVX2=ON -DUSE_V8_AVX2=ON` with `-march=native`) is a reasonable second configuration to
  compare against; never enable V8 without V4, since only V4 has a `move_p` implementation.

`bin/vpic` bakes the build and source directory paths into the compiled binary, so **do not move or
delete `~/vpic` or `~/vpic/build`** after compiling a deck.

## Monitoring and Troubleshooting

### Check SSM Command Status

Every script prints its command ID. Full output — the inline API response is truncated at 2500
characters — goes to S3:

```bash
aws s3 ls s3://ldms-telemetry/ssm-logs/<COMMAND_ID>/ --recursive
aws ssm list-command-invocations --command-id <COMMAND_ID> --details \
  --query 'CommandInvocations[*].[InstanceId,Status,CommandPlugins[0].Output]' --output table
```

### Query LDMS Directly

```bash
# Metric sets currently reaching the aggregator
aws ssm send-command --targets "Key=tag:LDMSCluster,Values=ldms-app" \
  "Key=tag:LDMSRole,Values=aggregator" --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo -u ubuntu bash -c \"export ZAP_LIBPATH=/home/ubuntu/ovis/build/lib/ovis-ldms; export LD_LIBRARY_PATH=/home/ubuntu/ovis/build/lib; /home/ubuntu/ovis/build/sbin/ldms_ls -x sock -p 10444 -h localhost -v\""]'
```

### Common Issues

- **`aws: not found`, `exit status 127`** → the AWS CLI is missing on the node. Every script that
  fetches from S3 now installs it first (`NODE_BOOTSTRAP` in `common.sh`), so this should not happen;
  if it does, the script is missing that prefix.
- **A metric set is missing from `METRIC_SETS`** → check the sampler log for the plugin that failed:
  `grep -iE 'error|fail' /tmp/sampler.log` on the compute node, and confirm the plugin was built with
  `ls ~/ovis/build/lib/ovis-ldms/ | grep -E 'meminfo|vmstat|procstat'`. If `procstat` will not
  configure, add `maxcpu=8` to its `config` line in `sampler.conf` and re-upload.
- **VPIC compile failure** → the codebase has not been touched since October 2021 and its CI only
  ever covered GCC 4.9 and 8.2, so it has never been tested against Ubuntu 22.04's GCC 11. The
  classic symptom is a missing `#include <cstdint>` or `<cstring>`; the full compiler output is in
  `s3://ldms-telemetry/ssm-logs/<COMMAND_ID>/`. This is the most likely thing to need a patch.
- **`cmake_minimum_required` / CMake policy error** → CMake 4.x removed compatibility with `< 3.5`
  and VPIC declares 3.1. Use apt's CMake (3.22 on 22.04), not pip, snap or Kitware.
- **`ldmsd` starts and immediately exits on the aggregator** → the `-m 1g` memory flag is required;
  the 512 MB default overruns its buffer and crashes.
- **A daemon start sits in `InProgress` until it times out** → something in the SSM payload is still
  holding the command's stdout/stderr open. SSM waits for those pipes to close, not just for the
  shell to exit, so a backgrounded daemon must have all three fds redirected. The trap is that `&&`
  binds tighter than `&`: `EXPORTS && { ldmsd; } > file &` backgrounds the whole list and forks
  *before* the redirection reaches the brace group, leaving the subshell holding SSM's pipes. Put
  everything inside the brace group: `{ EXPORTS && ldmsd; } > file 2>&1 < /dev/null &`.
- **Non-zero `pswpin`/`pswpout` in the summary** → the deck is too large for the instance. Lower
  `NPPC` and rebuild with `--deck-only`.
- **`analyze.py` reports `n/a` for CPU** → fewer than two samples fell inside that phase window. Any
  phase shorter than ~2 s cannot yield a counter delta; this is expected for `IDLE=0` runs.
- **`analyze.py` shows no difference between phases** → the timestamps and the CSV `#Time` column are
  misaligned. Both should be epoch-UTC; check that the `run` window in `run_<RUN_ID>.json` falls
  inside the range of `#Time` values in the CSV.

## Differences from the meminfo Workflow

| | Top-level (`../`) | This directory |
|---|---|---|
| Nodes | 1 aggregator + N samplers | 1 aggregator + 1 compute node |
| Workload | none (idle instances) | VPIC harris deck |
| Metrics | `meminfo` | `meminfo`, `vmstat`, `procstat` |
| Compute instance | `t2.medium` | `c5.2xlarge` |
| Security group | `cluster-sg` | `ldms-app-sg` |
| Hosted zone | `cluster.internal` | `app.internal` |
| Node script delivery | `raw.githubusercontent.com` | S3 (no `git push` needed) |
| Analysis | none | `analyze.py`, per-phase summary |
| Cost | ~$0.16/hr | ~$0.38/hr |

Both use the same S3 bucket and IAM role, and both can run simultaneously — the `LDMSCluster` tag
keeps their SSM commands separate.

## References

- **VPIC:** https://github.com/lanl/vpic
- **LDMS documentation:** https://ovis-hpc.readthedocs.io/projects/ldms/en/latest/
- **OVIS source:** https://github.com/ovis-hpc/ovis
- **AWS Systems Manager Run Command:** https://docs.aws.amazon.com/systems-manager/latest/userguide/run-command.html

## Contributors

*In collaboration between:*

- Northeastern University
- Sandia National Laboratories
