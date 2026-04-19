#!/usr/bin/env bash

set -euo pipefail


SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=bench/bench_common.sh
source "$SCRIPT_DIR/bench_common.sh"


usage() {
    cat <<EOF
Start one nginx benchmark scenario on the server, collect system metrics, and
stop nginx cleanly after the run window.

Usage:
  $(basename "$0") <scenario>

Scenarios:
$(bench_list_scenarios | sed 's/^/  - /')

Environment overrides:
  PREFIX_ROOT=\$HOME/opt/nginx-bench
  RESULTS_ROOT=\$PREFIX_ROOT/results/server
  RUN_ID=<shared run identifier>
  RUN_SECONDS=75
  TAIL_SECONDS=5
  SAMPLE_INTERVAL=1
  CLEAR_QLOG=1
  STOP_RUNNING=1
  WRITE_SYSCALL_TRACE=auto
  WRITE_SYSCALL_SUDO=1

Examples:
  RUN_ID=pilot-001 RUN_SECONDS=75 bench/run_server_measurement.sh quic-qlog
  RUN_ID=pilot-002 RUN_SECONDS=75 bench/run_server_measurement.sh quic-qlog-no-buffer

Notes:
  - Start this on the server VM before the client-side h2load run.
  - Default behavior is fixed-duration. Use RUN_SECONDS=0 to keep the server
    running until Ctrl-C.
EOF
}


copy_if_exists() {
    local src="$1"
    local dst="$2"

    [[ -f "$src" ]] || return 0
    cp "$src" "$dst"
}


is_pid_running() {
    local pid="$1"

    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}


read_pid_file() {
    local pid_file="$1"

    [[ -f "$pid_file" ]] || return 1
    tr -d '[:space:]' <"$pid_file"
}


list_benchmark_nginx_pids() {
    local master_pid="${SERVER_PID:-$(read_pid_file "$BENCH_SCENARIO_PID_FILE" || true)}"
    local child_pid

    if ! is_pid_running "$master_pid"; then
        return 0
    fi

    printf '%s\n' "$master_pid"

    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        is_pid_running "$child_pid" || continue
        printf '%s\n' "$child_pid"
    done < <(ps -o pid= --ppid "$master_pid" 2>/dev/null || true)
}


join_csv_lines() {
    awk '
        NF {
            if (count > 0) {
                printf ","
            }
            printf "%s", $0
            count++
        }
        END {
            if (count > 0) {
                printf "\n"
            }
        }
    '
}


wait_for_pid_exit() {
    local pid="$1"
    local timeout="$2"
    local waited=0

    while is_pid_running "$pid"; do
        if (( waited >= timeout )); then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 0
}


stop_nginx_if_running() {
    local pid

    pid="$(read_pid_file "$BENCH_SCENARIO_PID_FILE" || true)"

    if ! is_pid_running "$pid"; then
        return 0
    fi

    bench_log "Stopping existing nginx process $pid for $SCENARIO"

    if ! "$BENCH_SCENARIO_BIN" -c "$BENCH_SCENARIO_CONFIG" -s quit >/dev/null 2>&1; then
        kill -TERM "$pid" 2>/dev/null || true
    fi

    wait_for_pid_exit "$pid" 15 || bench_die "nginx pid $pid did not exit cleanly"
    rm -f "$BENCH_SCENARIO_PID_FILE"
}


is_benchmark_nginx_pid() {
    local pid="$1"
    local cmd=""

    [[ -n "$pid" ]] || return 1
    is_pid_running "$pid" || return 1

    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ -n "$cmd" ]] || return 1
    [[ "$cmd" == *nginx* ]] || return 1
    [[ "$cmd" == *"$PREFIX_ROOT"* ]] || return 1
}


stop_all_benchmark_nginx() {
    local pid_file
    local pid

    while IFS= read -r pid_file; do
        [[ -n "$pid_file" ]] || continue

        pid="$(read_pid_file "$pid_file" || true)"

        if ! is_benchmark_nginx_pid "$pid"; then
            rm -f "$pid_file"
            continue
        fi

        bench_log "Stopping benchmark nginx process $pid from $pid_file"
        kill -TERM "$pid" 2>/dev/null || true

        wait_for_pid_exit "$pid" 15 \
            || bench_die "benchmark nginx pid $pid did not exit cleanly"

        rm -f "$pid_file"
    done < <(
        find "$PREFIX_ROOT" -mindepth 2 -maxdepth 3 -type f -path '*/run/*.pid' | sort
    )
}


