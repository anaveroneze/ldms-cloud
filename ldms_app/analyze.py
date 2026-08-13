#!/usr/bin/env python3
"""Summarize LDMS system-usage metrics over the phases of a VPIC benchmark run.

Joins the CSV files written by the aggregator's store_csv plugin with the
run_<RUN_ID>.json markers written by run_vpic_node.sh, and prints memory, CPU
and paging figures for each phase: pre_idle, run, post_idle.

Standard library only - CloudShell has python3 but not necessarily pandas.

Usage:
    python3 analyze.py results
    python3 analyze.py results --out summary.csv
"""

import argparse
import csv
import glob
import json
import os
import re
import sys

KB_PER_MIB = 1024.0
PHASES = ("pre_idle", "run", "post_idle")

# Aggregate /proc/stat fields. Only exact name matches are used, so the per-core
# columns (per_core_user0, ...) are ignored here.
CPU_FIELDS = ("user", "nice", "sys", "system", "idle", "iowait", "irq",
              "softirq", "steal", "guest", "guest_nice")

PAGING_FIELDS = ("pgfault", "pgmajfault", "pswpin", "pswpout")

PER_CORE_IDLE = re.compile(r"^per_core_idle\d+$", re.IGNORECASE)


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def read_table(path):
    """Read one store_csv file.

    store_csv writes the header as the first line, prefixed with '#':
    #Time,Time_usec,ProducerName,component_id,job_id,app_id,<metrics...>
    With altheader enabled it writes a sibling <name>.HEADER file instead.
    """
    with open(path) as handle:
        lines = handle.read().splitlines()
    if not lines:
        return [], []

    first = lines[0].lstrip()
    if first.startswith("#"):
        fields = next(csv.reader([first.lstrip("#")]))
        data = lines[1:]
    elif os.path.exists(path + ".HEADER"):
        with open(path + ".HEADER") as handle:
            fields = next(csv.reader([handle.readline().lstrip().lstrip("#")]))
        data = lines
    else:
        fields = next(csv.reader([first]))
        data = lines[1:]

    fields = [f.strip() for f in fields]
    rows = [dict(zip(fields, rec)) for rec in csv.reader(data)
            if len(rec) == len(fields)]
    return fields, rows


def load_schema(root, schema):
    """Load every file for one schema, in time order."""
    paths = sorted(p for p in glob.glob(os.path.join(root, "**", schema + "*"),
                                        recursive=True)
                   if os.path.isfile(p) and not p.endswith(".HEADER"))
    fields, rows = [], []
    for path in paths:
        table_fields, table_rows = read_table(path)
        if not fields:
            fields = table_fields
        rows.extend(table_rows)
    rows.sort(key=lambda r: num(r.get("Time")) or 0.0)
    return fields, rows


def slice_phase(rows, start, end):
    kept = []
    for row in rows:
        stamp = num(row.get("Time"))
        if stamp is not None and start <= stamp <= end:
            kept.append(row)
    return kept


def memory_series(fields, rows):
    """Memory in use, in MiB, plus a description of the expression used."""
    low = {f.lower(): f for f in fields}
    total, avail, free = low.get("memtotal"), low.get("memavailable"), low.get("memfree")

    if total and avail:
        expr = "MemTotal - MemAvailable"
        subtract = [avail]
    elif total and free:
        subtract = [p for p in (free, low.get("buffers"), low.get("cached")) if p]
        expr = "MemTotal - " + " - ".join(subtract)
    else:
        return [], "unavailable (no MemTotal column)"

    values = []
    for row in rows:
        base = num(row.get(total))
        if base is None:
            continue
        parts = [num(row.get(col)) for col in subtract]
        if any(p is None for p in parts):
            continue
        values.append((base - sum(parts)) / KB_PER_MIB)
    return values, expr


def cpu_utilization(fields, rows):
    """Utilization as a percentage of all vCPUs, from cumulative jiffy counters."""
    low = {f.lower(): f for f in fields}
    counters = [low[k] for k in CPU_FIELDS if k in low]
    idle = low.get("idle")
    if not counters or not idle or len(rows) < 2:
        return None, "unavailable"

    first, last = rows[0], rows[-1]
    delta_total = 0.0
    for col in counters:
        start, end = num(first.get(col)), num(last.get(col))
        if start is None or end is None:
            return None, "unavailable"
        delta_total += end - start

    delta_idle = num(last.get(idle)) - num(first.get(idle))
    if delta_total <= 0:
        return None, "unavailable (counters did not advance)"

    expr = "idle=%s over total=%s" % (idle, "+".join(counters))
    return 100.0 * (1.0 - delta_idle / delta_total), expr


def count_cores(fields):
    return sum(1 for f in fields if PER_CORE_IDLE.match(f)) or None


def counter_deltas(fields, rows, names):
    """Phase totals and per-second rates for cumulative counters."""
    low = {f.lower(): f for f in fields}
    result = {}
    if len(rows) < 2:
        return result

    start_t, end_t = num(rows[0].get("Time")), num(rows[-1].get("Time"))
    span = end_t - start_t if (start_t and end_t and end_t > start_t) else None

    for name in names:
        col = low.get(name)
        if not col:
            continue
        start, end = num(rows[0].get(col)), num(rows[-1].get(col))
        if start is None or end is None:
            continue
        delta = end - start
        result[name] = (delta, delta / span if span else None)
    return result


