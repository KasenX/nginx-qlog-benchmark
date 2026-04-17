#!/usr/bin/env bash

set -euo pipefail


SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bench/bench_common.sh
source "$SCRIPT_DIR/bench_common.sh"


usage() {
    cat <<'EOF'
Run indexed benchmark cases from a third machine via SSH.

This orchestrator starts the server-side case first, waits briefly, then starts
the matching client-side case. Both sides use the same RUN_SET_ID and case
index, so the existing run_case_by_index.sh logic determines the exact RUN_ID.

Usage:
  bench/run_cases_via_ssh.sh --list
  bench/run_cases_via_ssh.sh run <case-index> [<case-index> ...]
  bench/run_cases_via_ssh.sh range <start-index> <end-index>
  bench/run_cases_via_ssh.sh all

Required environment for run/range/all:
  SERVER_SSH=jakub@example-server
  CLIENT_SSH=jakub@example-client

Case-matrix selection:
  RUN_SET_ID=thesis-main
  SCENARIOS=quic-qlog,quic-qlog-no-buffer
  WORKLOADS=small,bulk
  REPEATS=3

Remote repo locations:
  SERVER_REPO_DIR=$HOME/nginx-qlog-benchmark
  CLIENT_REPO_DIR=$HOME/nginx-qlog-benchmark

Server-side overrides:
  PREFIX_ROOT=$HOME/opt/nginx-bench
  SERVER_RESULTS_ROOT=$PREFIX_ROOT/results/server
  SERVER_RUN_SECONDS=70
  TAIL_SECONDS=0
  SAMPLE_INTERVAL=1
  CLEAR_QLOG=1
  STOP_RUNNING=1

Client-side overrides:
  CLIENT_RESULTS_ROOT=$HOME/bench-results/client
  BASE_URI=https://84.17.61.47:8443
  CA_CERT_FILE=/remote/path/to/server.crt
  H2LOAD_BIN=h2load
  THREADS=4
  DURATION=45s
  WARMUP=10s
  INTER_RUN_SLEEP=0

Orchestrator behavior:
  SERVER_START_DELAY=3
  BETWEEN_CASE_DELAY=0
  STOP_ON_FAILURE=1
  ORCHESTRATOR_RESULTS_ROOT=$PWD/results/orchestrator

Examples:
  bench/run_cases_via_ssh.sh --list | sed -n '1,12p'
  RUN_SET_ID=thesis-main SERVER_SSH=jakub@84.17.61.47 CLIENT_SSH=jakub@89.222.113.26 \
    BASE_URI=https://84.17.61.47:8443 CA_CERT_FILE=/home/jakub/bench-certs/server.crt \
    bench/run_cases_via_ssh.sh run 1 2 3
  RUN_SET_ID=thesis-main SERVER_SSH=jakub@84.17.61.47 CLIENT_SSH=jakub@89.222.113.26 \
    bench/run_cases_via_ssh.sh range 1 12
EOF
}


shell_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\"\'\"\'}"
}


case_table() {
    RUN_SET_ID="$RUN_SET_ID" \
    SCENARIOS="$SCENARIOS" \
    WORKLOADS="$WORKLOADS" \
    REPEATS="$REPEATS" \
    bash "$SCRIPT_DIR/run_case_by_index.sh" --list
}


resolve_case_line() {
    local case_index="$1"

    awk -F '\t' -v idx="$case_index" '
        NR == 1 { next }
        ($1 + 0) == idx { print; exit }
    ' "$CASE_TABLE_FILE"
}


manifest_init() {
    mkdir -p "$RUN_SET_DIR/logs"
    if [[ ! -f "$MANIFEST_PATH" ]]; then
        printf '%s\n' \
            'case_index	run_id	scenario	workload	path	clients	streams	repeat	start_utc	stop_utc	server_exit	client_exit	status	server_log	client_log' \
            >"$MANIFEST_PATH"
    fi
}