start_nginx() {
    bench_log "Validating nginx config"
    "$BENCH_SCENARIO_BIN" -t -c "$BENCH_SCENARIO_CONFIG" >/dev/null

    if [[ "$STOP_RUNNING" == "1" ]]; then
        stop_all_benchmark_nginx
    fi

    bench_log "Starting nginx for $SCENARIO"
    "$BENCH_SCENARIO_BIN" -c "$BENCH_SCENARIO_CONFIG"

    SERVER_PID="$(read_pid_file "$BENCH_SCENARIO_PID_FILE" || true)"
    is_pid_running "$SERVER_PID" \
        || bench_die "nginx failed to start for $SCENARIO"
}


stop_nginx() {
    local pid

    pid="${SERVER_PID:-$(read_pid_file "$BENCH_SCENARIO_PID_FILE" || true)}"

    if ! is_pid_running "$pid"; then
        return 0
    fi

    bench_log "Stopping nginx pid $pid"

    if ! "$BENCH_SCENARIO_BIN" -c "$BENCH_SCENARIO_CONFIG" -s quit >/dev/null 2>&1; then
        kill -TERM "$pid" 2>/dev/null || true
    fi

    wait_for_pid_exit "$pid" 15 || bench_die "nginx pid $pid did not stop cleanly"
}


clear_qlog_dir() {
    if [[ -z "$BENCH_SCENARIO_QLOG_DIR" ]]; then
        return 0
    fi

    [[ -d "$BENCH_SCENARIO_QLOG_DIR" ]] \
        || bench_die "qlog directory does not exist: $BENCH_SCENARIO_QLOG_DIR"

    if [[ "$CLEAR_QLOG" != "1" ]]; then
        return 0
    fi

    bench_log "Clearing old qlog files in $BENCH_SCENARIO_QLOG_DIR"
    find "$BENCH_SCENARIO_QLOG_DIR" -maxdepth 1 -type f -name '*.sqlog' -delete
}


collect_qlog_summary() {
    local qlog_count=0
    local qlog_bytes=0

    if [[ -n "$BENCH_SCENARIO_QLOG_DIR" && -d "$BENCH_SCENARIO_QLOG_DIR" ]]; then
        qlog_count="$(find "$BENCH_SCENARIO_QLOG_DIR" -maxdepth 1 -type f -name '*.sqlog' | wc -l | tr -d '[:space:]')"
        qlog_bytes="$(du -sb "$BENCH_SCENARIO_QLOG_DIR" | awk '{print $1}')"
        find "$BENCH_SCENARIO_QLOG_DIR" -maxdepth 1 -type f -name '*.sqlog' \
            -exec stat -c '%n %s' {} \; | sort >"$RUN_DIR/qlog-files.txt"
    fi

    collect_write_syscall_summary

    {
        printf 'scenario=%s\n' "$SCENARIO"
        printf 'run_id=%s\n' "$RUN_ID"
        printf 'host=%s\n' "$HOST_FQDN"
        printf 'listen_port=%s\n' "${BENCH_SCENARIO_LISTEN_PORT:-unknown}"
        printf 'nginx_pid=%s\n' "${SERVER_PID:-unknown}"
        printf 'run_seconds=%s\n' "$RUN_SECONDS"
        printf 'tail_seconds=%s\n' "$TAIL_SECONDS"
        printf 'sample_interval=%s\n' "$SAMPLE_INTERVAL"
        printf 'start_utc=%s\n' "$START_UTC"
        printf 'stop_utc=%s\n' "$STOP_UTC"
        printf 'qlog_dir=%s\n' "${BENCH_SCENARIO_QLOG_DIR:-<disabled>}"
        printf 'qlog_file_count=%s\n' "$qlog_count"
        printf 'qlog_total_bytes=%s\n' "$qlog_bytes"
        printf 'write_syscall_trace=%s\n' "$WRITE_SYSCALL_TRACE_STATUS"
        printf 'write_syscall_write=%s\n' "$WRITE_SYSCALL_WRITE"
        printf 'write_syscall_writev=%s\n' "$WRITE_SYSCALL_WRITEV"
        printf 'write_syscall_pwrite64=%s\n' "$WRITE_SYSCALL_PWRITE64"
        printf 'write_syscall_pwritev=%s\n' "$WRITE_SYSCALL_PWRITEV"
        printf 'write_syscall_pwritev2=%s\n' "$WRITE_SYSCALL_PWRITEV2"
        printf 'write_syscall_total=%s\n' "$WRITE_SYSCALL_TOTAL"
    } >"$RUN_DIR/summary.env"
}


