#!/usr/bin/env bash

set -euo pipefail


SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=bench/bench_common.sh
source "$SCRIPT_DIR/bench_common.sh"


usage() {
    cat <<EOF
Run an h2load matrix from the client side and save raw outputs.

Usage:
  $(basename "$0") <scenario-label>

Examples:
  BASE_URI=https://84.17.61.47:8443 TLS_INSECURE=1 \\
    RUN_ID=pilot-001 bench/run_h2load_matrix.sh quic-qlog

  BASE_URI=https://streaming-dev-jj-01-84-17-61-47.cdn77.eu:8443 \\
  CONNECT_TO=84.17.61.47:8443 SNI=streaming-dev-jj-01-84-17-61-47.cdn77.eu \\
  RUN_ID=pilot-002 bench/run_h2load_matrix.sh quic-qlog-no-buffer

Environment overrides:
  H2LOAD_BIN=h2load
  BASE_URI=https://127.0.0.1:8443
  RESULTS_ROOT=\$HOME/bench-results/client
  RUN_ID=<shared run identifier>
  REQUEST_PATHS=16k.bin,1m.bin
  CLIENTS=20,100,250
  STREAMS=1
  THREADS=4
  REPEATS=3
  DURATION=60s
  WARMUP=10s
  INTER_RUN_SLEEP=5
  ALPN_LIST=h3
  DISABLE_UDP_GSO=1
  TLS_INSECURE=0
  CA_CERT_FILE=/path/to/server.crt
  CA_CERT_DIR=/path/to/hashed-ca-dir
  SNI=<dnsname>
  CONNECT_TO=<host:port>
  ENABLE_CLIENT_QLOG=0
  H2LOAD_EXTRA_ARGS="<extra args>"

Notes:
  - The scenario label is used only for naming results directories.
  - This script assumes the matching server scenario is already running.
  - BASE_URI should match the server certificate name unless you intentionally
    use CONNECT_TO/SNI and provide a trusted CA file or directory.
EOF
}


supports_flag() {
    local flag="$1"

    [[ "$H2LOAD_HELP" == *"$flag"* ]]
}


slugify() {
    printf '%s' "$1" | sed 's#[/ ]#-#g; s#[^A-Za-z0-9._-]#_#g'
}


split_csv() {
    local value="$1"

    value="${value//,/ }"
    printf '%s\n' $value
}


join_command() {
    local arg

    for arg in "$@"; do
        printf '%q ' "$arg"
    done
    printf '\n'
}


extract_request_counts() {
    local summary_file="$1"

    awk '
        $1 == "requests:" {
            gsub(/,/, "", $0)
            printf "request_total=%s\n", $2
            printf "request_started=%s\n", $4
            printf "request_done=%s\n", $6
            printf "request_succeeded=%s\n", $8
            printf "request_failed=%s\n", $10
            printf "request_errored=%s\n", $12
            printf "request_timeout=%s\n", $14
            found = 1
            exit
        }

        END {
            if (!found) {
                exit 1
            }
        }
    ' "$summary_file"
}


append_optional_args() {
    EXTRA_ARGS=()

    if [[ "$DISABLE_UDP_GSO" == "1" ]]; then
        if supports_flag "--no-udp-gso"; then
            EXTRA_ARGS+=("--no-udp-gso")
        else
            bench_log "warning: h2load does not support --no-udp-gso; skipping it"
        fi
    fi

    if [[ "$TLS_INSECURE" == "1" ]]; then
        if supports_flag "--no-verify-peer"; then
            EXTRA_ARGS+=("--no-verify-peer")
        else
            bench_die "TLS_INSECURE=1 requested, but h2load has no --no-verify-peer support; use CA_CERT_FILE/CA_CERT_DIR or a newer h2load build"
        fi
    fi

    if [[ -n "$SNI" ]]; then
        if supports_flag "--sni"; then
            EXTRA_ARGS+=("--sni=$SNI")
        else
            bench_die "SNI was set, but h2load has no --sni support"
        fi
    fi

    if [[ -n "$CONNECT_TO" ]]; then
        if supports_flag "--connect-to"; then
            EXTRA_ARGS+=("--connect-to=$CONNECT_TO")
        else
            bench_die "CONNECT_TO was set, but h2load has no --connect-to support"
        fi
    fi

    if [[ -n "$H2LOAD_EXTRA_ARGS" ]]; then
        read -r -a USER_EXTRA_ARGS <<<"$H2LOAD_EXTRA_ARGS"
        EXTRA_ARGS+=("${USER_EXTRA_ARGS[@]}")
    fi
}


