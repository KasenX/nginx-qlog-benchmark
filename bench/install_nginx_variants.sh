#!/usr/bin/env bash

set -euo pipefail


usage() {
    cat <<'EOF'
Build and install three NGINX variants from this repository:
  1. master
  2. feature/quic-qlog without --with-quic_qlog_module
  3. feature/quic-qlog with    --with-quic_qlog_module

Run this script from any working tree of the nginx-qlog repository on Debian.

Environment overrides:
  REMOTE=origin
  MASTER_REF=origin/master
  QLOG_REF=origin/feature/quic-qlog
  SRC_ROOT=$HOME/src/nginx-bench
  PREFIX_ROOT=$HOME/opt/nginx-bench
  JOBS=<nproc>
  CC_OPT='-O2 -fno-omit-frame-pointer'

Examples:
  bench/install_nginx_variants.sh
  PREFIX_ROOT=$HOME/nginx bench/install_nginx_variants.sh
EOF
}


log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}


die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}


run_as_root() {
    if [[ ${EUID} -eq 0 ]]; then
        "$@"
        return
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        die "sudo is required to install build dependencies"
    fi

    sudo "$@"
}


ensure_cmd() {
    local cmd

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            die "required command not found: $cmd"
        fi
    done
}


install_debian_dependencies() {
    log "Installing Debian build dependencies"
    run_as_root apt-get update
    run_as_root apt-get install -y \
        build-essential \
        ca-certificates \
        git \
        openssl \
        libpcre3-dev \
        libssl-dev \
        zlib1g-dev
}


ensure_worktree() {
    local path="$1"
    local ref="$2"

    if [[ -e "$path" && ! -e "$path/.git" ]]; then
        die "path exists but is not a git working tree: $path"
    fi

    if [[ ! -e "$path/.git" ]]; then
        log "Creating worktree $path at $ref"
        git -C "$REPO_ROOT" worktree add --detach "$path" "$ref"
        return
    fi

    git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "existing path is not a valid git worktree: $path"

    log "Updating worktree $path to $ref"
    git -C "$path" checkout --detach "$ref"
}


write_build_info() {
    local name="$1"
    local src="$2"
    local prefix="$3"

    {
        printf 'variant: %s\n' "$name"
        printf 'build_time_utc: %s\n' "$(date -u '+%FT%TZ')"
        printf 'source_dir: %s\n' "$src"
        printf 'install_prefix: %s\n' "$prefix"
        printf 'git_commit: %s\n' "$(git -C "$src" rev-parse HEAD)"
        printf 'git_subject: %s\n' "$(git -C "$src" show -s --format=%s HEAD)"
        printf 'kernel: %s\n' "$(uname -srmo)"
        printf 'openssl: %s\n' "$(openssl version 2>/dev/null || printf 'unavailable')"
        printf 'configure_and_build:\n'
        "$prefix/sbin/nginx" -V
    } >"$prefix/BUILD_INFO.txt" 2>&1
}


configure_and_install() {
    local name="$1"
    local src="$2"
    local prefix="$3"
    shift 3

    mkdir -p "$prefix/run"

    log "Configuring $name"
    (
        cd "$src"
        ./auto/configure \
            --prefix="$prefix" \
            --conf-path="$prefix/conf/nginx.conf" \
            --error-log-path="$prefix/logs/error.log" \
            --http-log-path="$prefix/logs/access.log" \
            --pid-path="$prefix/run/nginx.pid" \
            --lock-path="$prefix/run/nginx.lock" \
            --modules-path="$prefix/modules" \
            --with-http_ssl_module \
            --with-http_v3_module \
            --with-cc-opt="$CC_OPT" \
            "$@"
    )

    log "Building $name"
    make -C "$src" -j "$JOBS"

    log "Installing $name into $prefix"
    make -C "$src" install
    mkdir -p "$prefix/run"

    write_build_info "$name" "$src" "$prefix"
}


if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

ensure_cmd apt-get date git uname

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "run this script from inside a clone of the nginx-qlog repository"

REMOTE="${REMOTE:-origin}"
MASTER_REF="${MASTER_REF:-$REMOTE/master}"
QLOG_REF="${QLOG_REF:-$REMOTE/feature/quic-qlog}"
SRC_ROOT="${SRC_ROOT:-$HOME/src/nginx-bench}"
PREFIX_ROOT="${PREFIX_ROOT:-$HOME/opt/nginx-bench}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}"
CC_OPT="${CC_OPT:--O2 -fno-omit-frame-pointer}"

MASTER_SRC="$SRC_ROOT/master"
QLOG_NOMODULE_SRC="$SRC_ROOT/qlog-nomodule"
QLOG_SRC="$SRC_ROOT/qlog"

MASTER_PREFIX="$PREFIX_ROOT/master"
QLOG_NOMODULE_PREFIX="$PREFIX_ROOT/qlog-nomodule"
QLOG_PREFIX="$PREFIX_ROOT/qlog"

mkdir -p "$SRC_ROOT" "$PREFIX_ROOT"

install_debian_dependencies
ensure_cmd make openssl

log "Fetching refs from $REMOTE"
git -C "$REPO_ROOT" fetch --prune "$REMOTE"

git -C "$REPO_ROOT" rev-parse --verify "$MASTER_REF" >/dev/null \
    || die "cannot resolve ref: $MASTER_REF"
git -C "$REPO_ROOT" rev-parse --verify "$QLOG_REF" >/dev/null \
    || die "cannot resolve ref: $QLOG_REF"

ensure_worktree "$MASTER_SRC" "$MASTER_REF"
ensure_worktree "$QLOG_NOMODULE_SRC" "$QLOG_REF"
ensure_worktree "$QLOG_SRC" "$QLOG_REF"

configure_and_install "master" "$MASTER_SRC" "$MASTER_PREFIX"
configure_and_install "qlog-nomodule" "$QLOG_NOMODULE_SRC" "$QLOG_NOMODULE_PREFIX"
configure_and_install "qlog" "$QLOG_SRC" "$QLOG_PREFIX" --with-quic_qlog_module

log "Installed variants:"
printf '  %-15s %s\n' "master" "$MASTER_PREFIX/sbin/nginx"
printf '  %-15s %s\n' "qlog-nomodule" "$QLOG_NOMODULE_PREFIX/sbin/nginx"
printf '  %-15s %s\n' "qlog" "$QLOG_PREFIX/sbin/nginx"

log "Build metadata:"
printf '  %s\n' "$MASTER_PREFIX/BUILD_INFO.txt"
printf '  %s\n' "$QLOG_NOMODULE_PREFIX/BUILD_INFO.txt"
printf '  %s\n' "$QLOG_PREFIX/BUILD_INFO.txt"
