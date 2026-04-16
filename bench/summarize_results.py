#!/usr/bin/env python3

from __future__ import annotations

import csv
import os
import re
import statistics
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional


ROOT = Path(__file__).resolve().parents[1]
RESULTS_DIR = Path(
    os.environ.get("BENCH_RESULTS_DIR", str(ROOT / "results"))
).expanduser()
CLIENT_RESULTS_DIR = RESULTS_DIR / "client"
SERVER_RESULTS_DIR = RESULTS_DIR / "server"
ANALYSIS_DIR = Path(
    os.environ.get("BENCH_ANALYSIS_DIR", str(RESULTS_DIR / "analysis"))
).expanduser()
FINISHED_RE = re.compile(
    r"finished in ([0-9.]+)s, ([0-9.]+) req/s, ([0-9.]+)([KMGTP]?B/s)"
)
TIME_LINE_RE = re.compile(r"^(time for request|time to 1st byte):\s+(.+)$")
RTT_LINE_RE = re.compile(r"^(smoothed RTT|min RTT):\s+(.+)$")
BASELINE_SCENARIO = "master"


@dataclass
class PairedRun:
    run_id: str
    scenario: str
    workload: str
    request_paths: str
    clients: str
    streams: str
    client_manifest: Path
    server_manifest: Path
    client_dir: Path
    server_dir: Path


def parse_env(path: Path) -> Dict[str, str]:
    env: Dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key] = value
    return env


def row_value(row: Dict[str, str], *keys: str, default: str = "") -> str:
    for key in keys:
        value = row.get(key)
        if value not in (None, ""):
            return value
    return default