write_metadata() {
    {
        printf 'scenario=%s\n' "$SCENARIO_LABEL"
        printf 'run_id=%s\n' "$RUN_ID"
        printf 'base_uri=%s\n' "$BASE_URI"
        printf 'request_paths=%s\n' "$REQUEST_PATHS"
        printf 'clients=%s\n' "$CLIENTS"
        printf 'streams=%s\n' "$STREAMS"
        printf 'threads=%s\n' "$THREADS"
        printf 'repeats=%s\n' "$REPEATS"
        printf 'duration=%s\n' "$DURATION"
        printf 'warmup=%s\n' "$WARMUP"
        printf 'inter_run_sleep=%s\n' "$INTER_RUN_SLEEP"
        printf 'alpn_list=%s\n' "$ALPN_LIST"
        printf 'disable_udp_gso=%s\n' "$DISABLE_UDP_GSO"
        printf 'tls_insecure=%s\n' "$TLS_INSECURE"
        printf 'ca_cert_file=%s\n' "${CA_CERT_FILE:-}"
        printf 'ca_cert_dir=%s\n' "${CA_CERT_DIR:-}"
        printf 'sni=%s\n' "${SNI:-}"
        printf 'connect_to=%s\n' "${CONNECT_TO:-}"
        printf 'enable_client_qlog=%s\n' "$ENABLE_CLIENT_QLOG"
        printf 'host=%s\n' "$HOST_FQDN"
        printf 'start_utc=%s\n' "$START_UTC"
    } >"$RUN_DIR/run.env"

    "$H2LOAD_BIN" --version >"$RUN_DIR/h2load-version.txt" 2>&1
    printf '%s\n' "$H2LOAD_HELP" >"$RUN_DIR/h2load-help.txt"

    printf 'scenario\trepeat\tpath\tclients\tstreams\tthreads\tduration\twarmup\tresult_dir\tstatus\n' \
        >"$RUN_DIR/matrix.tsv"
}


run_case() {
    local repeat="$1"
    local request_path="$2"
    local clients="$3"
    local streams="$4"
    local uri
    local path_slug
    local case_name
    local case_dir
    local request_log
    local summary_file
    local command_file
    local client_qlog_base=""
    local status="failed"
    local request_total=0
    local request_started=0
    local request_done=0
    local request_succeeded=0
    local request_failed=0
    local request_errored=0
    local request_timeout=0
    local -a env_prefix=()
    local -a cmd

    uri="${BASE_URI%/}/${request_path#/}"
    path_slug="$(slugify "$request_path")"
    case_name="${path_slug}__c${clients}__m${streams}__r$(printf '%02d' "$repeat")"
    case_dir="$RUN_DIR/$case_name"
    request_log="$case_dir/requests.tsv"
    summary_file="$case_dir/h2load.txt"
    command_file="$case_dir/command.txt"

    mkdir -p "$case_dir"

    cmd=(
        "$H2LOAD_BIN"
        "-t" "$THREADS"
        "-c" "$clients"
        "-m" "$streams"
        "-D" "$DURATION"
        "--warm-up-time=$WARMUP"
        "--alpn-list=$ALPN_LIST"
        "--log-file=$request_log"
    )

    if [[ "$ENABLE_CLIENT_QLOG" == "1" ]]; then
        if supports_flag "--qlog-file-base"; then
            client_qlog_base="$case_dir/client-qlog"
            cmd+=("--qlog-file-base=$client_qlog_base")
        else
            bench_die "ENABLE_CLIENT_QLOG=1 requested, but h2load has no --qlog-file-base support"
        fi
    fi

    cmd+=("${EXTRA_ARGS[@]}")
    cmd+=("$uri")

    if [[ -n "$CA_CERT_FILE" ]]; then
        env_prefix+=("SSL_CERT_FILE=$CA_CERT_FILE")
    fi

    if [[ -n "$CA_CERT_DIR" ]]; then
        env_prefix+=("SSL_CERT_DIR=$CA_CERT_DIR")
    fi

    join_command env "${env_prefix[@]}" "${cmd[@]}" >"$command_file"
    bench_log "Running $case_name"

    if env "${env_prefix[@]}" "${cmd[@]}" >"$summary_file" 2>&1; then
        if eval "$(extract_request_counts "$summary_file")"; then
            if (( request_started > 0 && request_done > 0 && request_succeeded > 0 )); then
                status="ok"
            else
                status="no-requests"
            fi
        else
            status="unparseable"
        fi
    else
        status="failed"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$SCENARIO_LABEL" "$repeat" "$request_path" "$clients" "$streams" \
        "$THREADS" "$DURATION" "$WARMUP" "$case_dir" "$status" >>"$RUN_DIR/matrix.tsv"

    printf '%s\n' "$status" >"$case_dir/status.txt"

    {
        printf 'status=%s\n' "$status"
        printf 'request_total=%s\n' "$request_total"
        printf 'request_started=%s\n' "$request_started"
        printf 'request_done=%s\n' "$request_done"
        printf 'request_succeeded=%s\n' "$request_succeeded"
        printf 'request_failed=%s\n' "$request_failed"
        printf 'request_errored=%s\n' "$request_errored"
        printf 'request_timeout=%s\n' "$request_timeout"
    } >"$case_dir/requests.env"

    if [[ "$status" != "ok" ]]; then
        bench_die "h2load failed for $case_name; see $summary_file"
    fi
}


