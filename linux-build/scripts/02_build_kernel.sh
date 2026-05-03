#!/bin/bash
#
# 02_build_kernel.sh
#
# Builds the Linux kernel for Xbox 360 (Xenon platform).
#
# This script supports two approaches:
#   A) Use rwf93/linux (pre-patched kernel fork, branches: 5.17, 6.5-xenon)
#   B) Use vanilla kernel + Free60 patches (6.16, 6.17, 6.18 available)
#
# The Free60 project now provides patches for 6.16–6.18 kernels with official
# defconfigs that include all Xenon-specific drivers (framebuffer via DRM/Xenos,
# SATA, ethernet, LEDs, SMC, RTC, sensors, joystick).
#
# Usage:
#   ./02_build_kernel.sh                          # Default: vanilla 6.18 + Free60 patches
#   ./02_build_kernel.sh --method rwf93           # Use rwf93/linux fork
#   ./02_build_kernel.sh --method free60 --kver 6.17  # Vanilla 6.17 + Free60 patches
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$(dirname "$SCRIPT_DIR")"

BUILD_METHOD="free60"          # "free60" or "rwf93"
KERNEL_VERSION="6.18"          # For free60 method
RWF93_BRANCH="6.5-xenon"      # For rwf93 method

KERNEL_SRC="${BUILD_ROOT}/kernel/linux-xenon"
OUTPUT_DIR="${BUILD_ROOT}/output"

PREFIX="${TOOLCHAIN_PREFIX:-/usr/local/xenon-linux}"
TARGET="powerpc64-linux-gnu"
CROSS_COMPILE="${PREFIX}/bin/${TARGET}-"

JOBS="$(nproc)"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --method)     BUILD_METHOD="$2"; shift 2 ;;
        --kver)       KERNEL_VERSION="$2"; shift 2 ;;
        --branch)     RWF93_BRANCH="$2"; shift 2 ;;
        --kernel-src) KERNEL_SRC="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

export PATH="${PREFIX}/bin:${PATH}"

info()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# Verify cross-compiler exists
if ! command -v "${TARGET}-gcc" &>/dev/null; then
    error "Cross-compiler not found. Run 01_build_toolchain.sh first."
fi
info "Cross-compiler: $(${TARGET}-gcc --version | head -1)"

# ─── Source acquisition ───────────────────────────────────────────
if [ "$BUILD_METHOD" = "free60" ]; then
    info "=== Method: Vanilla kernel ${KERNEL_VERSION} + Free60 patches ==="

    FREE60_PATCHES="${BUILD_ROOT}/patches/kernel/free60-patches"
    PATCH_FILE="${FREE60_PATCHES}/patch-${KERNEL_VERSION}-xenon0.30.diff"
    DEFCONFIG_FILE="${FREE60_PATCHES}/xenon-${KERNEL_VERSION}.defconfig"

    if [ ! -f "$PATCH_FILE" ]; then
        error "Free60 patch not found: $PATCH_FILE"
        error "Run fetch_patches.sh first, or check available versions:"
        ls "${FREE60_PATCHES}"/patch-*.diff 2>/dev/null || true
    fi

    MAJOR_VER=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VER}.x/linux-${KERNEL_VERSION}.tar.xz"
    KERNEL_TARBALL="${BUILD_ROOT}/kernel/linux-${KERNEL_VERSION}.tar.xz"

    if [ ! -d "$KERNEL_SRC" ]; then
        if [ ! -f "$KERNEL_TARBALL" ]; then
            info "Downloading Linux ${KERNEL_VERSION}..."
            mkdir -p "$(dirname "$KERNEL_TARBALL")"
            wget -q --show-progress -O "$KERNEL_TARBALL" "$KERNEL_URL"
        fi
        info "Extracting kernel source..."
        tar xf "$KERNEL_TARBALL" -C "${BUILD_ROOT}/kernel/"
        mv "${BUILD_ROOT}/kernel/linux-${KERNEL_VERSION}" "$KERNEL_SRC"
    fi

    cd "$KERNEL_SRC"

    # Apply Free60 Xenon patch
    if [ ! -f ".free60_patched" ]; then
        info "Applying Free60 Xenon patch: $(basename "$PATCH_FILE")"
        patch -p1 < "$PATCH_FILE"
        touch .free60_patched
    else
        info "Free60 patch already applied"
    fi

    # Use official Free60 defconfig
    if [ -f "$DEFCONFIG_FILE" ]; then
        info "Using official Free60 defconfig: $(basename "$DEFCONFIG_FILE")"
        cp "$DEFCONFIG_FILE" arch/powerpc/configs/xenon_defconfig
    elif [ -f "${BUILD_ROOT}/kernel/xenon_defconfig" ]; then
        info "Using local xenon_defconfig"
        cp "${BUILD_ROOT}/kernel/xenon_defconfig" arch/powerpc/configs/xenon_defconfig
    fi

