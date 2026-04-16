#!/usr/bin/env bash

set -euo pipefail


SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bench/case_matrix_common.sh
source "$SCRIPT_DIR/case_matrix_common.sh"


usage() {
    cat <<'EOF'
Print the exact per-case server/client commands for the full benchmark matrix.

This helper is intended for manually driven one-case-at-a-time benchmarking,
where the server and client are started separately for each case.

Usage:
  bench/print_manual_case_commands.sh

Environment overrides:
  RUN_SET_ID=2026-03-19-manual
  SCENARIOS=master,qlog-off,quic-qlog,quic-qlog-extended,http3-qlog,qlog-on-disk
  WORKLOADS=small,bulk
  REPEATS=7

  SERVER_REPO_DIR=$HOME/nginx-qlog-benchmark
  SERVER_RUN_SECONDS=70
  SAMPLE_INTERVAL=1
  CLEAR_QLOG=1
  STOP_RUNNING=1

  CLIENT_REPO_DIR=$HOME/nginx-qlog-benchmark
  BASE_URI=https://84.17.61.47:8443
  CA_CERT_FILE=$HOME/bench-certs/server.crt
  THREADS=4
  DURATION=45s
  WARMUP=10s
  INTER_RUN_SLEEP=0

Examples:
  bench/print_manual_case_commands.sh
  RUN_SET_ID=thesis-main BASE_URI=https://84.17.61.47:8443 \
    bench/print_manual_case_commands.sh > manual-cases.txt
EOF
}


print_case() {
    local run_id="$1"
    local scenario="$2"
    local workload="$3"
    local request_path="$4"
    local client_count="$5"
    local stream_count="$6"
    local repeat_index="$7"
    local case_index="$8"

    cat <<EOF
# Case $(printf '%03d' "$case_index"): $scenario / $workload / $request_path / c$client_count / m$stream_count / r$(printf '%02d' "$repeat_index")
RUN_ID=$run_id

# Server VM
cd $SERVER_REPO_DIR && \\
RUN_ID='$run_id' \\
RUN_SECONDS=$SERVER_RUN_SECONDS \\
TAIL_SECONDS=0 \\
SAMPLE_INTERVAL=$SAMPLE_INTERVAL \\
CLEAR_QLOG=$CLEAR_QLOG \\
STOP_RUNNING=$STOP_RUNNING \\
bash bench/run_server_measurement.sh $scenario

# Client VM
cd $CLIENT_REPO_DIR && \\
RUN_ID='$run_id' \\
REQUEST_PATHS='$request_path' \\
CLIENTS='$client_count' \\
STREAMS='$stream_count' \\
REPEATS=1 \\
DURATION=$DURATION \\
WARMUP=$WARMUP \\
INTER_RUN_SLEEP=$INTER_RUN_SLEEP \\
THREADS=$THREADS \\
BASE_URI='$BASE_URI' \\
CA_CERT_FILE='$CA_CERT_FILE' \\
bash bench/run_h2load_matrix.sh $scenario

EOF
}


if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

RUN_SET_ID="${RUN_SET_ID:-$(date -u '+%Y-%m-%d-manual')}"
SCENARIOS="${SCENARIOS:-master,qlog-off,quic-qlog,quic-qlog-extended,http3-qlog,qlog-on-disk}"
WORKLOADS="${WORKLOADS:-small,bulk}"
REPEATS="${REPEATS:-7}"

SERVER_REPO_DIR="${SERVER_REPO_DIR:-$HOME/nginx-qlog-benchmark}"
SERVER_RUN_SECONDS="${SERVER_RUN_SECONDS:-70}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
CLEAR_QLOG="${CLEAR_QLOG:-1}"
STOP_RUNNING="${STOP_RUNNING:-1}"

CLIENT_REPO_DIR="${CLIENT_REPO_DIR:-$HOME/nginx-qlog-benchmark}"
BASE_URI="${BASE_URI:-https://84.17.61.47:8443}"
CA_CERT_FILE="${CA_CERT_FILE:-$HOME/bench-certs/server.crt}"
THREADS="${THREADS:-4}"
DURATION="${DURATION:-45s}"
WARMUP="${WARMUP:-10s}"
INTER_RUN_SLEEP="${INTER_RUN_SLEEP:-0}"

bench_ensure_cmd bash date sed

case_index=0

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
                        print_case \
                            "$run_id" \
                            "$scenario" \
                            "$workload" \
                            "$request_path" \
                            "$client_count" \
                            "$stream_count" \
                            "$repeat_index" \
                            "$case_index"
                    done < <(bench_case_split_csv "$SCENARIOS")
                done
            done < <(bench_case_split_csv "$BENCH_WORKLOAD_STREAMS")
        done < <(bench_case_split_csv "$BENCH_WORKLOAD_CLIENTS")
    done < <(bench_case_split_csv "$BENCH_WORKLOAD_REQUEST_PATHS")
done < <(bench_case_split_csv "$WORKLOADS")
