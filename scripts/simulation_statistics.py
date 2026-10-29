#!/usr/bin/env python3
"""Summarize saved NEM replay runs using Python 3.11+ and its standard library."""

import argparse
import csv
import datetime as dt
import heapq
import io
import json
import math
import re
import tomllib
from collections import defaultdict
from pathlib import Path


REGIONS = ("NSW1", "QLD1", "SA1", "TAS1", "VIC1")
SERVICES = tuple(side + speed for side in ("LOWER", "RAISE")
                 for speed in ("1SEC", "6SEC", "60SEC", "5MIN", "REG"))
METRICS = {
    "dispatch_mw": ("dispatch", "TOTALCLEARED", ("DUID",), "MW"),
    "energy_price": ("prices", "ROP", ("REGIONID",), "$/MWh"),
    "fcas_price": ("fcas_prices", "ROP", ("REGIONID", "BIDTYPE"), "$/MWh"),
    "interconnector_flow_mw": ("interconnectors", "MWFLOW", ("INTERCONNECTORID",), "MW"),
    "interconnector_losses_mw": ("interconnectors", "MWLOSSES", ("INTERCONNECTORID",), "MW"),
}
PERCENTILES = (5, 25, 50, 75, 90, 95, 99)
NOTES = [
    "Errors are solved minus published; unqualified error percentiles are absolute errors.",
    "Energy prices compare ROP with ROP, not RRP. Market timestamps use fixed AEST UTC+10.",
    "Percentiles use linear interpolation between adjacent ordered observations.",
    "Accuracy summaries use completed days only. Partial and failed timing prefixes remain visible.",
    "Duplicate comparison keys are excluded entirely; missing values are never filled with zero.",
    "Pooled errors use the first completed attempt per day and compatible recorded provenance; exclusions are listed.",
    "Dispatch/interconnector expected entity inventories are inferred from exports; absent entities cannot be certified complete.",
    "OPTIMAL is not an independent feasibility audit. Full numerical-audit coverage is not established by this report.",
    "Solve-wrapper time contains MIP, pricing and auxiliary work. Nested timings must not be added to parents.",
    "Compilation/GC are included in measured wall time and cover instrumented calls only. Allocations are traffic, not retained RAM.",
    "Cold/refill cohorts infer the configured cache-window pattern; they are not a measured IO attribution.",
    "Summed worker times across parallel runs are not elapsed host wall time.",
]


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def read_csv(path, warnings):
    """Read a snapshot, omitting incomplete trailing records from active writers."""
    if not path.exists():
        return
    text = path.read_text()
    if text and not text.endswith("\n"):
        warnings.append(f"Incomplete trailing CSV record ignored: {path}")
        text = text[:text.rfind("\n") + 1]
    try:
        for row in csv.DictReader(io.StringIO(text), strict=True):
            if None in row or any(value is None for value in row.values()):
                warnings.append(f"Malformed CSV row ignored: {path}")
                continue
            yield row
    except csv.Error as error:
        warnings.append(f"Incomplete/malformed CSV snapshot: {path}: {error}")


def read_toml(path, warnings):
    if not path.exists():
        return {}
    try:
        return tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as error:
        warnings.append(f"Unreadable TOML snapshot: {path}: {error}")
        return {}


def quantile(ordered, probability):
    index = (len(ordered) - 1) * probability
    lower = int(index)
    fraction = index - lower
    return ordered[lower] * (1 - fraction) + ordered[min(lower + 1, len(ordered) - 1)] * fraction


def distribution(values):
    ordered = sorted(value for value in values if value is not None and math.isfinite(value))
    if not ordered:
        return {"n": 0}
    return {
        "n": len(ordered), "total_s": math.fsum(ordered), "min": ordered[0],
        "mean": math.fsum(ordered) / len(ordered), "max": ordered[-1],
        **{f"p{p}": quantile(ordered, p / 100) for p in PERCENTILES},
    }