def read_tsv(path: Path) -> List[Dict[str, str]]:
    with path.open(newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        return list(reader)


def write_tsv(path: Path, rows: Iterable[Dict[str, object]], fieldnames: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def display_path(path: Path) -> str:
    path = path.resolve()
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def as_int(value: str | int | float | None) -> int:
    if value is None or value == "":
        return 0
    return int(value)


def as_float(value: str | int | float | None) -> float:
    if value is None or value == "":
        return 0.0
    return float(value)


def parse_duration_us(value: str) -> float:
    value = value.strip()
    if value == "0us":
        return 0.0

    match = re.fullmatch(r"([0-9.]+)(ns|us|ms|s)", value)
    if not match:
        raise ValueError(f"Unsupported duration format: {value}")

    number = float(match.group(1))
    unit = match.group(2)
    if unit == "ns":
        return number / 1000.0
    if unit == "us":
        return number
    if unit == "ms":
        return number * 1000.0
    if unit == "s":
        return number * 1_000_000.0
    raise ValueError(f"Unsupported duration unit: {unit}")


def parse_rate_bytes_per_second(value: float, unit: str) -> float:
    factors = {
        "B/s": 1.0,
        "KB/s": 1_000.0,
        "MB/s": 1_000_000.0,
        "GB/s": 1_000_000_000.0,
        "TB/s": 1_000_000_000_000.0,
    }
    return value * factors[unit]


def parse_time_stats(path: Path) -> Dict[str, float]:
    stats: Dict[str, float] = {}
    for line in path.read_text().splitlines():
        finished_match = FINISHED_RE.search(line)
        if finished_match:
            finished_seconds = float(finished_match.group(1))
            req_per_s = float(finished_match.group(2))
            throughput_value = float(finished_match.group(3))
            throughput_unit = finished_match.group(4)
            stats["finished_seconds"] = finished_seconds
            stats["req_per_s"] = req_per_s
            stats["throughput_bytes_per_s"] = parse_rate_bytes_per_second(
                throughput_value, throughput_unit
            )
            continue

        time_line_match = TIME_LINE_RE.match(line)
        if time_line_match:
            name = time_line_match.group(1)
            columns = time_line_match.group(2).split()
            if len(columns) >= 6:
                prefix = "request" if name == "time for request" else "ttfb"
                stats[f"{prefix}_min_us"] = parse_duration_us(columns[0])
                stats[f"{prefix}_max_us"] = parse_duration_us(columns[1])
                stats[f"{prefix}_median_us"] = parse_duration_us(columns[2])
                stats[f"{prefix}_p95_us"] = parse_duration_us(columns[3])
                stats[f"{prefix}_p99_us"] = parse_duration_us(columns[4])
                stats[f"{prefix}_mean_us"] = parse_duration_us(columns[5])
            continue

        rtt_line_match = RTT_LINE_RE.match(line)
        if rtt_line_match:
            name = rtt_line_match.group(1)
            columns = rtt_line_match.group(2).split()
            if len(columns) >= 6:
                prefix = "smoothed_rtt" if name == "smoothed RTT" else "min_rtt"
                stats[f"{prefix}_median_us"] = parse_duration_us(columns[2])
                stats[f"{prefix}_p95_us"] = parse_duration_us(columns[3])
                stats[f"{prefix}_p99_us"] = parse_duration_us(columns[4])
                stats[f"{prefix}_mean_us"] = parse_duration_us(columns[5])
            continue

    return stats


def iter_manifest_paths(base_dir: Path) -> Iterable[Path]:
    seen: set[Path] = set()
    for dir_name in ("run_sets", "campaigns"):
        meta_dir = base_dir / dir_name
        if not meta_dir.exists():
            continue
        for manifest in sorted(meta_dir.glob("*/manifest.tsv")):
            if manifest in seen:
                continue
            seen.add(manifest)
            yield manifest


def load_ok_run_set_rows(base_dir: Path) -> Dict[str, Dict[str, str]]:
    rows: Dict[str, Dict[str, str]] = {}
    for manifest in iter_manifest_paths(base_dir):
        for row in read_tsv(manifest):
            if row.get("status") != "ok":
                continue
            row = dict(row)
            row["_manifest_path"] = str(manifest)
            rows[row["run_id"]] = row
    return rows


def infer_workload(request_path: str, streams: str) -> str:
    path = request_path.strip()
    stream_value = streams.strip()

    if path == "16k.bin" and stream_value == "1":
        return "small"
    if path == "1m.bin" and stream_value == "1":
        return "bulk"
    return "unknown"


def discover_client_run_dirs() -> Dict[str, Path]:
    run_dirs: Dict[str, Path] = {}
    for matrix_path in sorted(CLIENT_RESULTS_DIR.glob("**/matrix.tsv")):
        if any(part in ("campaigns", "run_sets") for part in matrix_path.parts):
            continue
        rows = read_tsv(matrix_path)
        run_ids = set()
        for row in rows:
            result_dir = row.get("result_dir", "")
            if not result_dir:
                continue
            result_path = Path(result_dir)
            if len(result_path.parts) < 3:
                continue
            run_ids.add(result_path.parts[-3])
        if len(run_ids) != 1:
            continue
        run_id = next(iter(run_ids))
        run_dirs[run_id] = matrix_path.parent
    return run_dirs


def discover_server_run_dirs() -> Dict[str, Path]:
    run_dirs: Dict[str, Path] = {}
    for summary_path in sorted(SERVER_RESULTS_DIR.glob("**/summary.env")):
        if any(part in ("campaigns", "run_sets") for part in summary_path.parts):
            continue
        env = parse_env(summary_path)
        run_id = env.get("run_id")
        if run_id:
            run_dirs[run_id] = summary_path.parent
    return run_dirs


def load_ok_client_rows() -> Dict[str, Dict[str, str]]:
    rows = load_ok_run_set_rows(CLIENT_RESULTS_DIR)
    if rows:
        return rows

    for run_id, run_dir in discover_client_run_dirs().items():
        matrix_path = run_dir / "matrix.tsv"
        if not matrix_path.exists():
            continue

        client_rows = read_tsv(matrix_path)
        if not client_rows:
            continue
        if any(row.get("status") != "ok" for row in client_rows):
            continue

        first = client_rows[0]
        request_path = row_value(first, "request_paths", "path")
        streams = row_value(first, "streams")
        rows[run_id] = {
            "run_id": run_id,
            "scenario": row_value(first, "scenario"),
            "workload": infer_workload(request_path, streams),
            "request_paths": request_path,
            "path": request_path,
            "clients": row_value(first, "clients"),
            "streams": streams,
            "_manifest_path": "",
        }

    return rows


def load_ok_server_rows() -> Dict[str, Dict[str, str]]:
    rows = load_ok_run_set_rows(SERVER_RESULTS_DIR)
    if rows:
        return rows

    for run_id, run_dir in discover_server_run_dirs().items():
        status_path = run_dir / "status.txt"
        summary_path = run_dir / "summary.env"
        if not status_path.exists() or not summary_path.exists():
            continue
        if status_path.read_text().strip() != "ok":
            continue

        env = parse_env(summary_path)
        rows[run_id] = {
            "run_id": run_id,
            "scenario": env.get("scenario", ""),
            "_manifest_path": "",
        }

    return rows


def paired_runs() -> List[PairedRun]:
    client_rows = load_ok_client_rows()
    server_rows = load_ok_server_rows()
    client_dirs = discover_client_run_dirs()
    server_dirs = discover_server_run_dirs()

    runs: List[PairedRun] = []
    for run_id in sorted(set(client_rows) & set(server_rows)):
        client_row = client_rows[run_id]
        server_row = server_rows[run_id]
        client_dir = client_dirs.get(run_id)
        server_dir = server_dirs.get(run_id)
        if client_dir is None or server_dir is None:
            continue
        client_manifest_path = (
            Path(client_row["_manifest_path"])
            if client_row.get("_manifest_path")
            else client_dir / "matrix.tsv"
        )
        server_manifest_path = (
            Path(server_row["_manifest_path"])
            if server_row.get("_manifest_path")
            else server_dir / "summary.env"
        )
        runs.append(
            PairedRun(
                run_id=run_id,
                scenario=client_row["scenario"],
                workload=client_row["workload"],
                request_paths=row_value(client_row, "request_paths", "path"),
                clients=row_value(client_row, "clients"),
                streams=row_value(client_row, "streams"),
                client_manifest=client_manifest_path,
                server_manifest=server_manifest_path,
                client_dir=client_dir,
                server_dir=server_dir,
            )
        )
    return runs


def qlog_file_stats(run_dir: Path) -> Dict[str, int]:
    qlog_files_path = run_dir / "qlog-files.txt"
    if not qlog_files_path.exists():
        return {
            "qlog_file_entries": 0,
            "qlog_zero_byte_files": 0,
            "qlog_nonzero_files": 0,
            "qlog_largest_file_bytes": 0,
            "qlog_files_total_bytes": 0,
        }

    total_bytes = 0
    zero_count = 0
    nonzero_count = 0
    largest = 0

    for line in qlog_files_path.read_text().splitlines():
        if not line:
            continue
        try:
            _, size_text = line.rsplit(" ", 1)
            size = int(size_text)
        except ValueError:
            continue
        total_bytes += size
        if size == 0:
            zero_count += 1
        else:
            nonzero_count += 1
            largest = max(largest, size)

    return {
        "qlog_file_entries": zero_count + nonzero_count,
        "qlog_zero_byte_files": zero_count,
        "qlog_nonzero_files": nonzero_count,
        "qlog_largest_file_bytes": largest,
        "qlog_files_total_bytes": total_bytes,
    }


def parse_mpstat_stats(path: Path) -> Dict[str, float]:
    if not path.exists():
        return {
            "server_cpu_samples": 0,
            "server_cpu_busy_pct": 0.0,
            "server_cpu_idle_pct": 0.0,
            "server_cpu_usr_pct": 0.0,
            "server_cpu_sys_pct": 0.0,
            "server_cpu_soft_pct": 0.0,
            "server_cpu_iowait_pct": 0.0,
            "server_cpu_steal_pct": 0.0,
        }

    samples = []

    for line in path.read_text().splitlines():
        cols = line.split()
        if len(cols) < 12:
            continue
        if cols[0] != "Average:" and not re.fullmatch(r"\d{2}:\d{2}:\d{2}", cols[0]):
            continue
        if cols[1] != "all":
            continue

        try:
            usr = float(cols[2])
            sys_pct = float(cols[4])
            iowait = float(cols[5])
            soft = float(cols[7])
            steal = float(cols[8])
            idle = float(cols[11])
        except ValueError:
            continue

        busy = 100.0 - idle
        samples.append(
            {
                "busy": busy,
                "idle": idle,
                "usr": usr,
                "sys": sys_pct,
                "soft": soft,
                "iowait": iowait,
                "steal": steal,
            }
        )

    if not samples:
        return {
            "server_cpu_samples": 0,
            "server_cpu_busy_pct": 0.0,
            "server_cpu_idle_pct": 0.0,
            "server_cpu_usr_pct": 0.0,
            "server_cpu_sys_pct": 0.0,
            "server_cpu_soft_pct": 0.0,
            "server_cpu_iowait_pct": 0.0,
            "server_cpu_steal_pct": 0.0,
        }

    sample_count = len(samples)

    def mean(key: str) -> float:
        return sum(sample[key] for sample in samples) / sample_count

    return {
        "server_cpu_samples": sample_count,
        "server_cpu_busy_pct": mean("busy"),
        "server_cpu_idle_pct": mean("idle"),
        "server_cpu_usr_pct": mean("usr"),
        "server_cpu_sys_pct": mean("sys"),
        "server_cpu_soft_pct": mean("soft"),
        "server_cpu_iowait_pct": mean("iowait"),
        "server_cpu_steal_pct": mean("steal"),
    }


def aggregate_median(values: Iterable[float]) -> float:
    values = list(values)
    return float(statistics.median(values)) if values else 0.0


def main() -> None:
    runs = paired_runs()

    paired_rows: List[Dict[str, object]] = []
    client_case_rows: List[Dict[str, object]] = []
    workload_rows: List[Dict[str, object]] = []

    for run in runs:
        paired_rows.append(
            {
                "run_id": run.run_id,
                "scenario": run.scenario,
                "workload": run.workload,
                "request_paths": run.request_paths,
                "clients": run.clients,
                "streams": run.streams,
                "client_manifest": display_path(run.client_manifest),
                "server_manifest": display_path(run.server_manifest),
                "client_dir": display_path(run.client_dir),
                "server_dir": display_path(run.server_dir),
            }
        )

        client_rows = read_tsv(run.client_dir / "matrix.tsv")
        server_env = parse_env(run.server_dir / "summary.env")
        qlog_stats = qlog_file_stats(run.server_dir)
        mpstat_stats = parse_mpstat_stats(run.server_dir / "mpstat.log")

        total_succeeded = 0
        total_started = 0
        total_done = 0
        total_failed = 0
        total_errored = 0
        total_timeout = 0

        for row in client_rows:
            case_dir = run.client_dir / Path(row["result_dir"]).name
            requests_env = parse_env(case_dir / "requests.env")
            h2load_stats = parse_time_stats(case_dir / "h2load.txt")

            total_succeeded += as_int(requests_env.get("request_succeeded"))
            total_started += as_int(requests_env.get("request_started"))
            total_done += as_int(requests_env.get("request_done"))
            total_failed += as_int(requests_env.get("request_failed"))
            total_errored += as_int(requests_env.get("request_errored"))
            total_timeout += as_int(requests_env.get("request_timeout"))

            client_case_rows.append(
                {
                    "run_id": run.run_id,
                    "scenario": run.scenario,
                    "workload": run.workload,
                    "path": row["path"],
                    "clients": as_int(row["clients"]),
                    "streams": as_int(row["streams"]),
                    "threads": as_int(row["threads"]),
                    "repeat": as_int(row["repeat"]),
                    "status": row["status"],
                    "request_total": as_int(requests_env.get("request_total")),
                    "request_started": as_int(requests_env.get("request_started")),
                    "request_done": as_int(requests_env.get("request_done")),
                    "request_succeeded": as_int(requests_env.get("request_succeeded")),
                    "request_failed": as_int(requests_env.get("request_failed")),
                    "request_errored": as_int(requests_env.get("request_errored")),
                    "request_timeout": as_int(requests_env.get("request_timeout")),
                    "finished_seconds": h2load_stats.get("finished_seconds", 0.0),
                    "req_per_s": h2load_stats.get("req_per_s", 0.0),
                    "throughput_bytes_per_s": h2load_stats.get(
                        "throughput_bytes_per_s", 0.0
                    ),
                    "request_median_us": h2load_stats.get("request_median_us", 0.0),
                    "request_p95_us": h2load_stats.get("request_p95_us", 0.0),
                    "request_p99_us": h2load_stats.get("request_p99_us", 0.0),
                    "request_mean_us": h2load_stats.get("request_mean_us", 0.0),
                    "smoothed_rtt_median_us": h2load_stats.get(
                        "smoothed_rtt_median_us", 0.0
                    ),
                    "smoothed_rtt_p95_us": h2load_stats.get("smoothed_rtt_p95_us", 0.0),
                    "server_cpu_samples": as_int(mpstat_stats.get("server_cpu_samples")),
                    "server_cpu_busy_pct": mpstat_stats.get("server_cpu_busy_pct", 0.0),
                    "server_cpu_idle_pct": mpstat_stats.get("server_cpu_idle_pct", 0.0),
                    "server_cpu_usr_pct": mpstat_stats.get("server_cpu_usr_pct", 0.0),
                    "server_cpu_sys_pct": mpstat_stats.get("server_cpu_sys_pct", 0.0),
                    "server_cpu_soft_pct": mpstat_stats.get("server_cpu_soft_pct", 0.0),
                    "server_cpu_iowait_pct": mpstat_stats.get(
                        "server_cpu_iowait_pct", 0.0
                    ),
                    "server_cpu_steal_pct": mpstat_stats.get(
                        "server_cpu_steal_pct", 0.0
                    ),
                    "server_cpu_busy_per_krps": (
                        (
                            mpstat_stats.get("server_cpu_busy_pct", 0.0)
                            / h2load_stats.get("req_per_s", 0.0)
                        )
                        * 1000.0
                        if h2load_stats.get("req_per_s", 0.0)
                        else 0.0
                    ),
                    "case_dir": display_path(case_dir),
                }
            )

        qlog_total_bytes = as_int(server_env.get("qlog_total_bytes"))
        qlog_file_count = as_int(server_env.get("qlog_file_count"))
        qlog_bytes_per_request = (
            qlog_total_bytes / total_succeeded if total_succeeded else 0.0
        )
        qlog_bytes_per_nonzero_file = (
            qlog_total_bytes / qlog_stats["qlog_nonzero_files"]
            if qlog_stats["qlog_nonzero_files"]
            else 0.0
        )
        qlog_bytes_per_reported_file = (
            qlog_total_bytes / qlog_file_count if qlog_file_count else 0.0
        )
        qlog_ram_saturated = (
            run.scenario == "qlog-on-ram"
            and qlog_total_bytes >= int(0.99 * 8 * 1024 * 1024 * 1024)
            and qlog_stats["qlog_zero_byte_files"] > 0
        )

        workload_rows.append(
            {
                "run_id": run.run_id,
                "scenario": run.scenario,
                "workload": run.workload,
                "request_paths": run.request_paths,
                "clients": run.clients,
                "streams": run.streams,
                "server_qlog_dir": server_env.get("qlog_dir", ""),
                "server_run_seconds": as_int(server_env.get("run_seconds")),
                "server_tail_seconds": as_int(server_env.get("tail_seconds")),
                "server_cpu_samples": as_int(mpstat_stats.get("server_cpu_samples")),
                "server_cpu_busy_pct": mpstat_stats.get("server_cpu_busy_pct", 0.0),
                "server_cpu_idle_pct": mpstat_stats.get("server_cpu_idle_pct", 0.0),
                "server_cpu_usr_pct": mpstat_stats.get("server_cpu_usr_pct", 0.0),
                "server_cpu_sys_pct": mpstat_stats.get("server_cpu_sys_pct", 0.0),
                "server_cpu_soft_pct": mpstat_stats.get("server_cpu_soft_pct", 0.0),
                "server_cpu_iowait_pct": mpstat_stats.get(
                    "server_cpu_iowait_pct", 0.0
                ),
                "server_cpu_steal_pct": mpstat_stats.get(
                    "server_cpu_steal_pct", 0.0
                ),
                "total_request_started": total_started,
                "total_request_done": total_done,
                "total_request_succeeded": total_succeeded,
                "total_request_failed": total_failed,
                "total_request_errored": total_errored,
                "total_request_timeout": total_timeout,
                "qlog_file_count": qlog_file_count,
                "qlog_total_bytes": qlog_total_bytes,
                "qlog_bytes_per_request": qlog_bytes_per_request,
                "qlog_bytes_per_reported_file": qlog_bytes_per_reported_file,
                "qlog_file_entries": qlog_stats["qlog_file_entries"],
                "qlog_zero_byte_files": qlog_stats["qlog_zero_byte_files"],
                "qlog_nonzero_files": qlog_stats["qlog_nonzero_files"],
                "qlog_largest_file_bytes": qlog_stats["qlog_largest_file_bytes"],
                "qlog_bytes_per_nonzero_file": qlog_bytes_per_nonzero_file,
                "qlog_file_listing_total_bytes": qlog_stats["qlog_files_total_bytes"],
                "qlog_ram_saturated": "yes" if qlog_ram_saturated else "no",
                "server_dir": display_path(run.server_dir),
            }
        )

    cell_groups: Dict[tuple, List[Dict[str, object]]] = defaultdict(list)
    for row in client_case_rows:
        key = (
            row["scenario"],
            row["workload"],
            row["path"],
            row["clients"],
            row["streams"],
        )
        cell_groups[key].append(row)

    cell_rows: List[Dict[str, object]] = []
    for key, rows in sorted(cell_groups.items()):
        scenario, workload, path, clients, streams = key
        cell_rows.append(
            {
                "scenario": scenario,
                "workload": workload,
                "path": path,
                "clients": clients,
                "streams": streams,
                "repeats": len(rows),
                "median_req_per_s": aggregate_median(row["req_per_s"] for row in rows),
                "median_throughput_bytes_per_s": aggregate_median(
                    row["throughput_bytes_per_s"] for row in rows
                ),
                "median_request_median_us": aggregate_median(
                    row["request_median_us"] for row in rows
                ),
                "median_request_p95_us": aggregate_median(
                    row["request_p95_us"] for row in rows
                ),
                "median_request_p99_us": aggregate_median(
                    row["request_p99_us"] for row in rows
                ),
                "median_request_mean_us": aggregate_median(
                    row["request_mean_us"] for row in rows
                ),
                "median_server_cpu_busy_pct": aggregate_median(
                    row["server_cpu_busy_pct"] for row in rows
                ),
                "median_server_cpu_usr_pct": aggregate_median(
                    row["server_cpu_usr_pct"] for row in rows
                ),
                "median_server_cpu_sys_pct": aggregate_median(
                    row["server_cpu_sys_pct"] for row in rows
                ),
                "median_server_cpu_soft_pct": aggregate_median(
                    row["server_cpu_soft_pct"] for row in rows
                ),
                "median_server_cpu_iowait_pct": aggregate_median(
                    row["server_cpu_iowait_pct"] for row in rows
                ),
                "median_server_cpu_steal_pct": aggregate_median(
                    row["server_cpu_steal_pct"] for row in rows
                ),
                "median_server_cpu_busy_per_krps": aggregate_median(
                    row["server_cpu_busy_per_krps"] for row in rows
                ),
                "total_request_succeeded": sum(
                    as_int(row["request_succeeded"]) for row in rows
                ),
            }
        )

    baseline_map = {
        (row["workload"], row["path"], row["clients"], row["streams"]): row
        for row in cell_rows
        if row["scenario"] == BASELINE_SCENARIO
    }
    qlog_off_map = {
        (row["workload"], row["path"], row["clients"], row["streams"]): row
        for row in cell_rows
        if row["scenario"] == "qlog-off"
    }
    ram_map = {
        (row["workload"], row["path"], row["clients"], row["streams"]): row
        for row in cell_rows
        if row["scenario"] == "qlog-on-ram"
    }

    comparison_rows: List[Dict[str, object]] = []
    for row in cell_rows:
        key = (row["workload"], row["path"], row["clients"], row["streams"])
        baseline = baseline_map.get(key)
        ram = ram_map.get(key)
        baseline_req_per_s = baseline["median_req_per_s"] if baseline else 0.0
        baseline_p95 = baseline["median_request_p95_us"] if baseline else 0.0
        baseline_cpu_busy = baseline["median_server_cpu_busy_pct"] if baseline else 0.0
        baseline_cpu_per_krps = (
            baseline["median_server_cpu_busy_per_krps"] if baseline else 0.0
        )
        qlog_off = qlog_off_map.get(key)
        qlog_off_req_per_s = qlog_off["median_req_per_s"] if qlog_off else 0.0
        ram_req_per_s = ram["median_req_per_s"] if ram else 0.0

        delta_vs_master_req_pct = (
            ((row["median_req_per_s"] - baseline_req_per_s) / baseline_req_per_s) * 100.0
            if baseline_req_per_s
            else 0.0
        )
        delta_vs_master_p95_pct = (
            ((row["median_request_p95_us"] - baseline_p95) / baseline_p95) * 100.0
            if baseline_p95
            else 0.0
        )
        delta_vs_master_cpu_busy_pct = (
            ((row["median_server_cpu_busy_pct"] - baseline_cpu_busy) / baseline_cpu_busy)
            * 100.0
            if baseline_cpu_busy
            else 0.0
        )
        delta_vs_master_cpu_per_krps_pct = (
            (
                (
                    row["median_server_cpu_busy_per_krps"]
                    - baseline_cpu_per_krps
                )
                / baseline_cpu_per_krps
            )
            * 100.0
            if baseline_cpu_per_krps
            else 0.0
        )
        delta_vs_qlog_off_req_pct = (
            ((row["median_req_per_s"] - qlog_off_req_per_s) / qlog_off_req_per_s) * 100.0
            if qlog_off_req_per_s
            else 0.0
        )
        delta_vs_qlog_on_ram_req_pct = (
            ((row["median_req_per_s"] - ram_req_per_s) / ram_req_per_s) * 100.0
            if ram_req_per_s
            else 0.0
        )

        comparison_rows.append(
            {
                **row,
                "delta_req_per_s_vs_master_pct": delta_vs_master_req_pct,
                "delta_request_p95_vs_master_pct": delta_vs_master_p95_pct,
                "delta_server_cpu_busy_vs_master_pct": delta_vs_master_cpu_busy_pct,
                "delta_server_cpu_busy_per_krps_vs_master_pct": delta_vs_master_cpu_per_krps_pct,
                "delta_req_per_s_vs_qlog_off_pct": delta_vs_qlog_off_req_pct,
                "delta_req_per_s_vs_qlog_on_ram_pct": delta_vs_qlog_on_ram_req_pct,
            }
        )

    write_tsv(
        ANALYSIS_DIR / "paired_runs.tsv",
        paired_rows,
        [
            "run_id",
            "scenario",
            "workload",
            "request_paths",
            "clients",
            "streams",
            "client_manifest",
            "server_manifest",
            "client_dir",
            "server_dir",
        ],
    )
    write_tsv(
        ANALYSIS_DIR / "client_case_summary.tsv",
        client_case_rows,
        [
            "run_id",
            "scenario",
            "workload",
            "path",
            "clients",
            "streams",
            "threads",
            "repeat",
            "status",
            "request_total",
            "request_started",
            "request_done",
            "request_succeeded",
            "request_failed",
            "request_errored",
            "request_timeout",
            "finished_seconds",
            "req_per_s",
            "throughput_bytes_per_s",
            "request_median_us",
            "request_p95_us",
            "request_p99_us",
            "request_mean_us",
            "smoothed_rtt_median_us",
            "smoothed_rtt_p95_us",
            "server_cpu_samples",
            "server_cpu_busy_pct",
            "server_cpu_idle_pct",
            "server_cpu_usr_pct",
            "server_cpu_sys_pct",
            "server_cpu_soft_pct",
            "server_cpu_iowait_pct",
            "server_cpu_steal_pct",
            "server_cpu_busy_per_krps",
            "case_dir",
        ],
    )
    write_tsv(
        ANALYSIS_DIR / "workload_run_summary.tsv",
        workload_rows,
        [
            "run_id",
            "scenario",
            "workload",
            "request_paths",
            "clients",
            "streams",
            "server_qlog_dir",
            "server_run_seconds",
            "server_tail_seconds",
            "server_cpu_samples",
            "server_cpu_busy_pct",
            "server_cpu_idle_pct",
            "server_cpu_usr_pct",
            "server_cpu_sys_pct",
            "server_cpu_soft_pct",
            "server_cpu_iowait_pct",
            "server_cpu_steal_pct",
            "total_request_started",
            "total_request_done",
            "total_request_succeeded",
            "total_request_failed",
            "total_request_errored",
            "total_request_timeout",
            "qlog_file_count",
            "qlog_total_bytes",
            "qlog_bytes_per_request",
            "qlog_bytes_per_reported_file",
            "qlog_file_entries",
            "qlog_zero_byte_files",
            "qlog_nonzero_files",
            "qlog_largest_file_bytes",
            "qlog_bytes_per_nonzero_file",
            "qlog_file_listing_total_bytes",
            "qlog_ram_saturated",
            "server_dir",
        ],
    )
    write_tsv(
        ANALYSIS_DIR / "client_cell_summary.tsv",
        cell_rows,
        [
            "scenario",
            "workload",
            "path",
            "clients",
            "streams",
            "repeats",
            "median_req_per_s",
            "median_throughput_bytes_per_s",
            "median_request_median_us",
            "median_request_p95_us",
            "median_request_p99_us",
            "median_request_mean_us",
            "median_server_cpu_busy_pct",
            "median_server_cpu_usr_pct",
            "median_server_cpu_sys_pct",
            "median_server_cpu_soft_pct",
            "median_server_cpu_iowait_pct",
            "median_server_cpu_steal_pct",
            "median_server_cpu_busy_per_krps",
            "total_request_succeeded",
        ],
    )
    write_tsv(
        ANALYSIS_DIR / "client_cell_comparison.tsv",
        comparison_rows,
        [
            "scenario",
            "workload",
            "path",
            "clients",
            "streams",
            "repeats",
            "median_req_per_s",
            "median_throughput_bytes_per_s",
            "median_request_median_us",
            "median_request_p95_us",
            "median_request_p99_us",
            "median_request_mean_us",
            "median_server_cpu_busy_pct",
            "median_server_cpu_usr_pct",
            "median_server_cpu_sys_pct",
            "median_server_cpu_soft_pct",
            "median_server_cpu_iowait_pct",
            "median_server_cpu_steal_pct",
            "median_server_cpu_busy_per_krps",
            "total_request_succeeded",
            "delta_req_per_s_vs_master_pct",
            "delta_request_p95_vs_master_pct",
            "delta_server_cpu_busy_vs_master_pct",
            "delta_server_cpu_busy_per_krps_vs_master_pct",
            "delta_req_per_s_vs_qlog_off_pct",
            "delta_req_per_s_vs_qlog_on_ram_pct",
        ],
    )

    print(f"Wrote analysis outputs to {display_path(ANALYSIS_DIR)}")
    print(f"Paired runs: {len(paired_rows)}")


if __name__ == "__main__":
    main()
