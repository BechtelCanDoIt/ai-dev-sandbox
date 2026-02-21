#!/bin/bash
# =============================================================================
# AI-Dev-Sandbox — Build Script
# =============================================================================
# Builds two images end-to-end:
#
#   1. ai-dev-sandbox:latest       Inner Docker image (runs inside Firecracker guest VM)
#   2. ai-dev-sandbox-host:latest  Host Docker image  (extends firecracker-base,
#                                   Firecracker VMM with ai-dev-sandbox pre-baked into rootfs)
#
# What this does, step by step:
#   1. Build the inner image  (Dockerfile)
#   2. docker save it to .build/ai-dev-sandbox.tar
#   3. Extract base.ext4 from firecracker-base:latest
#   4. Run inject-ai-dev-sandbox.sh in a privileged container to:
#        - Resize base.ext4 → ai-dev-sandbox.ext4 (makes room for the image tar)
#        - Copy ai-dev-sandbox.tar into the rootfs
#        - Install load-ai-dev-sandbox.service (loads image into guest Docker on first boot)
#        - Patch sandbox .bash_profile to auto-launch ai-dev-sandbox on login
#   5. Build the host image (Dockerfile.host — embeds ai-dev-sandbox.ext4)
#
# Prerequisites:
#   - firecracker-base:latest already built  (cd ../firecracker-base && ./build.sh)
#   - Docker with BuildKit support
#   - Privilege to run a --privileged container (for the loop mount step)
#
# Usage (via ai):
#   ./ai build                  Full build
#   ./ai build clean          Remove .build/ then full build
#   ./ai build inner-only     Rebuild just the inner image
#   ./ai build host-only      Rebuild just the host image (needs .build/ai-dev-sandbox.ext4)
#   ./ai build inject-only    Redo only the rootfs injection step
# =============================================================================

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
INNER_IMAGE="${INNER_IMAGE:-ai-dev-sandbox:latest}"
HOST_IMAGE="${HOST_IMAGE:-ai-dev-sandbox-host:latest}"
FC_BASE_IMAGE="${FC_BASE_IMAGE:-firecracker-base:latest}"
# Path to base.ext4 inside the firecracker-base image
FC_BASE_ROOTFS_PATH="${FC_BASE_ROOTFS_PATH:-/var/lib/firecracker/rootfs/base.ext4}"
# Extra MB added to the rootfs to hold the ai-dev-sandbox image tar + Docker metadata
AI_SANDBOX_ROOTFS_EXTRA_MB="${AI_SANDBOX_ROOTFS_EXTRA_MB:-6144}"