def error_distribution(values):
    if not values:
        return {"n": 0}
    result = distribution([abs(value) for value in values])
    result.pop("total_s")
    result["mae"] = result.pop("mean")
    ordered = sorted(values)
    result.update(bias=math.fsum(values) / len(values),
                  rmse=math.sqrt(math.fsum(value * value for value in values) / len(values)),
                  signed_p5=quantile(ordered, .05), signed_p95=quantile(ordered, .95),
                  within_1_pct=100 * sum(abs(value) <= 1 for value in values) / len(values))
    return result


def expected_times(day):
    start = dt.datetime.combine(dt.date.fromisoformat(day), dt.time(4, 5))
    return {(start + dt.timedelta(minutes=5 * index)).isoformat() for index in range(288)}


def normalize_timestamp(value):
    try:
        timestamp = dt.datetime.fromisoformat(value)
        if timestamp.tzinfo:
            timestamp = timestamp.astimezone(dt.timezone(dt.timedelta(hours=10))).replace(tzinfo=None)
        return timestamp.isoformat()
    except (TypeError, ValueError):
        return None


def compare_day(folder, metric, warnings):
    table, field, dimensions, unit = METRICS[metric]
    path = folder / f"comparison_{table}.csv"
    valid_times = expected_times(folder.name)
    unique = {}
    duplicates = set()
    groups = defaultdict(lambda: {"errors": [], "rows": 0, "missing": 0, "times": set()})
    if metric == "energy_price":
        for region in REGIONS:
            groups[region]
    if metric == "fcas_price":
        for region in REGIONS:
            for service in SERVICES:
                groups[f"{region}|{service}"]
    counts = defaultdict(int)
    for row in read_csv(path, warnings):
        counts["rows"] += 1
        timestamp = normalize_timestamp(row.get("SETTLEMENTDATE"))
        if timestamp not in valid_times:
            counts["out_of_day_rows"] += 1
            continue
        if any(not row.get(key) for key in dimensions):
            counts["invalid_entity_rows"] += 1
            continue
        group = "|".join(row[key] for key in dimensions)
        key = (timestamp, group)
        if key in unique:
            duplicates.add(key)
        else:
            unique[key] = (number(row.get(field + "_published")), number(row.get(field + "_solved")))
    values, outliers = [], []
    for (timestamp, group), (published, solved) in unique.items():
        item = groups[group]
        item["rows"] += 1
        if (timestamp, group) in duplicates:
            continue
        if published is None or solved is None:
            item["missing"] += 1
            counts["missing_or_nonfinite"] += 1
            if published is not None and published != 0:
                counts["missing_nonzero_published"] += 1
            continue
        error = solved - published
        if not math.isfinite(error):
            counts["missing_or_nonfinite"] += 1
            continue
        values.append(error)
        item["errors"].append(error)
        item["times"].add(timestamp)
        outlier = (abs(error), timestamp, group, published, solved, error)
        heapq.heappush(outliers, outlier)
        if len(outliers) > 10:
            heapq.heappop(outliers)
    counts["duplicate_keys"] = len(duplicates)
    summary = {
        **{key: counts[key] for key in ("rows", "out_of_day_rows", "invalid_entity_rows",
                                       "missing_or_nonfinite", "missing_nonzero_published", "duplicate_keys")},
        "file_present": path.exists(), "unit": unit, "errors": error_distribution(values),
        "groups": {name: {**error_distribution(item["errors"]), "rows": item["rows"],
                          "missing": item["missing"], "paired_intervals": len(item["times"]),
                          "expected_intervals": 288}
                   for name, item in sorted(groups.items())},
        "worst": [dict(zip(("absolute_error", "interval_aest", "entity", "published", "solved", "error"), row))
                  for row in sorted(outliers, reverse=True)],
    }
    return summary, values


