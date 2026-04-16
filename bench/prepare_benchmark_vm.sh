#!/usr/bin/env bash

set -euo pipefail


usage() {
    cat <<'EOF'
Prepare a Debian benchmark VM for nginx qlog experiments.

This script performs host-side setup that should be separate from nginx builds:
  - install benchmark helper packages
  - create the disk-backed qlog directory
  - create and mount a tmpfs qlog directory
  - raise file descriptor limits for benchmark processes

Default paths:
  QLOG_RAM_PATH=/mnt/qlog-ram
  QLOG_DISK_PATH=/var/lib/nginx-qlog
  RAM_SIZE=8G
  NOFILE_LIMIT=1048576

Environment overrides:
  QLOG_RAM_PATH=/mnt/qlog-ram
  QLOG_DISK_PATH=/var/lib/nginx-qlog
  RAM_SIZE=8G
  NOFILE_LIMIT=1048576
  INSTALL_PACKAGES=1
  CONFIGURE_LIMITS=1

Examples:
  sudo bench/prepare_benchmark_vm.sh
  sudo QLOG_RAM_PATH=/mnt/qlog-ram QLOG_DISK_PATH=/var/lib/nginx-qlog \
       bench/prepare_benchmark_vm.sh
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


install_packages() {
    log "Installing benchmark helper packages"
    apt-get update
    apt-get install -y \
        ethtool \
        fio \
        iperf3 \
        jq \
        numactl \
        sysstat
}


configure_limits() {
    log "Configuring nofile limits to $NOFILE_LIMIT"

    mkdir -p /etc/security/limits.d
    cat >/etc/security/limits.d/99-nginx-bench.conf <<EOF
* soft nofile $NOFILE_LIMIT
* hard nofile $NOFILE_LIMIT
root soft nofile $NOFILE_LIMIT
root hard nofile $NOFILE_LIMIT
EOF
}


prepare_disk_qlog_dir() {
    log "Preparing disk-backed qlog directory: $QLOG_DISK_PATH"
    mkdir -p "$QLOG_DISK_PATH"
    chown "$SUDO_USER_NAME":"$SUDO_GROUP_NAME" "$QLOG_DISK_PATH"
    chmod 0755 "$QLOG_DISK_PATH"
}


prepare_ram_qlog_dir() {
    log "Preparing RAM-backed qlog directory: $QLOG_RAM_PATH"
    mkdir -p "$QLOG_RAM_PATH"

    if mountpoint -q "$QLOG_RAM_PATH"; then
        log "$QLOG_RAM_PATH is already mounted"
    else
        mount -t tmpfs -o "size=$RAM_SIZE,noatime" tmpfs "$QLOG_RAM_PATH"
    fi

    chown "$SUDO_USER_NAME":"$SUDO_GROUP_NAME" "$QLOG_RAM_PATH"
    chmod 0755 "$QLOG_RAM_PATH"
}


print_summary() {
    cat <<EOF
Prepared benchmark VM paths:
  ram qlog path:  $QLOG_RAM_PATH
  disk qlog path: $QLOG_DISK_PATH

Important:
  /etc/security/limits.d was updated, but existing login shells keep their
  old soft/hard limits. Open a fresh SSH session before checking `ulimit -n`
  or launching nginx manually.

Verification:
  mountpoint $QLOG_RAM_PATH
  findmnt $QLOG_RAM_PATH
  ls -ld $QLOG_RAM_PATH $QLOG_DISK_PATH
  su - $SUDO_USER_NAME -c 'ulimit -n'

Next:
  QLOG_RAM_PATH=$QLOG_RAM_PATH QLOG_DISK_PATH=$QLOG_DISK_PATH \\
    bash bench/generate_benchmark_configs.sh
EOF
}


if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

[[ ${EUID} -eq 0 ]] || die "run this script with sudo or as root"

ensure_cmd apt-get chmod chown findmnt mkdir mount mountpoint

SUDO_USER_NAME="${SUDO_USER:-${USER:-root}}"
SUDO_GROUP_NAME="$(id -gn "$SUDO_USER_NAME" 2>/dev/null || printf '%s' "$SUDO_USER_NAME")"

QLOG_RAM_PATH="${QLOG_RAM_PATH:-/mnt/qlog-ram}"
QLOG_DISK_PATH="${QLOG_DISK_PATH:-/var/lib/nginx-qlog}"
RAM_SIZE="${RAM_SIZE:-8G}"
NOFILE_LIMIT="${NOFILE_LIMIT:-1048576}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
CONFIGURE_LIMITS="${CONFIGURE_LIMITS:-1}"

if [[ "$INSTALL_PACKAGES" == "1" ]]; then
    install_packages
fi

if [[ "$CONFIGURE_LIMITS" == "1" ]]; then
    configure_limits
fi

prepare_disk_qlog_dir
prepare_ram_qlog_dir
print_summary