manifest_append() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$CASE_INDEX_PADDED" \
        "$RUN_ID" \
        "$SCENARIO" \
        "$WORKLOAD" \
        "$REQUEST_PATH" \
        "$CLIENT_COUNT" \
        "$STREAM_COUNT" \
        "$REPEAT_LABEL" \
        "$START_UTC" \
        "$STOP_UTC" \
        "$SERVER_EXIT" \
        "$CLIENT_EXIT" \
        "$CASE_STATUS" \
        "$SERVER_LOG_PATH" \
        "$CLIENT_LOG_PATH" \
        >>"$MANIFEST_PATH"
}


run_server_background() {
    local case_index="$1"
    local log_path="$2"
    local server_repo_dir_line
    local prefix_root_line
    local server_results_root_line

    if [[ -n "$SERVER_REPO_DIR" ]]; then
        server_repo_dir_line="cd $(shell_quote "$SERVER_REPO_DIR")"
    else
        server_repo_dir_line='cd "${HOME}/nginx-qlog-benchmark"'
    fi

    if [[ -n "$PREFIX_ROOT" ]]; then
        prefix_root_line="export PREFIX_ROOT=$(shell_quote "$PREFIX_ROOT")"
    else
        prefix_root_line='export PREFIX_ROOT="${HOME}/opt/nginx-bench"'
    fi

    if [[ -n "$SERVER_RESULTS_ROOT" ]]; then
        server_results_root_line="export SERVER_RESULTS_ROOT=$(shell_quote "$SERVER_RESULTS_ROOT")"
    else
        server_results_root_line='export SERVER_RESULTS_ROOT="${PREFIX_ROOT}/results/server"'
    fi

    (
        ssh "$SERVER_SSH" \
            "exec \"\${SHELL:-/bin/bash}\" -lc 'bash -s'" <<EOF
set -euo pipefail
$server_repo_dir_line
export RUN_SET_ID=$(shell_quote "$RUN_SET_ID")
export SCENARIOS=$(shell_quote "$SCENARIOS")
export WORKLOADS=$(shell_quote "$WORKLOADS")
export REPEATS=$(shell_quote "$REPEATS")
$prefix_root_line
$server_results_root_line
export SERVER_RUN_SECONDS=$(shell_quote "$SERVER_RUN_SECONDS")
export TAIL_SECONDS=$(shell_quote "$TAIL_SECONDS")
export SAMPLE_INTERVAL=$(shell_quote "$SAMPLE_INTERVAL")
export CLEAR_QLOG=$(shell_quote "$CLEAR_QLOG")
export STOP_RUNNING=$(shell_quote "$STOP_RUNNING")
bash bench/run_case_by_index.sh server $(shell_quote "$case_index")
EOF
    ) 2>&1 | tee "$log_path" &
    SERVER_JOB_PID=$!
}


run_client_foreground() {
    local case_index="$1"
    local log_path="$2"
    local client_repo_dir_line
    local client_results_root_line
    local ca_cert_file_line

    if [[ -n "$CLIENT_REPO_DIR" ]]; then
        client_repo_dir_line="cd $(shell_quote "$CLIENT_REPO_DIR")"
    else
        client_repo_dir_line='cd "${HOME}/nginx-qlog-benchmark"'
    fi

    if [[ -n "$CLIENT_RESULTS_ROOT" ]]; then
        client_results_root_line="export CLIENT_RESULTS_ROOT=$(shell_quote "$CLIENT_RESULTS_ROOT")"
    else
        client_results_root_line='export CLIENT_RESULTS_ROOT="${HOME}/bench-results/client"'
    fi

    if [[ -n "$CA_CERT_FILE" ]]; then
        ca_cert_file_line="export CA_CERT_FILE=$(shell_quote "$CA_CERT_FILE")"
    else
        ca_cert_file_line='unset CA_CERT_FILE'
    fi

    ssh "$CLIENT_SSH" \
        "exec \"\${SHELL:-/bin/bash}\" -lc 'bash -s'" <<EOF 2>&1 | tee "$log_path"
set -euo pipefail
$client_repo_dir_line
export RUN_SET_ID=$(shell_quote "$RUN_SET_ID")
export SCENARIOS=$(shell_quote "$SCENARIOS")
export WORKLOADS=$(shell_quote "$WORKLOADS")
export REPEATS=$(shell_quote "$REPEATS")
$client_results_root_line
export BASE_URI=$(shell_quote "$BASE_URI")
$ca_cert_file_line
export H2LOAD_BIN=$(shell_quote "$H2LOAD_BIN")
export THREADS=$(shell_quote "$THREADS")
export DURATION=$(shell_quote "$DURATION")
export WARMUP=$(shell_quote "$WARMUP")
export INTER_RUN_SLEEP=$(shell_quote "$INTER_RUN_SLEEP")
bash bench/run_case_by_index.sh client $(shell_quote "$case_index")
EOF
}