elif [ "$BUILD_METHOD" = "rwf93" ]; then
    info "=== Method: rwf93/linux fork (branch: ${RWF93_BRANCH}) ==="

    if [ ! -d "$KERNEL_SRC/.git" ]; then
        mkdir -p "$(dirname "$KERNEL_SRC")"
        git clone --depth=1 --branch "$RWF93_BRANCH" \
            "https://github.com/rwf93/linux.git" "$KERNEL_SRC" || {
            warn "Branch '${RWF93_BRANCH}' not found, cloning default branch"
            git clone --depth=1 "https://github.com/rwf93/linux.git" "$KERNEL_SRC"
        }
    fi

    cd "$KERNEL_SRC"

    if [ -f "${BUILD_ROOT}/kernel/xenon_defconfig" ]; then
        cp "${BUILD_ROOT}/kernel/xenon_defconfig" arch/powerpc/configs/xenon_defconfig
    fi
else
    error "Unknown build method: $BUILD_METHOD (use 'free60' or 'rwf93')"
fi

# ─── Configure kernel ─────────────────────────────────────────────
info "=== Configuring kernel ==="

if [ -f "arch/powerpc/configs/xenon_defconfig" ]; then
    make ARCH=powerpc CROSS_COMPILE="$CROSS_COMPILE" xenon_defconfig
else
    warn "No xenon_defconfig found. Using ppc64_defconfig as fallback."
    make ARCH=powerpc CROSS_COMPILE="$CROSS_COMPILE" ppc64_defconfig
fi

# Ensure ZRAM is built-in (not module) for immediate swap availability
scripts/config --file .config \
    --enable CONFIG_ZRAM \
    --enable CONFIG_ZSWAP \
    --enable CONFIG_ZSWAP_DEFAULT_ON 2>/dev/null || true

make ARCH=powerpc CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

# ─── Build kernel ─────────────────────────────────────────────────
info "=== Compiling Linux kernel ==="
make ARCH=powerpc CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" all

# ─── Build Debian packages (optional, useful for deployment) ──────
if command -v dpkg-deb &>/dev/null; then
    info "=== Building kernel .deb packages ==="
    make ARCH=powerpc CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" bindeb-pkg 2>/dev/null || \
        warn "Debian package build skipped (non-fatal)"
fi

# ─── Install modules to output dir ────────────────────────────────
MODULES_DIR="${OUTPUT_DIR}/modules"
mkdir -p "$MODULES_DIR"
make ARCH=powerpc CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$MODULES_DIR" modules_install

# ─── Copy kernel image to output ──────────────────────────────────
mkdir -p "$OUTPUT_DIR"

KERNEL_IMAGE=""
for candidate in \
    arch/powerpc/boot/zImage.xenon \
    arch/powerpc/boot/zImage \
    vmlinux; do
    if [ -f "$candidate" ]; then
        KERNEL_IMAGE="$candidate"
        break
    fi
done

if [ -z "$KERNEL_IMAGE" ]; then
    error "No kernel image found after compilation!"
fi

cp "$KERNEL_IMAGE" "$OUTPUT_DIR/vmlinux-xenon"
cp .config "$OUTPUT_DIR/kernel-config"

info ""
info "=========================================="
info "  Kernel build complete!"
info "  Method: ${BUILD_METHOD}"
info "  Version: $(make -s kernelrelease 2>/dev/null || echo 'unknown')"
info "  Image: ${OUTPUT_DIR}/vmlinux-xenon"
info "  Config: ${OUTPUT_DIR}/kernel-config"
info "  Modules: ${MODULES_DIR}/"
info "=========================================="