def fmt(value, spec="%.1f"):
    return "n/a" if value is None else spec % value


def report_run(meta, tables, sink):
    run_id = meta.get("run_id", "?")
    print("=" * 78)
    print("Run %s   host %s   %s MPI ranks   exit code %s"
          % (run_id, meta.get("hostname", "?"), meta.get("np", "?"),
             meta.get("exit_code", "?")))
    print("VPIC wall time: %s s" % meta.get("wall_seconds", "?"))
    print("=" * 78)

    windows = {}
    for phase in PHASES:
        span = meta.get(phase) or {}
        if "start" in span and "end" in span:
            windows[phase] = (float(span["start"]), float(span["end"]))

    # --- memory ---
    if "meminfo" in tables:
        fields, rows = tables["meminfo"]
        _, expr = memory_series(fields, rows[:1] or rows)
        print("\nMemory in use (MiB, %s)" % expr)
        print("  %-11s %8s %8s %8s" % ("phase", "samples", "mean", "peak"))
        stats = {}
        for phase, (start, end) in windows.items():
            values, _ = memory_series(fields, slice_phase(rows, start, end))
            if values:
                stats[phase] = (sum(values) / len(values), max(values))
                print("  %-11s %8d %8.0f %8.0f"
                      % (phase, len(values), stats[phase][0], stats[phase][1]))
                sink(run_id, phase, "mem_mean_mib", stats[phase][0])
                sink(run_id, phase, "mem_peak_mib", stats[phase][1])
            else:
                print("  %-11s %8d %8s %8s" % (phase, 0, "n/a", "n/a"))
        if "run" in stats and "pre_idle" in stats:
            print("  run - pre_idle:  mean %+.0f MiB,  peak %+.0f MiB"
                  % (stats["run"][0] - stats["pre_idle"][0],
                     stats["run"][1] - stats["pre_idle"][1]))

    # --- cpu ---
    if "procstat" in tables:
        fields, rows = tables["procstat"]
        cores = count_cores(fields)
        _, expr = cpu_utilization(fields, rows)
        print("\nCPU utilization (%% of all vCPUs; %s)" % expr)
        if cores:
            print("  detected %d per-core columns" % cores)
        print("  %-11s %8s %8s %12s" % ("phase", "samples", "util%", "busy vCPUs"))
        for phase, (start, end) in windows.items():
            phase_rows = slice_phase(rows, start, end)
            util, _ = cpu_utilization(fields, phase_rows)
            busy = util * cores / 100.0 if (util is not None and cores) else None
            print("  %-11s %8d %8s %12s"
                  % (phase, len(phase_rows), fmt(util), fmt(busy, "%.2f")))
            if util is not None:
                sink(run_id, phase, "cpu_util_pct", util)

    # --- paging ---
    if "vmstat" in tables:
        fields, rows = tables["vmstat"]
        print("\nPaging and swap (total over the phase, rate per second)")
        header = "  %-11s" % "phase"
        for name in PAGING_FIELDS:
            header += " %20s" % name
        print(header)
        for phase, (start, end) in windows.items():
            deltas = counter_deltas(fields, slice_phase(rows, start, end), PAGING_FIELDS)
            line = "  %-11s" % phase
            for name in PAGING_FIELDS:
                if name in deltas:
                    total, rate = deltas[name]
                    line += " %20s" % ("%d (%s/s)" % (total, fmt(rate, "%.0f")))
                    sink(run_id, phase, name, total)
                else:
                    line += " %20s" % "n/a"
            print(line)
    print("")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root", help="directory produced by fetch_results.sh")
    parser.add_argument("--out", metavar="FILE",
                        help="also write the numbers as a tidy CSV")
    args = parser.parse_args()

    run_files = sorted(glob.glob(os.path.join(args.root, "**", "run_*.json"),
                                 recursive=True))
    if not run_files:
        sys.exit("No run_*.json found under %s - did fetch_results.sh complete?"
                 % args.root)

    tables = {}
    for schema in ("meminfo", "vmstat", "procstat"):
        fields, rows = load_schema(args.root, schema)
        if rows:
            tables[schema] = (fields, rows)
            producers = sorted({r.get("ProducerName", "?") for r in rows})
            print("Loaded %-9s %6d samples  producer(s): %s"
                  % (schema, len(rows), ", ".join(producers)))
        else:
            print("WARNING: no %s data found under %s" % (schema, args.root))
    print("")

    records = []
    sink = lambda run_id, phase, metric, value: records.append(
        (run_id, phase, metric, value))

    for path in run_files:
        with open(path) as handle:
            report_run(json.load(handle), tables, sink)

    if args.out:
        with open(args.out, "w", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(["run_id", "phase", "metric", "value"])
            for run_id, phase, metric, value in records:
                writer.writerow([run_id, phase, metric, round(value, 2)])
        print("Wrote %s (%d rows)" % (args.out, len(records)))


if __name__ == "__main__":
    main()