run_case() {
    local case_index="$1"
    local case_line

    case_line="$(resolve_case_line "$case_index")"
    [[ -n "$case_line" ]] || bench_die "unknown case index: $case_index"

    IFS=$'\t' read -r CASE_INDEX_PADDED RUN_ID SCENARIO WORKLOAD REQUEST_PATH CLIENT_COUNT STREAM_COUNT REPEAT_LABEL <<<"$case_line"

    START_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    SERVER_LOG_PATH="$RUN_SET_DIR/logs/${RUN_ID}-server.log"
    CLIENT_LOG_PATH="$RUN_SET_DIR/logs/${RUN_ID}-client.log"
    SERVER_JOB_PID=""
    SERVER_EXIT=0
    CLIENT_EXIT=0
    CASE_STATUS="ok"

    bench_log \
        "Running case $CASE_INDEX_PADDED: $SCENARIO / $WORKLOAD / $REQUEST_PATH / c$CLIENT_COUNT / m$STREAM_COUNT / $REPEAT_LABEL"
    bench_log "run_id=$RUN_ID"

    run_server_background "$case_index" "$SERVER_LOG_PATH"
    sleep "$SERVER_START_DELAY"

    if ! kill -0 "$SERVER_JOB_PID" 2>/dev/null; then
        if wait "$SERVER_JOB_PID"; then
            SERVER_EXIT=0
        else
            SERVER_EXIT=$?
        fi
        CLIENT_EXIT=125
        CASE_STATUS="server-start-failed"
        STOP_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        manifest_append
        bench_die "server case exited before client start; see $SERVER_LOG_PATH"
    fi

    if run_client_foreground "$case_index" "$CLIENT_LOG_PATH"; then
        CLIENT_EXIT=0
    else
        CLIENT_EXIT=$?
        CASE_STATUS="client-failed"
    fi

    if wait "$SERVER_JOB_PID"; then
        SERVER_EXIT=0
    else
        SERVER_EXIT=$?
        if [[ "$CASE_STATUS" == "ok" ]]; then
            CASE_STATUS="server-failed"
        fi
    fi

    STOP_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    manifest_append

    if [[ "$CASE_STATUS" == "ok" ]]; then
        bench_log "Case $CASE_INDEX_PADDED completed successfully"
    else
        bench_log \
            "Case $CASE_INDEX_PADDED failed: status=$CASE_STATUS server_exit=$SERVER_EXIT client_exit=$CLIENT_EXIT"
        if [[ "$STOP_ON_FAILURE" == "1" ]]; then
            bench_die "stopping on first failure"
        fi
    fi

    if [[ "$BETWEEN_CASE_DELAY" != "0" ]]; then
        bench_log "Sleeping $BETWEEN_CASE_DELAY seconds before next case"
        sleep "$BETWEEN_CASE_DELAY"
    fi
}


if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

RUN_SET_ID="${RUN_SET_ID:-$(date -u '+%Y-%m-%d-orchestrated')}"
SCENARIOS="${SCENARIOS:-quic-qlog,quic-qlog-no-buffer}"
WORKLOADS="${WORKLOADS:-small,bulk}"
REPEATS="${REPEATS:-3}"