run_matrix() {
    local repeat
    local request_path
    local clients
    local streams

    while IFS= read -r request_path; do
        while IFS= read -r clients; do
            while IFS= read -r streams; do
                for ((repeat = 1; repeat <= REPEATS; repeat++)); do
                    run_case "$repeat" "$request_path" "$clients" "$streams"
                    sleep "$INTER_RUN_SLEEP"
                done
            done < <(split_csv "$STREAMS")
        done < <(split_csv "$CLIENTS")
    done < <(split_csv "$REQUEST_PATHS")
}


if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

SCENARIO_LABEL="${1:-}"
[[ -n "$SCENARIO_LABEL" ]] || {
    usage
    exit 1
}

H2LOAD_BIN="${H2LOAD_BIN:-h2load}"
BASE_URI="${BASE_URI:-https://127.0.0.1:8443}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/bench-results/client}"
RUN_ID="${RUN_ID:-$(date -u '+%Y%m%dT%H%M%SZ')}"
REQUEST_PATHS="${REQUEST_PATHS:-16k.bin,1m.bin}"
CLIENTS="${CLIENTS:-20,100,250}"
STREAMS="${STREAMS:-1}"
THREADS="${THREADS:-4}"
REPEATS="${REPEATS:-3}"
DURATION="${DURATION:-60s}"
WARMUP="${WARMUP:-10s}"
INTER_RUN_SLEEP="${INTER_RUN_SLEEP:-5}"
ALPN_LIST="${ALPN_LIST:-h3}"
DISABLE_UDP_GSO="${DISABLE_UDP_GSO:-1}"
TLS_INSECURE="${TLS_INSECURE:-0}"
CA_CERT_FILE="${CA_CERT_FILE:-}"
CA_CERT_DIR="${CA_CERT_DIR:-}"
SNI="${SNI:-}"
CONNECT_TO="${CONNECT_TO:-}"
ENABLE_CLIENT_QLOG="${ENABLE_CLIENT_QLOG:-0}"
H2LOAD_EXTRA_ARGS="${H2LOAD_EXTRA_ARGS:-}"

bench_ensure_cmd "$H2LOAD_BIN" awk date hostname sed

H2LOAD_HELP="$("$H2LOAD_BIN" --help 2>&1 || true)"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
RUN_DIR="$RESULTS_ROOT/$RUN_ID/$SCENARIO_LABEL"
START_UTC="$(date -u '+%FT%TZ')"

mkdir -p "$RUN_DIR"

append_optional_args
write_metadata
run_matrix

bench_log "Client matrix completed"
bench_log "Results saved in $RUN_DIR"
