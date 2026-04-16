#!/usr/bin/env bash

set -euo pipefail


usage() {
    cat <<'EOF'
Generate minimal HTTP/3 benchmark configs for the nginx benchmark installs.

By default this script expects the three installs created by
bench/install_nginx_variants.sh under:
  $HOME/opt/nginx-bench/{master,qlog}

Run `sudo bench/prepare_benchmark_vm.sh` first if you want the standard
benchmark qlog paths:
  /mnt/qlog-ram
  /var/lib/nginx-qlog

It creates:
  - shared benchmark payloads
  - a self-signed certificate
  - one config for master
  - three configs for qlog: off, on-ram, on-disk

Environment overrides:
  PREFIX_ROOT=$HOME/opt/nginx-bench
  WWW_ROOT=$PREFIX_ROOT/www
  CERT_ROOT=$PREFIX_ROOT/certs
  LISTEN_PORT=8443
  SERVER_NAME=<hostname>
  CERT_HOST=<hostname used in SAN DNS entry>
  CERT_IP=<IPv4 used in SAN IP entry>
  QLOG_RAM_PATH=/mnt/qlog-ram
  QLOG_DISK_PATH=/var/lib/nginx-qlog

Examples:
  bench/generate_benchmark_configs.sh
  LISTEN_PORT=443 QLOG_RAM_PATH=/mnt/qlog-ram \
  QLOG_DISK_PATH=/var/lib/nginx-qlog \
    bench/generate_benchmark_configs.sh
EOF
}


log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}


die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}


ensure_cmd() {
    local cmd

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            die "required command not found: $cmd"
        fi
    done
}


ensure_dir() {
    local dir="$1"

    mkdir -p "$dir" || die "cannot create directory: $dir"
    [[ -w "$dir" ]] || die "directory is not writable: $dir"
}


write_payload() {
    local path="$1"
    local block_size="$2"
    local count="$3"

    if [[ -f "$path" ]]; then
        return
    fi

    dd if=/dev/zero of="$path" bs="$block_size" count="$count" status=none
}


write_payloads() {
    log "Creating shared benchmark payloads in $WWW_ROOT"
    ensure_dir "$WWW_ROOT"

    cat >"$WWW_ROOT/index.html" <<EOF
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>nginx-qlog benchmark</title>
</head>
<body>
  <h1>nginx-qlog benchmark</h1>
  <ul>
    <li><a href="/1k.bin">1k.bin</a></li>
    <li><a href="/16k.bin">16k.bin</a></li>
    <li><a href="/1m.bin">1m.bin</a></li>
    <li><a href="/10m.bin">10m.bin</a></li>
  </ul>
</body>
</html>
EOF

    printf 'ok\n' >"$WWW_ROOT/healthz.txt"
    write_payload "$WWW_ROOT/1k.bin" 1024 1
    write_payload "$WWW_ROOT/16k.bin" 1024 16
    write_payload "$WWW_ROOT/1m.bin" 1M 1
    write_payload "$WWW_ROOT/10m.bin" 1M 10
}


select_qlog_ram_path() {
    if [[ -d "$QLOG_RAM_PATH_REQUESTED" && -w "$QLOG_RAM_PATH_REQUESTED" ]]; then
        QLOG_RAM_PATH_SELECTED="$QLOG_RAM_PATH_REQUESTED"
        QLOG_RAM_NOTE="Using existing RAM qlog path: $QLOG_RAM_PATH_SELECTED"
        return
    fi

    QLOG_RAM_PATH_SELECTED="$PREFIX_ROOT/qlogs/ram-fallback"
    ensure_dir "$QLOG_RAM_PATH_SELECTED"
    QLOG_RAM_NOTE="Requested RAM qlog path unavailable, using fallback path: $QLOG_RAM_PATH_SELECTED"
}


