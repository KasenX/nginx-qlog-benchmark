#!/usr/bin/env bash


SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bench/bench_common.sh
source "$SCRIPT_DIR/bench_common.sh"


bench_case_split_csv() {
    local value="$1"

    value="${value//,/ }"
    printf '%s\n' $value
}


bench_case_count_csv() {
    local value="$1"
    local item
    local count=0

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        count=$((count + 1))
    done < <(bench_case_split_csv "$value")

    printf '%s\n' "$count"
}


bench_case_list_workloads() {
    cat <<'EOF'
small
bulk
EOF
}


bench_case_load_workload() {
    local workload="$1"

    case "$workload" in
        small)
            BENCH_WORKLOAD_NAME="small"
            BENCH_WORKLOAD_DESCRIPTION="Small object, connection-oriented"
            BENCH_WORKLOAD_REQUEST_PATHS="16k.bin"
            BENCH_WORKLOAD_CLIENTS="20,100,250"
            BENCH_WORKLOAD_STREAMS="1"
            ;;
        bulk)
            BENCH_WORKLOAD_NAME="bulk"
            BENCH_WORKLOAD_DESCRIPTION="Large object, throughput-oriented"
            BENCH_WORKLOAD_REQUEST_PATHS="1m.bin"
            BENCH_WORKLOAD_CLIENTS="20,100,250"
            BENCH_WORKLOAD_STREAMS="1"
            ;;
        *)
            bench_die "unknown workload: $workload"
            ;;
    esac
}


bench_case_duration_to_seconds() {
    local value="$1"

    case "$value" in
        *ms)
            bench_die "millisecond durations are not supported in case-matrix scripts: $value"
            ;;
        *s)
            printf '%s\n' "${value%s}"
            ;;
        *m)
            printf '%s\n' $(( ${value%m} * 60 ))
            ;;
        *h)
            printf '%s\n' $(( ${value%h} * 3600 ))
            ;;
        ''|*[!0-9])
            bench_die "unsupported duration format: $value"
            ;;
        *)
            printf '%s\n' "$value"
            ;;
    esac
}


bench_case_count() {
    local request_paths="$1"
    local clients="$2"
    local streams="$3"
    local repeats="$4"
    local path_count
    local client_count
    local stream_count

    path_count="$(bench_case_count_csv "$request_paths")"
    client_count="$(bench_case_count_csv "$clients")"
    stream_count="$(bench_case_count_csv "$streams")"

    printf '%s\n' $(( path_count * client_count * stream_count * repeats ))
}


bench_case_estimated_single_case_seconds() {
    local duration="$1"
    local warmup="$2"
    local inter_run_sleep="${3:-0}"
    local duration_seconds
    local warmup_seconds
    local sleep_seconds

    duration_seconds="$(bench_case_duration_to_seconds "$duration")"
    warmup_seconds="$(bench_case_duration_to_seconds "$warmup")"
    sleep_seconds="$(bench_case_duration_to_seconds "$inter_run_sleep")"

    printf '%s\n' $(( duration_seconds + warmup_seconds + sleep_seconds ))
}


bench_case_slugify() {
    printf '%s' "$1" | sed 's#[/ ]#-#g; s#[^A-Za-z0-9._-]#_#g'
}


bench_case_run_id() {
    local run_set_id="$1"
    local workload="$2"
    local scenario="$3"
    local request_path="$4"
    local clients="$5"
    local streams="$6"
    local repeat="$7"

    printf '%s-%s-%s-%s-c%s-m%s-r%02d\n' \
        "$run_set_id" \
        "$workload" \
        "$scenario" \
        "$(bench_case_slugify "$request_path")" \
        "$clients" \
        "$streams" \
        "$repeat"
}
