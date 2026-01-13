#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"
ROOTFS_SIZE="${ROOTFS_SIZE:-2G}"
USERDATA_SIZE="${USERDATA_SIZE:-128M}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_dependencies() {
    local missing=()

    if ! command -v docker &> /dev/null; then
        missing+=("docker")
    fi

    if ! command -v zig &> /dev/null; then
        missing+=("zig")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

build_zig_binaries() {
    log_info "Building Zig binaries for Linux ARM64..."

    log_info "Building vmd and sandbox-helper..."
    (cd "$SCRIPT_DIR/.." && zig build guest sandbox -Doptimize=ReleaseSafe)

    mkdir -p "$ARTIFACTS_DIR/bin"
    cp "$SCRIPT_DIR/../zig-out/bin/vmd-aarch64" "$ARTIFACTS_DIR/bin/vmd"
    cp "$SCRIPT_DIR/../zig-out/bin/sandbox-helper-aarch64" "$ARTIFACTS_DIR/bin/sandbox-helper"

    log_info "Zig binaries built successfully"
}

create_rootfs() {
    log_info "Creating rootfs.img ($ROOTFS_SIZE)..."

    "$SCRIPT_DIR/scripts/create-rootfs.sh" "$ARTIFACTS_DIR/rootfs.img" "$ROOTFS_SIZE"
}

create_userdata() {
    log_info "Creating userdata.img ($USERDATA_SIZE)..."

    "$SCRIPT_DIR/scripts/create-userdata.sh" "$ARTIFACTS_DIR/userdata.img" "$USERDATA_SIZE"
}

install_base_system() {
    log_info "Installing base system (Ubuntu ARM64)..."

    "$SCRIPT_DIR/scripts/install-base.sh" "$ARTIFACTS_DIR/rootfs.img"
}

main() {
    log_info "Starting VM image build..."

    check_dependencies
    mkdir -p "$ARTIFACTS_DIR"

    build_zig_binaries

    if [ ! -f "$ARTIFACTS_DIR/rootfs.img" ]; then
        create_rootfs
        install_base_system
    else
        log_warn "rootfs.img already exists, skipping creation"
        log_info "To rebuild, delete $ARTIFACTS_DIR/rootfs.img"
    fi

    if [ ! -f "$ARTIFACTS_DIR/userdata.img" ]; then
        create_userdata
    else
        log_warn "userdata.img already exists, skipping creation"
    fi

    log_info "Build complete!"
    log_info "  rootfs.img: $ARTIFACTS_DIR/rootfs.img"
    log_info "  userdata.img: $ARTIFACTS_DIR/userdata.img"
}

main "$@"
