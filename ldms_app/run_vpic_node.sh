#!/usr/bin/env bash
# Run the VPIC benchmark with an idle baseline on either side, then push the log
# and the phase timestamps to S3. Runs on the compute node, dispatched by
# run_benchmark.sh.
set -uo pipefail

NP="${NP:-4}"                                   # MPI ranks; keep it a divisor of ny
TPP="${TPP:-1}"                                 # threads per rank (VPIC --tpp); 1 = pure MPI
IDLE="${IDLE:-60}"                              # seconds of idle baseline per side
RUN_ID="${RUN_ID:-$(date +%Y%m%dT%H%M%S)}"
BUCKET="${BUCKET:-ldms-telemetry}"
RESULTS_PREFIX="${RESULTS_PREFIX:-app-results}"
REGION="${REGION:-us-east-1}"

BIN="$HOME/vpic/build/harris_bench.Linux"
RUNDIR="$HOME/vpic-run/$RUN_ID"
LOG="vpic_$RUN_ID.log"
META="run_$RUN_ID.json"

[ -x "$BIN" ] || { echo "ERROR: $BIN not found - run build_vpic.sh first"; exit 1; }

mkdir -p "$RUNDIR" && cd "$RUNDIR" || exit 1
cp "$BIN" .

# 'date +%s' is epoch-UTC, the same clock LDMS writes into the CSV '#Time'
# column, so these markers slice the time series directly - no conversion.
echo "Phase 1/3: idle baseline (${IDLE}s)"
T_PRE_START=$(date +%s); sleep "$IDLE"; T_PRE_END=$(date +%s)

# Total occupancy is NP x TPP. The default is one rank per physical core:
# c5.2xlarge reports 8 vCPUs but has 4 cores, and on a memory-bandwidth-bound
# particle push the hyperthread siblings mostly contend.
#
# In hybrid mode (TPP > 1) binding each rank to a single core would make that
# rank's threads share one core, so binding is dropped. VPIC does not set thread
# affinity itself (upstream issue #32), which is a reason to prefer pure MPI.
if [ "$TPP" -gt 1 ]; then
    BIND="--bind-to none"
else
    BIND="--bind-to core --map-by core"
fi

echo "Phase 2/3: VPIC on $NP ranks x $TPP thread(s) ($BIND)"
T_RUN_START=$(date +%s)
mpirun -np "$NP" $BIND --report-bindings \
  ./harris_bench.Linux --tpp "$TPP" > "$LOG" 2>&1
RC=$?
T_RUN_END=$(date +%s)

echo "Phase 3/3: idle baseline (${IDLE}s)"
T_POST_START=$(date +%s); sleep "$IDLE"; T_POST_END=$(date +%s)

cat > "$META" <<EOF
{
  "run_id": "$RUN_ID",
  "hostname": "$(hostname)",
  "np": $NP,
  "tpp": $TPP,
  "idle_seconds": $IDLE,
  "exit_code": $RC,
  "wall_seconds": $((T_RUN_END - T_RUN_START)),
  "pre_idle":  { "start": $T_PRE_START,  "end": $T_PRE_END },
  "run":       { "start": $T_RUN_START,  "end": $T_RUN_END },
  "post_idle": { "start": $T_POST_START, "end": $T_POST_END }
}
EOF

aws s3 cp "$META" "s3://$BUCKET/$RESULTS_PREFIX/" --region "$REGION"
aws s3 cp "$LOG"  "s3://$BUCKET/$RESULTS_PREFIX/" --region "$REGION"

echo
echo "=== Run summary ==="
cat "$META"

echo
echo "=== Files in $RUNDIR ==="
ls -1

echo
echo "=== Last 25 lines of $LOG ==="
tail -25 "$LOG"

exit $RC