collect_write_syscall_summary() {
    local perf_output="$RUN_DIR/write-syscalls.perf-stat.txt"
    local event
    local value

    WRITE_SYSCALL_WRITE=0
    WRITE_SYSCALL_WRITEV=0
    WRITE_SYSCALL_PWRITE64=0
    WRITE_SYSCALL_PWRITEV=0
    WRITE_SYSCALL_PWRITEV2=0
    WRITE_SYSCALL_TOTAL=0

    [[ -f "$perf_output" ]] || return 0

    while IFS=, read -r value _ event _; do
        [[ -n "$event" ]] || continue
        [[ "$value" =~ ^[0-9][0-9]*$ ]] || continue

        case "$event" in
            syscalls:sys_enter_write)
                WRITE_SYSCALL_WRITE="$value"
                ;;
            syscalls:sys_enter_writev)
                WRITE_SYSCALL_WRITEV="$value"
                ;;
            syscalls:sys_enter_pwrite64)
                WRITE_SYSCALL_PWRITE64="$value"
                ;;
            syscalls:sys_enter_pwritev)
                WRITE_SYSCALL_PWRITEV="$value"
                ;;
            syscalls:sys_enter_pwritev2)
                WRITE_SYSCALL_PWRITEV2="$value"
                ;;
        esac
    done <"$perf_output"

    WRITE_SYSCALL_TOTAL=$((
        WRITE_SYSCALL_WRITE +
        WRITE_SYSCALL_WRITEV +
        WRITE_SYSCALL_PWRITE64 +
        WRITE_SYSCALL_PWRITEV +
        WRITE_SYSCALL_PWRITEV2
    ))

    if (( WRITE_SYSCALL_TOTAL == 0 )) && grep -qi 'failed\|not supported\|permission\|can.t access trace events' "$perf_output"; then
        WRITE_SYSCALL_TRACE_STATUS="failed"
    fi
}