def native_snapshots(folder, warnings):
    snapshots = []
    states = []
    for path in sorted(folder.glob("timers_*_chunk_*.toml"),
                       key=lambda value: int(value.stem.rsplit("_", 1)[-1])):
        data = read_toml(path, warnings)
        def walk(node, parts=()):
            if parts:
                snapshots.append({"file": path.name, "timer": "/".join(parts),
                                  "calls": node.get("n_calls"),
                                  "time_s": (number(node.get("time_ns")) or 0) / 1e9})
            for name, child in node.get("inner_timers", {}).items():
                walk(child, (*parts, name))
        walk(data)
        if path.name.startswith("timers_execute"):
            execute = data.get("inner_timers", {}).get("Execute Simulation", {})
            state = execute.get("inner_timers", {}).get("Execute dispatch", {}).get("inner_timers", {}).get("Update State")
            if state is not None:
                states.append((execute.get("n_calls"), (number(state.get("time_ns")) or 0) / 1e9))
    state_total = None
    if len(states) == 1:
        state_total = states[0][1]
    elif states:
        calls = [row[0] for row in states]
        if all(value == 1 for value in calls):
            state_total = math.fsum(value for _, value in states)
        elif all(isinstance(value, int) for value in calls) and all(a < b for a, b in zip(calls, calls[1:])):
            state_total = states[-1][1]
        else:
            warnings.append(f"Ambiguous cumulative native timers; state total withheld: {folder}")
    return snapshots, state_total


# Schema 1 wrote solve_impl and result_write rows. Schema 2 writes one solve_and_write row per step,
# whose span also covers the result write, the native state update and the warm start.
SOLVER_PHASES = ("solve_impl", "solve_and_write")
WRITE_PHASES = ("result_write", "solve_and_write")
MEASURED_PHASES = {
    1: ("parameter_update", "solve_impl", "result_write"),
    2: ("parameter_update", "solve_and_write"),
}


def timing_schema(row):
    """Return the schema version of an interval timing row; files without the column are schema 1."""
    if "schema_version" not in row:
        return 1
    if row["schema_version"] not in ("1", "2"):
        raise ValueError(f"Unsupported interval timing schema_version: {row['schema_version']!r}")
    return int(row["schema_version"])


def single_timing_schema(schemas, folder):
    """Return the one schema present in a set of rows, or None when there are no rows."""
    if len(schemas) > 1:
        raise ValueError(f"Schema 1 and schema 2 interval timings cannot be pooled: {folder}")
    return next(iter(schemas), None)


def instrumented_totals(schema, instrumented, optimizer):
    """Sum the recorder's gc, compilation and allocation fields that the given schema measured.

    Schema 1 measured the whole solve_impl wrapper, so its totals cover every instrumented row.
    Schema 2 measured only JuMP.optimize!, so its totals are optimize_* and compilation is absent.
    """
    def total(values):
        return math.fsum(value for value in values if value is not None)

    if schema == 1:
        return {
            "instrumented_gc_s": total(instrumented["gc_s"]),
            "instrumented_compilation_s": total(instrumented["compilation_s"]),
            "instrumented_allocated_bytes": total(instrumented["allocated_bytes"]),
            "optimize_gc_s": None, "optimize_allocated_bytes": None,
        }
    if schema == 2:
        return {
            "instrumented_gc_s": None, "instrumented_compilation_s": None,
            "instrumented_allocated_bytes": None,
            "optimize_gc_s": total(optimizer["gc_s"]),
            "optimize_allocated_bytes": total(optimizer["allocated_bytes"]),
        }
    return {key: None for key in ("instrumented_gc_s", "instrumented_compilation_s",
                                  "instrumented_allocated_bytes", "optimize_gc_s",
                                  "optimize_allocated_bytes")}


