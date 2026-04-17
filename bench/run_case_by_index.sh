#!/usr/bin/env bash

set -euo pipefail


SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bench/case_matrix_common.sh
source "$SCRIPT_DIR/case_matrix_common.sh"


usage() {
    cat <<'EOF'
Run one benchmark case selected by a numeric case index.

This is intended for manual one-case-at-a-time benchmarking from two terminals
or two VMs. Use the same CASE index and RUN_SET_ID on both sides.

Usage:
  bench/run_case_by_index.sh --list
  bench/run_case_by_index.sh server <case-index>
  bench/run_case_by_index.sh client <case-index>

Environment overrides:
  RUN_SET_ID=2026-03-19-manual
  SCENARIOS=quic-qlog,quic-qlog-no-buffer
  WORKLOADS=small,bulk
  REPEATS=3

Server-side:
  PREFIX_ROOT=$HOME/opt/nginx-bench
  SERVER_RESULTS_ROOT=$PREFIX_ROOT/results/server
  SERVER_RUN_SECONDS=70
  TAIL_SECONDS=0
  SAMPLE_INTERVAL=1
  CLEAR_QLOG=1
  STOP_RUNNING=1

Client-side:
  CLIENT_RESULTS_ROOT=$HOME/bench-results/client
  BASE_URI=https://84.17.61.47:8443
  CA_CERT_FILE=$HOME/bench-certs/server.crt
  THREADS=4
  DURATION=45s
  WARMUP=10s
  INTER_RUN_SLEEP=0

Examples:
  bench/run_case_by_index.sh --list | sed -n '1,12p'
  RUN_SET_ID=thesis-main bench/run_case_by_index.sh server 17
  RUN_SET_ID=thesis-main BASE_URI=https://84.17.61.47:8443 \
    CA_CERT_FILE=$HOME/bench-certs/server.crt \
    bench/run_case_by_index.sh client 17
EOF
}


print_case_line() {
    local case_index="$1"
    local run_id="$2"
    local scenario="$3"
    local workload="$4"
    local request_path="$5"
    local client_count="$6"
    local stream_count="$7"
    local repeat_index="$8"

    printf '%03d\t%s\t%s\t%s\t%s\t%s\t%s\tr%02d\n' \
        "$case_index" \
        "$run_id" \
        "$scenario" \
        "$workload" \
        "$request_path" \
        "$client_count" \
        "$stream_count" \
        "$repeat_index"
}


selected_case() {
    SELECTED_CASE_INDEX="$1"
    CURRENT_CASE_INDEX=0
    SELECTED_RUN_ID=""
    SELECTED_SCENARIO=""
    SELECTED_WORKLOAD=""
    SELECTED_REQUEST_PATH=""
    SELECTED_CLIENTS=""
    SELECTED_STREAMS=""
    SELECTED_REPEAT=""

    while IFS= read -r workload; do
        [[ -n "$workload" ]] || continue
        bench_case_load_workload "$workload"

        while IFS= read -r request_path; do
            [[ -n "$request_path" ]] || continue
            while IFS= read -r client_count; do
                [[ -n "$client_count" ]] || continue
                while IFS= read -r stream_count; do
                    [[ -n "$stream_count" ]] || continue
                    for ((repeat_index = 1; repeat_index <= REPEATS; repeat_index++)); do
                        while IFS= read -r scenario; do
                            [[ -n "$scenario" ]] || continue
                            CURRENT_CASE_INDEX=$((CURRENT_CASE_INDEX + 1))

                            run_id="$(
                                bench_case_run_id \
                                    "$RUN_SET_ID" \
                                    "$workload" \
                                    "$scenario" \
                                    "$request_path" \
                                    "$client_count" \
                                    "$stream_count" \
                                    "$repeat_index"
                            )"

                            if (( CURRENT_CASE_INDEX == SELECTED_CASE_INDEX )); then
                                SELECTED_RUN_ID="$run_id"
                                SELECTED_SCENARIO="$scenario"
                                SELECTED_WORKLOAD="$workload"
                                SELECTED_REQUEST_PATH="$request_path"
                                SELECTED_CLIENTS="$client_count"
                                SELECTED_STREAMS="$stream_count"
                                SELECTED_REPEAT="$repeat_index"
                                return 0
                            fi
                        done < <(bench_case_split_csv "$SCENARIOS")
                    done
                done < <(bench_case_split_csv "$BENCH_WORKLOAD_STREAMS")
            done < <(bench_case_split_csv "$BENCH_WORKLOAD_CLIENTS")
        done < <(bench_case_split_csv "$BENCH_WORKLOAD_REQUEST_PATHS")
    done < <(bench_case_split_csv "$WORKLOADS")

    return 1
}


