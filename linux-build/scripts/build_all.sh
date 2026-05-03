#!/bin/bash
#
# build_all.sh
#
# Master build script that runs all stages in order to produce a complete
# bootable Arch Linux USB image for Xbox 360.
#
# Usage: ./build_all.sh [--skip-toolchain] [--skip-kernel] [--skip-rootfs]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKIP_TOOLCHAIN=0
SKIP_KERNEL=0
SKIP_ROOTFS=0
SKIP_USB=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-toolchain) SKIP_TOOLCHAIN=1; shift ;;
        --skip-kernel)    SKIP_KERNEL=1; shift ;;
        --skip-rootfs)    SKIP_ROOTFS=1; shift ;;
        --skip-usb)       SKIP_USB=1; shift ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --skip-toolchain  Skip cross-compiler toolchain build"
            echo "  --skip-kernel     Skip Linux kernel compilation"
            echo "  --skip-rootfs     Skip Arch Linux rootfs creation"
            echo "  --skip-usb        Skip USB image creation"
            echo ""
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

info()  { echo -e "\033[1;34m[BUILD]\033[0m $*"; }
sep()   { echo -e "\033[1;35m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"; }

sep
info "Xbox 360 Arch Linux Build System"
info "$(date)"
sep

# Stage 1: Toolchain
if [ "$SKIP_TOOLCHAIN" -eq 0 ]; then
    sep
    info "STAGE 1/4: Building cross-compiler toolchain"
    sep
    bash "$SCRIPT_DIR/01_build_toolchain.sh"
else
    info "Skipping toolchain build"
fi

export TOOLCHAIN_PREFIX="/usr/local/xenon-linux"
export PATH="${TOOLCHAIN_PREFIX}/bin:${PATH}"

# Stage 2: Kernel
if [ "$SKIP_KERNEL" -eq 0 ]; then
    sep
    info "STAGE 2/4: Building Linux kernel"
    sep
    bash "$SCRIPT_DIR/02_build_kernel.sh"
else
    info "Skipping kernel build"
fi

# Stage 3: Rootfs
if [ "$SKIP_ROOTFS" -eq 0 ]; then
    sep
    info "STAGE 3/4: Building Arch Linux rootfs"
    sep
    bash "$SCRIPT_DIR/03_build_archlinux_rootfs.sh"
else
    info "Skipping rootfs build"
fi

# Stage 4: USB Image
if [ "$SKIP_USB" -eq 0 ]; then
    sep
    info "STAGE 4/4: Creating bootable USB image"
    sep
    bash "$SCRIPT_DIR/04_create_usb_image.sh"
else
    info "Skipping USB image creation"
fi

sep
info "BUILD COMPLETE!"
info ""
info "Output files in: $(dirname "$SCRIPT_DIR")/output/"
ls -lh "$(dirname "$SCRIPT_DIR")/output/" 2>/dev/null || true
sep