ensure_certificate() {
    ensure_dir "$CERT_ROOT"

    CERT_PATH="$CERT_ROOT/server.crt"
    KEY_PATH="$CERT_ROOT/server.key"

    if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
        log "Reusing certificate in $CERT_ROOT"
        return
    fi

    log "Generating self-signed certificate in $CERT_ROOT"

    if [[ -n "$CERT_IP" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
            -keyout "$KEY_PATH" \
            -out "$CERT_PATH" \
            -subj "/CN=$CERT_HOST" \
            -addext "subjectAltName=DNS:$CERT_HOST,IP:$CERT_IP" >/dev/null 2>&1
    else
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
            -keyout "$KEY_PATH" \
            -out "$CERT_PATH" \
            -subj "/CN=$CERT_HOST" \
            -addext "subjectAltName=DNS:$CERT_HOST" >/dev/null 2>&1
    fi
}


write_config() {
    local prefix="$1"
    local config_name="$2"
    local qlog_directives="$3"
    local config_path="$prefix/conf/$config_name"
    local pid_name="${config_name%.conf}.pid"
    local error_name="${config_name%.conf}-error.log"

    cat >"$config_path" <<EOF
worker_processes auto;
worker_rlimit_nofile 200000;

pid $prefix/run/$pid_name;
error_log $prefix/logs/$error_name warn;

events {
    worker_connections 65535;
    multi_accept on;
}

http {
    default_type application/octet-stream;
    access_log off;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 300s;
    keepalive_requests 100000;
    server_tokens off;

    ssl_protocols TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_early_data off;

    server {
        listen ${LISTEN_PORT} ssl reuseport;
        listen ${LISTEN_PORT} quic reuseport;
        server_name ${SERVER_NAME};

        ssl_certificate $CERT_PATH;
        ssl_certificate_key $KEY_PATH;

        http3 on;
        quic_gso off;
${qlog_directives}
        add_header Alt-Svc 'h3=":${LISTEN_PORT}"; ma=86400' always;
        add_header X-Http3 \$http3 always;

        root $WWW_ROOT;

        location = /healthz {
            default_type text/plain;
            return 200 "ok\n";
        }

        location = / {
            try_files /index.html =404;
        }

        location / {
            try_files \$uri =404;
        }
    }
}
EOF
}


validate_config() {
    local nginx_bin="$1"
    local config_path="$2"

    "$nginx_bin" -t -c "$config_path" >/dev/null
}


write_summary() {
    SUMMARY_PATH="$PREFIX_ROOT/BENCHMARK_CONFIGS.txt"

    cat >"$SUMMARY_PATH" <<EOF
Benchmark payload root:
  $WWW_ROOT

Certificate:
  crt: $CERT_PATH
  key: $KEY_PATH
  host SAN: $CERT_HOST
  ip SAN: ${CERT_IP:-<none>}

Listen port:
  $LISTEN_PORT

Qlog paths:
  ram:  $QLOG_RAM_PATH_SELECTED
  disk: $QLOG_DISK_PATH
  note: $QLOG_RAM_NOTE

Config files:
  master:         $MASTER_PREFIX/conf/bench-h3.conf
  qlog-off:       $QLOG_PREFIX/conf/bench-h3-qlog-off.conf
  qlog-on-ram:    $QLOG_PREFIX/conf/bench-h3-qlog-on-ram.conf
  qlog-on-disk:   $QLOG_PREFIX/conf/bench-h3-qlog-on-disk.conf

Start commands:
  $MASTER_PREFIX/sbin/nginx -c $MASTER_PREFIX/conf/bench-h3.conf
  $QLOG_PREFIX/sbin/nginx -c $QLOG_PREFIX/conf/bench-h3-qlog-off.conf
  $QLOG_PREFIX/sbin/nginx -c $QLOG_PREFIX/conf/bench-h3-qlog-on-ram.conf
  $QLOG_PREFIX/sbin/nginx -c $QLOG_PREFIX/conf/bench-h3-qlog-on-disk.conf

Stop commands:
  $MASTER_PREFIX/sbin/nginx -c $MASTER_PREFIX/conf/bench-h3.conf -s quit
  $QLOG_PREFIX/sbin/nginx -c $QLOG_PREFIX/conf/bench-h3-qlog-off.conf -s quit
  $QLOG_PREFIX/sbin/nginx -c $QLOG_PREFIX/conf/bench-h3-qlog-on-ram.conf -s quit
  $QLOG_PREFIX/sbin/nginx -c $QLOG_PREFIX/conf/bench-h3-qlog-on-disk.conf -s quit

Smoke test example:
  curl -k --http3-only https://$CERT_HOST:$LISTEN_PORT/healthz
EOF
}


if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

ensure_cmd awk bash dd hostname openssl

PREFIX_ROOT="${PREFIX_ROOT:-$HOME/opt/nginx-bench}"
WWW_ROOT="${WWW_ROOT:-$PREFIX_ROOT/www}"
CERT_ROOT="${CERT_ROOT:-$PREFIX_ROOT/certs}"
LISTEN_PORT="${LISTEN_PORT:-8443}"
SERVER_NAME="${SERVER_NAME:-_}"
CERT_HOST="${CERT_HOST:-$(hostname -f 2>/dev/null || hostname)}"
CERT_IP="${CERT_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
QLOG_RAM_PATH_REQUESTED="${QLOG_RAM_PATH:-/mnt/qlog-ram}"
QLOG_DISK_PATH="${QLOG_DISK_PATH:-/var/lib/nginx-qlog}"

MASTER_PREFIX="$PREFIX_ROOT/master"
QLOG_PREFIX="$PREFIX_ROOT/qlog"

[[ -x "$MASTER_PREFIX/sbin/nginx" ]] || die "missing nginx binary: $MASTER_PREFIX/sbin/nginx"
[[ -x "$QLOG_PREFIX/sbin/nginx" ]] || die "missing nginx binary: $QLOG_PREFIX/sbin/nginx"

if [[ $LISTEN_PORT -lt 1024 && ${EUID} -ne 0 ]]; then
    die "LISTEN_PORT=$LISTEN_PORT requires root or CAP_NET_BIND_SERVICE; use an unprivileged port like 8443"
fi

ensure_dir "$QLOG_DISK_PATH"
select_qlog_ram_path
write_payloads
ensure_certificate

log "Writing benchmark configs"
write_config "$MASTER_PREFIX" "bench-h3.conf" ""
write_config "$QLOG_PREFIX" "bench-h3-qlog-off.conf" "        quic_qlog off;"
write_config "$QLOG_PREFIX" "bench-h3-qlog-on-ram.conf" "$(cat <<EOF
        quic_qlog on;
        quic_qlog_path $QLOG_RAM_PATH_SELECTED;
        quic_qlog_sample 1;
        quic_qlog_importance base;
        quic_qlog_max_size 0;
EOF
)"
write_config "$QLOG_PREFIX" "bench-h3-qlog-on-disk.conf" "$(cat <<EOF
        quic_qlog on;
        quic_qlog_path $QLOG_DISK_PATH;
        quic_qlog_sample 1;
        quic_qlog_importance base;
        quic_qlog_max_size 0;
EOF
)"

log "Validating configs with nginx -t"
validate_config "$MASTER_PREFIX/sbin/nginx" "$MASTER_PREFIX/conf/bench-h3.conf"
validate_config "$QLOG_PREFIX/sbin/nginx" "$QLOG_PREFIX/conf/bench-h3-qlog-off.conf"
validate_config "$QLOG_PREFIX/sbin/nginx" "$QLOG_PREFIX/conf/bench-h3-qlog-on-ram.conf"
validate_config "$QLOG_PREFIX/sbin/nginx" "$QLOG_PREFIX/conf/bench-h3-qlog-on-disk.conf"

write_summary

log "Generated configs summary: $SUMMARY_PATH"
printf '  %s\n' "$MASTER_PREFIX/conf/bench-h3.conf"
printf '  %s\n' "$QLOG_PREFIX/conf/bench-h3-qlog-off.conf"
printf '  %s\n' "$QLOG_PREFIX/conf/bench-h3-qlog-on-ram.conf"
printf '  %s\n' "$QLOG_PREFIX/conf/bench-h3-qlog-on-disk.conf"