# Paths — build.sh lives in scripts/, project root is one level up
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[build]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[build]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[build]${NC} $*"; }
log_error() { echo -e "${RED}[build]${NC} $*" >&2; }
log_step()  { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
              echo -e "${BLUE}  $*${NC}"; \
              echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ─── Step 1: Build inner image ────────────────────────────────────────────────
build_inner_image() {
    log_step "Step 1/5 — Building inner image: $INNER_IMAGE"
    docker build \
        --progress=plain \
        -f "$PROJECT_DIR/Dockerfile" \
        -t "$INNER_IMAGE" \
        "$PROJECT_DIR"
    log_ok "Inner image built: $INNER_IMAGE"
}

# ─── Step 2: Export inner image as tar ───────────────────────────────────────
export_inner_image() {
    log_step "Step 2/5 — Exporting $INNER_IMAGE to tar"
    mkdir -p "$BUILD_DIR"
    docker save "$INNER_IMAGE" -o "$BUILD_DIR/ai-dev-sandbox.tar"
    local size
    size=$(du -sh "$BUILD_DIR/ai-dev-sandbox.tar" | cut -f1)
    log_ok "Saved: $BUILD_DIR/ai-dev-sandbox.tar ($size)"
}

# ─── Step 3: Extract base.ext4 from firecracker-base ─────────────────────────
extract_base_rootfs() {
    log_step "Step 3/5 — Extracting base.ext4 from $FC_BASE_IMAGE"
    local tmp_container
    tmp_container=$(docker create "$FC_BASE_IMAGE" /bin/true 2>/dev/null)
    docker cp "${tmp_container}:${FC_BASE_ROOTFS_PATH}" "$BUILD_DIR/base.ext4"
    docker rm "$tmp_container" >/dev/null 2>&1
    local size
    size=$(du -sh "$BUILD_DIR/base.ext4" | cut -f1)
    log_ok "Extracted base.ext4 ($size)"
}

# ─── Step 4: Inject ai-dev-sandbox into rootfs ───────────────────────────────
inject_ai_sandbox() {
    log_step "Step 4/5 — Injecting ai-dev-sandbox into rootfs (privileged loop mount)"
    log_info "This resizes base.ext4 by +${AI_SANDBOX_ROOTFS_EXTRA_MB}MB and bakes the image in."

    docker run --rm \
        --privileged \
        -v "$BUILD_DIR:/build" \
        -v "$SCRIPTS_DIR/inject-ai-dev-sandbox.sh:/inject.sh:ro" \
        -e AI_SANDBOX_ROOTFS_EXTRA_MB="$AI_SANDBOX_ROOTFS_EXTRA_MB" \
        ubuntu:24.04 \
        bash -c "
            set -e
            apt-get update -qq
            apt-get install -y -qq e2fsprogs rsync >/dev/null 2>&1
            bash /inject.sh
        "

    local size
    size=$(du -sh "$BUILD_DIR/ai-dev-sandbox.ext4" | cut -f1)
    log_ok "Injection complete: $BUILD_DIR/ai-dev-sandbox.ext4 ($size)"
}

# ─── Step 5: Build host image ─────────────────────────────────────────────────
build_host_image() {
    log_step "Step 5/5 — Building host image: $HOST_IMAGE"
    docker build \
        --progress=plain \
        -f "$PROJECT_DIR/Dockerfile.host" \
        -t "$HOST_IMAGE" \
        "$PROJECT_DIR"
    log_ok "Host image built: $HOST_IMAGE"
}

# ─── Preflight checks ─────────────────────────────────────────────────────────
preflight() {
    # Check firecracker-base exists
    if ! docker image inspect "$FC_BASE_IMAGE" &>/dev/null 2>&1; then
        log_error "Base image not found: $FC_BASE_IMAGE"
        log_error ""
        log_error "Build firecracker-base first:"
        log_error "  cd ../firecracker-base && ./build.sh"
        exit 1
    fi
    log_ok "Base image found: $FC_BASE_IMAGE"
}

# ─── Help ─────────────────────────────────────────────────────────────────────
show_help() {
    cat << EOF
Build ai-dev-sandbox images

Usage: ./ai build [OPTIONS]

Options:
  help, -h, --help  Show this help
  clean             Remove .build/ directory then do a full build
  inner-only        Build only the inner image  (ai-dev-sandbox:latest)
  inject-only       Re-run only rootfs injection (needs .build/base.ext4 + .build/ai-dev-sandbox.tar)
  host-only         Build only the host image   (needs .build/ai-dev-sandbox.ext4)

Environment Variables:
  FC_BASE_IMAGE                 firecracker-base image (default: firecracker-base:latest)
  INNER_IMAGE                   Inner image name       (default: ai-dev-sandbox:latest)
  HOST_IMAGE                    Host image name        (default: ai-dev-sandbox-host:latest)
  AI_SANDBOX_ROOTFS_EXTRA_MB    Extra MB for rootfs    (default: 6144)

Build sequence:
  1. docker build (Dockerfile)              → ai-dev-sandbox:latest
  2. docker save                             → .build/ai-dev-sandbox.tar
  3. docker cp from firecracker-base         → .build/base.ext4
  4. inject-ai-dev-sandbox.sh (privileged)   → .build/ai-dev-sandbox.ext4
  5. docker build (Dockerfile.host)          → ai-dev-sandbox-host:latest

Examples:
  ./ai build                            # Full build
  ./ai build clean                    # Clean rebuild
  ./ai build inner-only               # Iterate on inner image only
  AI_SANDBOX_ROOTFS_EXTRA_MB=8192 ./ai build  # Larger rootfs
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    local do_inner=true
    local do_export=true
    local do_extract=true
    local do_inject=true
    local do_host=true

    while [[ $# -gt 0 ]]; do
        case $1 in
            help|-h|--help)      show_help; exit 0 ;;
            clean)        rm -rf "$BUILD_DIR"; shift ;;
            inner-only)   do_export=false; do_extract=false; do_inject=false; do_host=false; shift ;;
            inject-only)  do_inner=false; do_export=false; do_extract=false; do_host=false; shift ;;
            host-only)    do_inner=false; do_export=false; do_extract=false; do_inject=false; shift ;;
            *)              log_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  AI-Dev-Sandbox build                                          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    preflight
    mkdir -p "$BUILD_DIR"

    $do_inner   && build_inner_image
    $do_export  && export_inner_image
    $do_extract && extract_base_rootfs
    $do_inject  && inject_ai_sandbox
    $do_host    && build_host_image

    echo ""
    log_ok "Build complete!"
    echo ""
    echo "  Run:"
    echo "    ./ai"
    echo ""
}

main "$@"