def day_timing(folder, totals, cache_windows, warnings):
    series = defaultdict(list)
    calls = defaultdict(list)
    instrumented = defaultdict(list)
    optimizer = defaultdict(list)
    seen = set()
    schemas = set()
    written = 0
    for path in sorted(folder.rglob("interval_timings.csv")):
        first_update = True
        for row in read_csv(path, warnings):
            phase = row.get("phase")
            schema = timing_schema(row)
            schemas.add(schema)
            key = (str(path), phase, row.get("execution_count"), row.get("interval_aest"))
            if key in seen:
                warnings.append(f"Duplicate interval timing omitted: {key}")
                continue
            seen.add(key)
            wall = number(row.get("wall_s"))
            if wall is None or wall < 0:
                continue
            series[phase].append(wall)
            calls[phase].append({"interval_aest": row.get("interval_aest"), "wall_s": wall})
            written += phase in WRITE_PHASES
            for field in ("gc_s", "compilation_s", "allocated_bytes"):
                value = number(row.get(field))
                instrumented[field].append(value)
                if schema == 2 and phase == "solve_and_write" and field != "compilation_s":
                    optimizer[field].append(value)
            if phase in SOLVER_PHASES:
                children = []
                for field, label in (("timed_solve_s", "mip"), ("pricing_s", "pricing"), ("auxiliary_s", "auxiliary")):
                    value = number(row.get(field))
                    series[label].append(value)
                    children.append(value)
                    if value is not None:
                        calls[label].append({"interval_aest": row.get("interval_aest"), "wall_s": value})
                if all(value is not None for value in children):
                    residual = "solve_wrapper_residual" if schema == 1 else "solve_and_write_residual"
                    series[residual].append(wall - math.fsum(children))
            if phase == "parameter_update":
                count = number(row.get("execution_count"))
                cohort = "cold" if first_update else "refill_candidate" if count is not None and count % cache_windows == 1 else "ordinary"
                series["updates_" + cohort].append(wall)
                first_update = False
    schema = single_timing_schema(schemas, folder)
    native, state = native_snapshots(folder, warnings)
    execute = number(totals.get("execute_s"))
    measured = math.fsum(value for phase in MEASURED_PHASES.get(schema, ()) for value in series[phase])
    unattributed = None
    if execute is not None and schema is not None:
        # The native state update sits inside schema 2's solve_and_write span, so it is not subtracted again.
        unattributed = execute - measured - ((state or 0) if schema == 1 else 0)
    result = {
        "timing_schema": schema,
        "series": {key: distribution(values) for key, values in sorted(series.items())},
        **instrumented_totals(schema, instrumented, optimizer),
        "native_state_s": state, "native_snapshots": native,
        "execution_unattributed_s": unattributed,
        "slowest_calls": {phase: sorted(rows, key=lambda row: row["wall_s"], reverse=True)[:10]
                          for phase, rows in calls.items()},
        "written_intervals": written,
    }
    if result["execution_unattributed_s"] is not None and result["execution_unattributed_s"] < -.1:
        warnings.append(f"Negative execution residual; timer boundaries require review: {folder}")
    wall = number(totals.get("elapsed_s"))
    parts = [number(totals.get(field)) for field in ("system_build_s", "model_build_s", "execute_s", "compare_s")]
    result["outside_build_execute_compare_s"] = wall - math.fsum(parts) if wall is not None and all(x is not None for x in parts) else None
    return result


def provenance_signature(provenance):
    keys = ("revision", "psi", "aem", "aem_simulations", "hdf5", "julia", "optimization_level",
            "intervention", "mip_rel_gap", "mip_abs_gap", "package_source_hashes")
    return json.dumps({key: provenance.get(key) for key in keys}, sort_keys=True)