SERVER_SSH="${SERVER_SSH:-}"
CLIENT_SSH="${CLIENT_SSH:-}"
SERVER_REPO_DIR="${SERVER_REPO_DIR:-}"
CLIENT_REPO_DIR="${CLIENT_REPO_DIR:-}"

PREFIX_ROOT="${PREFIX_ROOT:-}"
SERVER_RESULTS_ROOT="${SERVER_RESULTS_ROOT:-}"
SERVER_RUN_SECONDS="${SERVER_RUN_SECONDS:-70}"
TAIL_SECONDS="${TAIL_SECONDS:-0}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
CLEAR_QLOG="${CLEAR_QLOG:-1}"
STOP_RUNNING="${STOP_RUNNING:-1}"

CLIENT_RESULTS_ROOT="${CLIENT_RESULTS_ROOT:-}"
BASE_URI="${BASE_URI:-https://84.17.61.47:8443}"
CA_CERT_FILE="${CA_CERT_FILE:-}"
H2LOAD_BIN="${H2LOAD_BIN:-h2load}"
THREADS="${THREADS:-4}"
DURATION="${DURATION:-45s}"
WARMUP="${WARMUP:-10s}"
INTER_RUN_SLEEP="${INTER_RUN_SLEEP:-0}"

SERVER_START_DELAY="${SERVER_START_DELAY:-3}"
BETWEEN_CASE_DELAY="${BETWEEN_CASE_DELAY:-0}"
STOP_ON_FAILURE="${STOP_ON_FAILURE:-1}"
ORCHESTRATOR_RESULTS_ROOT="${ORCHESTRATOR_RESULTS_ROOT:-$PWD/results/orchestrator}"

RUN_SET_DIR="$ORCHESTRATOR_RESULTS_ROOT/run_sets/$RUN_SET_ID"
MANIFEST_PATH="$RUN_SET_DIR/manifest.tsv"

bench_ensure_cmd bash ssh awk sed tee mktemp date

CASE_TABLE_FILE="$(mktemp)"
cleanup() {
    rm -f "$CASE_TABLE_FILE"
}
trap cleanup EXIT

case_table >"$CASE_TABLE_FILE"

COMMAND="${1:-}"

if [[ "$COMMAND" == "--list" ]]; then
    cat "$CASE_TABLE_FILE"
    exit 0
fi

[[ -n "$SERVER_SSH" ]] || bench_die "SERVER_SSH is required"
[[ -n "$CLIENT_SSH" ]] || bench_die "CLIENT_SSH is required"

if [[ "$CA_CERT_FILE" == /Users/* ]]; then
    bench_log "warning: CA_CERT_FILE looks like a local macOS path; the remote client needs its own path, e.g. /home/.../server.crt"
fi

if [[ "$CLIENT_RESULTS_ROOT" == /Users/* ]]; then
    bench_log "warning: CLIENT_RESULTS_ROOT looks like a local macOS path; the remote client will not be able to write there"
fi

manifest_init

case "$COMMAND" in
    run)
        shift
        [[ $# -ge 1 ]] || bench_die "run requires at least one case index"
        for case_index in "$@"; do
            [[ "$case_index" =~ ^[0-9]+$ ]] || bench_die "invalid case index: $case_index"
            run_case "$case_index"
        done
        ;;
    range)
        local_start="${2:-}"
        local_end="${3:-}"
        [[ "${local_start:-}" =~ ^[0-9]+$ ]] || bench_die "range start must be an integer"
        [[ "${local_end:-}" =~ ^[0-9]+$ ]] || bench_die "range end must be an integer"
        (( local_end >= local_start )) || bench_die "range end must be >= range start"
        for ((case_index = local_start; case_index <= local_end; case_index++)); do
            run_case "$case_index"
        done
        ;;
    all)
        while IFS=$'\t' read -r case_index _; do
            [[ "$case_index" == "idx" ]] && continue
            run_case "$((10#$case_index))"
        done <"$CASE_TABLE_FILE"
        ;;
    *)
        usage
        exit 1
        ;;
esac