list_cases() {
    local case_index=0

    printf 'idx\trun_id\tscenario\tworkload\tpath\tclients\tstreams\trepeat\n'

    while IFS= read -r workload; do
        [[ -n "$workload" ]] || continue
        bench_case_load_workload "$workload"

        while IFS= read -r request_path; do
            [[ -n "$request_path" ]] || continue
            while IFS= read -r client_count; do
                [[ -n "$client_count" ]] || continue
                while IFS= read -r stream_count; do
                    [[ -n "$stream_count" ]] || continue
                    for ((repeat_index = 1; repeat_index <= REPEATS; repeat_index++)); do
                        while IFS= read -r scenario; do
                            [[ -n "$scenario" ]] || continue
                            case_index=$((case_index + 1))
                            run_id="$(
                                bench_case_run_id \
                                    "$RUN_SET_ID" \
                                    "$workload" \
                                    "$scenario" \
                                    "$request_path" \
                                    "$client_count" \
                                    "$stream_count" \
                                    "$repeat_index"
                            )"
                            print_case_line \
                                "$case_index" \
                                "$run_id" \
                                "$scenario" \
                                "$workload" \
                                "$request_path" \
                                "$client_count" \
                                "$stream_count" \
                                "$repeat_index"
                        done < <(bench_case_split_csv "$SCENARIOS")
                    done
                done < <(bench_case_split_csv "$BENCH_WORKLOAD_STREAMS")
            done < <(bench_case_split_csv "$BENCH_WORKLOAD_CLIENTS")
        done < <(bench_case_split_csv "$BENCH_WORKLOAD_REQUEST_PATHS")
    done < <(bench_case_split_csv "$WORKLOADS")
}


run_server_case() {
    PREFIX_ROOT="$PREFIX_ROOT" \
    RESULTS_ROOT="$SERVER_RESULTS_ROOT" \
    RUN_ID="$SELECTED_RUN_ID" \
    RUN_SECONDS="$SERVER_RUN_SECONDS" \
    TAIL_SECONDS="$TAIL_SECONDS" \
    SAMPLE_INTERVAL="$SAMPLE_INTERVAL" \
    CLEAR_QLOG="$CLEAR_QLOG" \
    STOP_RUNNING="$STOP_RUNNING" \
    bash "$SCRIPT_DIR/run_server_measurement.sh" "$SELECTED_SCENARIO"
}


run_client_case() {
    RUN_ID="$SELECTED_RUN_ID" \
    REQUEST_PATHS="$SELECTED_REQUEST_PATH" \
    CLIENTS="$SELECTED_CLIENTS" \
    STREAMS="$SELECTED_STREAMS" \
    REPEATS=1 \
    DURATION="$DURATION" \
    WARMUP="$WARMUP" \
    INTER_RUN_SLEEP="$INTER_RUN_SLEEP" \
    THREADS="$THREADS" \
    RESULTS_ROOT="$CLIENT_RESULTS_ROOT" \
    BASE_URI="$BASE_URI" \
    CA_CERT_FILE="$CA_CERT_FILE" \
    bash "$SCRIPT_DIR/run_h2load_matrix.sh" "$SELECTED_SCENARIO"
}


if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

RUN_SET_ID="${RUN_SET_ID:-$(date -u '+%Y-%m-%d-manual')}"
SCENARIOS="${SCENARIOS:-quic-qlog,quic-qlog-no-buffer}"
WORKLOADS="${WORKLOADS:-small,bulk}"
REPEATS="${REPEATS:-3}"

PREFIX_ROOT="${PREFIX_ROOT:-$HOME/opt/nginx-bench}"
SERVER_RESULTS_ROOT="${SERVER_RESULTS_ROOT:-$PREFIX_ROOT/results/server}"
CLIENT_RESULTS_ROOT="${CLIENT_RESULTS_ROOT:-$HOME/bench-results/client}"
SERVER_RUN_SECONDS="${SERVER_RUN_SECONDS:-70}"
TAIL_SECONDS="${TAIL_SECONDS:-0}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
CLEAR_QLOG="${CLEAR_QLOG:-1}"
STOP_RUNNING="${STOP_RUNNING:-1}"

BASE_URI="${BASE_URI:-https://84.17.61.47:8443}"
CA_CERT_FILE="${CA_CERT_FILE:-$HOME/bench-certs/server.crt}"
THREADS="${THREADS:-4}"
DURATION="${DURATION:-45s}"
WARMUP="${WARMUP:-10s}"
INTER_RUN_SLEEP="${INTER_RUN_SLEEP:-0}"

bench_ensure_cmd bash sed

if [[ ${1:-} == "--list" ]]; then
    list_cases
    exit 0
fi

ROLE="${1:-}"
CASE_INDEX="${2:-}"

[[ "$ROLE" == "server" || "$ROLE" == "client" ]] || {
    usage
    exit 1
}

[[ "$CASE_INDEX" =~ ^[0-9]+$ ]] || bench_die "case index must be a positive integer"

selected_case "$CASE_INDEX" || bench_die "unknown case index: $CASE_INDEX"

bench_log \
    "Selected case $(printf '%03d' "$CASE_INDEX"): $SELECTED_SCENARIO / $SELECTED_WORKLOAD / $SELECTED_REQUEST_PATH / c$SELECTED_CLIENTS / m$SELECTED_STREAMS / r$(printf '%02d' "$SELECTED_REPEAT")"
bench_log "run_id=$SELECTED_RUN_ID"

if [[ "$ROLE" == "server" ]]; then
    run_server_case
else
    run_client_case
fi