def analyze(runs, cache_windows=24):
    result = {"generated_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "notes": NOTES,
              "warnings": [], "runs": [], "days": [], "pooled": {}, "cache_windows": cache_windows}
    warnings = result["warnings"]
    pools = defaultdict(list)
    selected_days = set()
    signature = None
    for root in dict.fromkeys(Path(path).resolve() for path in runs):
        if not root.is_dir():
            raise ValueError(f"Run directory does not exist: {root}")
        totals = {row["trading_day"]: row for row in read_csv(root / "days.csv", warnings)
                  if row.get("status") == "completed"}
        failures = list(read_csv(root / "failures.csv", warnings))
        failed = {row.get("trading_day") for row in failures}
        phases = defaultdict(list)
        phase_rows = list(read_csv(root / "phases.csv", warnings))
        for index, row in enumerate(phase_rows):
            next_row = phase_rows[index + 1] if index + 1 < len(phase_rows) else {}
            start, stop = number(row.get("elapsed_s")), number(next_row.get("elapsed_s"))
            row["observed_span_s"] = stop - start if start is not None and stop is not None else None
            row["span_complete"] = stop is not None
            phases[row.get("trading_day")].append(row)
        memory = list(read_csv(root / "memory.csv", warnings))
        rss = distribution([number(row.get("rss_mib")) for row in memory])
        rss.pop("total_s", None)
        run = {"path": str(root), "status": read_toml(root / "status.toml", warnings),
               "config": read_toml(root / "run.toml", warnings),
               "outcome": read_toml(root / "outcome.toml", warnings), "failures": failures,
               "completed_days": len(totals), "failed_days": len(failures), "rss_mib": rss,
               "peak_worker_rss_mib": max((number(row.get("peak_rss_mib")) or 0 for row in memory), default=None)}
        result["runs"].append(run)
        for folder in sorted(root.iterdir()):
            if not folder.is_dir() or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", folder.name):
                continue
            day = folder.name
            try:
                expected_times(day)
            except ValueError:
                warnings.append(f"Invalid day directory ignored: {folder}")
                continue
            status = "completed" if day in totals else "failed" if day in failed else "in_progress"
            provenance = read_toml(folder / "provenance.toml", warnings)
            item = {"run": str(root), "day": day, "status": status, "provenance": provenance,
                    "totals": {key: value if key in ("trading_day", "status") else number(value)
                               for key, value in totals.get(day, {}).items()},
                    "phase_boundaries": phases[day],
                    "timing": day_timing(folder, totals.get(day, {}), cache_windows, warnings),
                    "comparisons": {}, "pooled": False}
            if status == "completed":
                current_signature = provenance_signature(provenance)
                eligible = day not in selected_days and (signature is None or signature == current_signature)
                if day in selected_days:
                    warnings.append(f"Completed-day overlap excluded from pooled errors: {folder}")
                elif signature is not None and signature != current_signature:
                    warnings.append(f"Different provenance excluded from pooled errors: {folder}")
                if eligible:
                    signature = current_signature
                    selected_days.add(day)
                    item["pooled"] = True
                for metric in METRICS:
                    comparison, values = compare_day(folder, metric, warnings)
                    item["comparisons"][metric] = comparison
                    if not comparison["file_present"]:
                        warnings.append(f"Missing completed comparison: {folder}: {metric}")
                    if eligible:
                        pools[metric].extend(values)
            result["days"].append(item)
    schemas = {item["timing"]["timing_schema"] for item in result["days"]} - {None}
    if len(schemas) > 1:
        raise ValueError(f"Schema 1 and schema 2 interval timings cannot be pooled across days: {sorted(schemas)}")
    result["pooled"] = {metric: error_distribution(values) for metric, values in pools.items()}
    result["unique_completed_days"] = len({item["day"] for item in result["days"] if item["status"] == "completed"})
    result["pooled_completed_days"] = len(selected_days)
    result["unique_written_intervals"] = len({(item["day"], row["interval_aest"])
        for item in result["days"] for path in (Path(item["run"]) / item["day"]).rglob("interval_timings.csv")
        for row in read_csv(path, warnings) if row.get("phase") in WRITE_PHASES and row.get("interval_aest")})
    return result


def write_csv(path, rows):
    if not rows:
        path.write_text("")
        return
    fields = list(dict.fromkeys(key for row in rows for key in row))
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def format_value(value):
    return "-" if value is None else f"{value:.6g}" if isinstance(value, (int, float)) else str(value)


def markdown_table(headers, rows):
    return "\n".join(["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |",
                      *("| " + " | ".join(format_value(value).replace("|", "/") for value in row) + " |" for row in rows)])