start_write_syscall_collector() {
    local pid_csv
    local perf_output="$RUN_DIR/write-syscalls.perf-stat.txt"
    local perf_stderr="$RUN_DIR/write-syscalls.perf-stat.stderr.txt"
    local -a perf_cmd
    local -a pid_args
    local pid

    WRITE_SYSCALL_TRACE_STATUS="disabled"
    WRITE_SYSCALL_COLLECTOR_PID=""

    if [[ "$WRITE_SYSCALL_TRACE" == "0" || "$WRITE_SYSCALL_TRACE" == "off" ]]; then
        return 0
    fi

    if ! command -v perf >/dev/null 2>&1; then
        if [[ "$WRITE_SYSCALL_TRACE" == "auto" ]]; then
            WRITE_SYSCALL_TRACE_STATUS="unavailable"
            return 0
        fi
        bench_die "WRITE_SYSCALL_TRACE=$WRITE_SYSCALL_TRACE requested, but perf is not installed"
    fi

    if [[ "$WRITE_SYSCALL_SUDO" == "1" && "$EUID" != "0" ]] \
        && ! command -v sudo >/dev/null 2>&1; then
        if [[ "$WRITE_SYSCALL_TRACE" == "auto" ]]; then
            WRITE_SYSCALL_TRACE_STATUS="unavailable"
            return 0
        fi
        bench_die "WRITE_SYSCALL_SUDO=1 requested, but sudo is not installed"
    fi

    sleep 1
    pid_csv="$(list_benchmark_nginx_pids | join_csv_lines)"
    if [[ -z "$pid_csv" ]]; then
        if [[ "$WRITE_SYSCALL_TRACE" == "auto" ]]; then
            WRITE_SYSCALL_TRACE_STATUS="no-pids"
            return 0
        fi
        bench_die "failed to resolve nginx pids for write syscall tracing"
    fi

    IFS=',' read -r -a pid_args_raw <<<"$pid_csv"
    pid_args=()
    for pid in "${pid_args_raw[@]}"; do
        [[ -n "$pid" ]] || continue
        pid_args+=( -p "$pid" )
    done
    if [[ ${#pid_args[@]} -eq 0 ]]; then
        if [[ "$WRITE_SYSCALL_TRACE" == "auto" ]]; then
            WRITE_SYSCALL_TRACE_STATUS="no-pids"
            return 0
        fi
        bench_die "failed to build perf pid arguments for write syscall tracing"
    fi

    bench_log "Starting write syscall collector for nginx pids: $pid_csv"
    perf_cmd=(perf stat -x, -o "$perf_output" \
        -e syscalls:sys_enter_write \
        -e syscalls:sys_enter_writev \
        -e syscalls:sys_enter_pwrite64 \
        -e syscalls:sys_enter_pwritev \
        -e syscalls:sys_enter_pwritev2 \
        "${pid_args[@]}" -- sleep 1000000)
    if [[ "$WRITE_SYSCALL_SUDO" == "1" && "$EUID" != "0" ]]; then
        perf_cmd=(sudo -n "${perf_cmd[@]}")
    fi

    : >"$perf_stderr"
    if setsid "${perf_cmd[@]}" </dev/null >/dev/null 2>>"$perf_stderr" & then
        WRITE_SYSCALL_COLLECTOR_PID=$!
        sleep 1
        if ! is_pid_running "$WRITE_SYSCALL_COLLECTOR_PID"; then
            WRITE_SYSCALL_TRACE_STATUS="failed"
            wait "$WRITE_SYSCALL_COLLECTOR_PID" 2>/dev/null || true
            WRITE_SYSCALL_COLLECTOR_PID=""
            if [[ "$WRITE_SYSCALL_TRACE" == "auto" ]]; then
                return 0
            fi
            bench_die "write syscall collector exited immediately"
        fi

        WRITE_SYSCALL_TRACE_STATUS="running"
        printf '%s\n' "$WRITE_SYSCALL_COLLECTOR_PID" >"$RUN_DIR/write-syscalls.pid"
        printf '%s\n' "$pid_csv" >"$RUN_DIR/write-syscalls.target-pids.txt"
        printf '%s\n' "$WRITE_SYSCALL_SUDO" >"$RUN_DIR/write-syscalls.sudo-enabled.txt"
    else
        if [[ "$WRITE_SYSCALL_TRACE" == "auto" ]]; then
            WRITE_SYSCALL_TRACE_STATUS="failed"
            return 0
        fi
        bench_die "failed to start write syscall collector"
    fi
}


stop_write_syscall_collector() {
    local pid="${WRITE_SYSCALL_COLLECTOR_PID:-}"

    [[ -n "$pid" ]] || return 0
    is_pid_running "$pid" || return 0

    kill -INT -- "-$pid" 2>/dev/null || kill -INT "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    if [[ "$WRITE_SYSCALL_TRACE_STATUS" == "running" ]]; then
        WRITE_SYSCALL_TRACE_STATUS="collected"
    fi
}


start_collectors() {
    bench_log "Starting collectors in $RUN_DIR"

    mpstat -P ALL "$SAMPLE_INTERVAL" >"$RUN_DIR/mpstat.log" 2>&1 &
    MPSTAT_PID=$!

    iostat -xz "$SAMPLE_INTERVAL" >"$RUN_DIR/iostat.log" 2>&1 &
    IOSTAT_PID=$!

    sar -n DEV "$SAMPLE_INTERVAL" >"$RUN_DIR/sar-dev.log" 2>&1 &
    SAR_PID=$!

    printf '%s\n' "$MPSTAT_PID" >"$RUN_DIR/mpstat.pid"
    printf '%s\n' "$IOSTAT_PID" >"$RUN_DIR/iostat.pid"
    printf '%s\n' "$SAR_PID" >"$RUN_DIR/sar.pid"
}


stop_collectors() {
    local pid

    for pid in "${MPSTAT_PID:-}" "${IOSTAT_PID:-}" "${SAR_PID:-}"; do
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}


write_metadata() {
    {
        printf 'scenario=%s\n' "$SCENARIO"
        printf 'run_id=%s\n' "$RUN_ID"
        printf 'host=%s\n' "$HOST_FQDN"
        printf 'run_seconds=%s\n' "$RUN_SECONDS"
        printf 'tail_seconds=%s\n' "$TAIL_SECONDS"
        printf 'sample_interval=%s\n' "$SAMPLE_INTERVAL"
        printf 'results_dir=%s\n' "$RUN_DIR"
        printf 'nginx_binary=%s\n' "$BENCH_SCENARIO_BIN"
        printf 'nginx_config=%s\n' "$BENCH_SCENARIO_CONFIG"
        printf 'nginx_pid_file=%s\n' "$BENCH_SCENARIO_PID_FILE"
        printf 'listen_port=%s\n' "${BENCH_SCENARIO_LISTEN_PORT:-unknown}"
        printf 'qlog_dir=%s\n' "${BENCH_SCENARIO_QLOG_DIR:-<disabled>}"
        printf 'write_syscall_trace=%s\n' "$WRITE_SYSCALL_TRACE"
    } >"$RUN_DIR/run.env"

    copy_if_exists "$BENCH_SCENARIO_CONFIG" "$RUN_DIR/nginx.conf"
    "$BENCH_SCENARIO_BIN" -V >"$RUN_DIR/nginx-V.txt" 2>&1
    hostnamectl >"$RUN_DIR/hostnamectl.txt" 2>&1 || true
    lscpu >"$RUN_DIR/lscpu.txt" 2>&1 || true
}


finish_run() {
    local status="$1"

    STOP_UTC="$(date -u '+%FT%TZ')"

    stop_collectors
    stop_write_syscall_collector
    stop_nginx
    collect_qlog_summary

    printf '%s\n' "$status" >"$RUN_DIR/status.txt"
    bench_log "Run completed with status=$status"
    bench_log "Results saved in $RUN_DIR"
}


trap_handler() {
    STOP_REQUESTED=1
}


run_window() {
    local remaining

    if (( RUN_SECONDS == 0 )); then
        bench_log "Server run active until Ctrl-C"
        while (( STOP_REQUESTED == 0 )); do
            sleep 1
        done
        return
    fi

    remaining=$((RUN_SECONDS + TAIL_SECONDS))
    bench_log "Server run active for ${RUN_SECONDS}s + ${TAIL_SECONDS}s tail"

    while (( remaining > 0 && STOP_REQUESTED == 0 )); do
        sleep 1
        remaining=$((remaining - 1))
    done
}


if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

SCENARIO="${1:-}"
[[ -n "$SCENARIO" ]] || {
    usage
    exit 1
}

PREFIX_ROOT="${PREFIX_ROOT:-$HOME/opt/nginx-bench}"
RESULTS_ROOT="${RESULTS_ROOT:-$PREFIX_ROOT/results/server}"
RUN_ID="${RUN_ID:-$(date -u '+%Y%m%dT%H%M%SZ')}"
RUN_SECONDS="${RUN_SECONDS:-75}"
TAIL_SECONDS="${TAIL_SECONDS:-5}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
CLEAR_QLOG="${CLEAR_QLOG:-1}"
STOP_RUNNING="${STOP_RUNNING:-1}"
WRITE_SYSCALL_TRACE="${WRITE_SYSCALL_TRACE:-auto}"
WRITE_SYSCALL_SUDO="${WRITE_SYSCALL_SUDO:-1}"

bench_ensure_cmd awk date du find grep hostname hostnamectl iostat lscpu mpstat sar sed setsid stat

bench_load_scenario "$PREFIX_ROOT" "$SCENARIO" \
    || bench_die "unknown scenario: $SCENARIO"

RUN_DIR="$RESULTS_ROOT/$RUN_ID/$SCENARIO"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
START_UTC="$(date -u '+%FT%TZ')"
STOP_UTC=""
SERVER_PID=""
STOP_REQUESTED=0
WRITE_SYSCALL_TRACE_STATUS="disabled"
WRITE_SYSCALL_COLLECTOR_PID=""
WRITE_SYSCALL_WRITE=0
WRITE_SYSCALL_WRITEV=0
WRITE_SYSCALL_PWRITE64=0
WRITE_SYSCALL_PWRITEV=0
WRITE_SYSCALL_PWRITEV2=0
WRITE_SYSCALL_TOTAL=0

mkdir -p "$RUN_DIR"

write_metadata
clear_qlog_dir

trap trap_handler INT TERM

start_nginx
start_write_syscall_collector
start_collectors

if ! run_window; then
    finish_run "failed"
    exit 1
fi

if (( STOP_REQUESTED == 1 )); then
    finish_run "interrupted"
else
    finish_run "ok"
fi
