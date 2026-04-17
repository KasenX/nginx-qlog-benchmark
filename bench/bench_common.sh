#!/usr/bin/env bash


bench_log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}


bench_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}


bench_ensure_cmd() {
    local cmd

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            bench_die "required command not found: $cmd"
        fi
    done
}


bench_list_scenarios() {
    cat <<'EOF'
quic-qlog
quic-qlog-no-buffer
EOF
}


bench_parse_simple_directive() {
    local config_path="$1"
    local directive="$2"

    awk -v key="$directive" '
        $1 == key {
            value = $2
            sub(/;$/, "", value)
            print value
            exit
        }
    ' "$config_path"
}


bench_parse_listen_port() {
    local config_path="$1"

    awk '
        $1 == "listen" && $3 == "quic" {
            value = $2
            sub(/;$/, "", value)
            print value
            exit
        }
    ' "$config_path"
}


bench_load_scenario() {
    local prefix_root="$1"
    local scenario="$2"

    case "$scenario" in
        quic-qlog)
            BENCH_SCENARIO_PREFIX="$prefix_root/quic-qlog"
            BENCH_SCENARIO_CONFIG="$BENCH_SCENARIO_PREFIX/conf/bench-h3-quic-qlog-on-disk.conf"
            ;;
        quic-qlog-no-buffer)
            BENCH_SCENARIO_PREFIX="$prefix_root/quic-qlog-no-buffer"
            BENCH_SCENARIO_CONFIG="$BENCH_SCENARIO_PREFIX/conf/bench-h3-quic-qlog-no-buffer-on-disk.conf"
            ;;
        *)
            return 1
            ;;
    esac

    BENCH_SCENARIO_NAME="$scenario"
    BENCH_SCENARIO_BIN="$BENCH_SCENARIO_PREFIX/sbin/nginx"

    [[ -x "$BENCH_SCENARIO_BIN" ]] \
        || bench_die "missing nginx binary: $BENCH_SCENARIO_BIN"
    [[ -f "$BENCH_SCENARIO_CONFIG" ]] \
        || bench_die "missing nginx config: $BENCH_SCENARIO_CONFIG"

    BENCH_SCENARIO_PID_FILE="$(bench_parse_simple_directive "$BENCH_SCENARIO_CONFIG" "pid")"
    BENCH_SCENARIO_LISTEN_PORT="$(bench_parse_listen_port "$BENCH_SCENARIO_CONFIG")"
    BENCH_SCENARIO_QLOG_MODE="$(bench_parse_simple_directive "$BENCH_SCENARIO_CONFIG" "quic_qlog" || true)"
    BENCH_SCENARIO_QLOG_DIR="$(bench_parse_simple_directive "$BENCH_SCENARIO_CONFIG" "quic_qlog_path" || true)"

    if [[ "${BENCH_SCENARIO_QLOG_MODE:-}" != "on" ]]; then
        BENCH_SCENARIO_QLOG_DIR=""
    fi
}