def save_report(result, output):
    output.mkdir(parents=True, exist_ok=True)
    runtime, errors, groups, timings, worst, native, boundaries, slow = [], [], [], [], [], [], [], []
    for day in result["days"]:
        context = {"run": day["run"], "day": day["day"], "status": day["status"]}
        timing = day["timing"]
        runtime.append({**context, **day["totals"], "timing_schema": timing["timing_schema"],
                        "written_intervals": timing["written_intervals"],
                        **{phase + "_s": timing["series"].get(phase, {}).get("total_s")
                           for phase in ("parameter_update", "mip", "pricing", "auxiliary", "result_write", "solve_and_write")},
                        **{key: timing[key] for key in ("native_state_s", "execution_unattributed_s",
                           "outside_build_execute_compare_s", "instrumented_gc_s", "instrumented_compilation_s",
                           "instrumented_allocated_bytes", "optimize_gc_s", "optimize_allocated_bytes")}})
        for phase, stats in timing["series"].items():
            timings.append({**context, "phase": phase, **stats})
        for row in timing["native_snapshots"]:
            native.append({**context, **row})
        for phase, rows in timing["slowest_calls"].items():
            for row in rows:
                slow.append({**context, "phase": phase, **row})
        for row in day["phase_boundaries"]:
            boundaries.append({**context, **row})
        for metric, comparison in day["comparisons"].items():
            errors.append({**context, "metric": metric, "unit": comparison["unit"], "pooled": day["pooled"],
                           **comparison["errors"], **{k: comparison[k] for k in ("rows", "missing_or_nonfinite",
                              "missing_nonzero_published", "duplicate_keys", "out_of_day_rows")}})
            for entity, stats in comparison["groups"].items():
                groups.append({**context, "metric": metric, "entity": entity, "unit": comparison["unit"], **stats})
            for row in comparison["worst"]:
                worst.append({**context, "metric": metric, "unit": comparison["unit"], **row})
    for filename, rows in (("runtime.csv", runtime), ("errors.csv", errors), ("entity_errors.csv", groups),
                           ("timing_percentiles.csv", timings), ("worst_errors.csv", worst),
                           ("native_timers.csv", native), ("phase_boundaries.csv", boundaries),
                           ("slowest_intervals.csv", slow),
                           ("memory_statistics.csv", [{"run": run["path"], **run["rss_mib"],
                                "peak_worker_rss_mib": run["peak_worker_rss_mib"]} for run in result["runs"]])):
        write_csv(output / filename, rows)
    (output / "statistics.json").write_text(json.dumps(result, indent=2, allow_nan=False, default=str) + "\n")
    lines = ["# Simulation statistics", "", f"Snapshot: {result['generated_utc']}", "",
             f"Completed unique trading days: {result['unique_completed_days']}; "
             f"unique written interval identities: {result['unique_written_intervals']}.", "",
             "## Runtime", "", "Seconds. Partial days have timing prefixes only. Repeated days remain separate worker attempts.", "",
             markdown_table(["Run", "Day", "Status", "Wall", "Build system/model", "Updates", "MIP", "Pricing", "Writes", "Solve and write"],
                [[Path(row["run"]).name, row["day"], row["status"], row.get("elapsed_s"),
                  (row.get("system_build_s") or 0) + (row.get("model_build_s") or 0) if row.get("elapsed_s") else None,
                  row["parameter_update_s"], row["mip_s"], row["pricing_s"], row["result_write_s"], row["solve_and_write_s"]] for row in runtime]),
             "", "## Timing distributions", "", "Seconds per instrumented call; nested phases are shown separately.", "",
             markdown_table(["Day", "Phase/cohort", "n", "Total", "p5", "p25", "p50", "p75", "p90", "p95", "p99", "Max"],
                [[row["day"], row["phase"], *(row.get(key) for key in
                    ("n", "total_s", "p5", "p25", "p50", "p75", "p90", "p95", "p99", "max"))]
                 for row in timings if row["phase"] not in ("solve_impl", "solve_and_write", "parameter_update")]),
             "", "## Completed-day NEMDE absolute errors", "",
             markdown_table(["Day", "Metric", "Unit", "n", "MAE", "p5", "p50", "p95", "p99", "Max"],
                [[row["day"], row["metric"], row["unit"], row.get("n"), row.get("mae"),
                  *(row.get(key) for key in ("p5", "p50", "p95", "p99", "max"))] for row in errors]),
             "", "## Pooled compatible unique-day errors", "",
             markdown_table(["Metric", "n", "MAE", "Bias", "p5", "p95", "p99", "Max"],
                [[metric, *(stats.get(key) for key in ("n", "mae", "bias", "p5", "p95", "p99", "max"))]
                 for metric, stats in result["pooled"].items()]),
             "", "## Regional energy ROP errors", "", "Absolute errors in $/MWh, with signed bias.", "",
             markdown_table(["Day", "Region", "Paired intervals", "MAE", "Bias", "p5", "p50", "p95", "p99", "Max"],
                [[row["day"], row["entity"], row["paired_intervals"], *(row.get(key) for key in
                    ("mae", "bias", "p5", "p50", "p95", "p99", "max"))]
                 for row in groups if row["metric"] == "energy_price"]),
             "", "## Unit outliers by daily MAE", "", "The twenty highest daily unit MAEs; all units are retained in entity_errors.csv.", "",
             markdown_table(["Day", "DUID", "Paired intervals", "MAE MW", "p95", "p99", "Max"],
                [[row["day"], row["entity"], row["paired_intervals"], *(row.get(key) for key in ("mae", "p95", "p99", "max"))]
                 for row in sorted((row for row in groups if row["metric"] == "dispatch_mw"),
                                   key=lambda row: row.get("mae", -1), reverse=True)[:20]]),
             "", "## Worker memory and failures", ""]
    for run in result["runs"]:
        lines.extend([f"- {run['path']}: {run['completed_days']} completed / {run['failed_days']} failed days; "
                      f"sampled RSS max {format_value(run['rss_mib'].get('max'))} MiB; "
                      f"worker high-water RSS {format_value(run['peak_worker_rss_mib'])} MiB."])
        for failure in run["failures"]:
            lines.append(f"  - Failed {failure.get('trading_day')}; preserved error in statistics.json and the source run.")
    lines.extend(["", "## Interpretation and coverage", "", *("- " + note for note in result["notes"]),
                  "", "## Snapshot warnings", "", *("- " + warning for warning in result["warnings"])])
    if not result["warnings"]:
        lines.append("No parser or pooling warnings.")
    lines.extend(["", "See timing_percentiles.csv for per-day phase/cohort distributions, entity_errors.csv for unit/region/service/link "
                  "coverage and percentiles, worst_errors.csv for outliers, native_timers.csv for unaggregated nested snapshots, "
                  "slowest_intervals.csv for timing outliers, memory_statistics.csv for RSS distributions, "
                  "and phase_boundaries.csv for loading/preflight/build/execute/compare/export boundaries and observed spans. "
                  "Boundary spans include framework overhead and must not be added to their internal timers.", ""])
    (output / "report.md").write_text("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", type=Path, nargs="+", help="Replay output folders, in pooling priority order")
    parser.add_argument("--output", type=Path, help="Report folder (default: FIRST_RUN/simulation_statistics)")
    parser.add_argument("--cache-windows", type=int, default=24, help="Window count used only to infer update cohorts (default: 24)")
    args = parser.parse_args()
    if args.cache_windows < 1:
        parser.error("--cache-windows must be positive")
    try:
        result = analyze(args.runs, args.cache_windows)
        output = (args.output or args.runs[0] / "simulation_statistics").resolve()
        if output in {path.resolve() for path in args.runs}:
            parser.error("--output must be a report subfolder, not a source run root")
        save_report(result, output)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(f"Report: {output / 'report.md'}")
    print(f"Unique completed days: {result['unique_completed_days']}; "
          f"unique written intervals: {result['unique_written_intervals']}; warnings: {len(result['warnings'])}")


if __name__ == "__main__":
    main()
