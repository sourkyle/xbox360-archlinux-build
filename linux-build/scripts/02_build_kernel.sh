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

# Verify host tools needed by the kernel build before make fails mid-build.
for cmd in bc bison flex make patch tar wget; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required host command not found: $cmd
  On Arch Linux: sudo pacman -S base-devel bc flex bison wget"
    fi
done

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

    if [ ! -s "$PATCH_FILE" ]; then
        error "Free60 patch not found or empty: $PATCH_FILE
Run ./scripts/fetch_patches.sh first. Available patch files:
$(ls "${FREE60_PATCHES}"/patch-*.diff 2>/dev/null || echo "  (none)")"
    fi

    MAJOR_VER=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VER}.x/linux-${KERNEL_VERSION}.tar.xz"
    KERNEL_TARBALL="${BUILD_ROOT}/kernel/linux-${KERNEL_VERSION}.tar.xz"

    if [ -d "$KERNEL_SRC" ]; then
        if [ -f "$KERNEL_SRC/.xenon_kernel_version" ]; then
            existing_ver="$(cat "$KERNEL_SRC/.xenon_kernel_version")"
            if [ "$existing_ver" != "$KERNEL_VERSION" ]; then
                error "Kernel source at $KERNEL_SRC is version $existing_ver, but $KERNEL_VERSION was requested.
Remove it and re-run:  rm -rf \"$KERNEL_SRC\""
            fi
        fi
    else
        if [ ! -s "$KERNEL_TARBALL" ]; then
            info "Downloading Linux ${KERNEL_VERSION}..."
            mkdir -p "$(dirname "$KERNEL_TARBALL")"
            rm -f "$KERNEL_TARBALL" "${KERNEL_TARBALL}.part"
            wget -q --show-progress -O "${KERNEL_TARBALL}.part" "$KERNEL_URL"
            if [ ! -s "${KERNEL_TARBALL}.part" ]; then
                rm -f "${KERNEL_TARBALL}.part"
                error "Failed to download kernel tarball: $KERNEL_URL"
            fi
            mv "${KERNEL_TARBALL}.part" "$KERNEL_TARBALL"
        fi
        info "Extracting kernel source..."
        mkdir -p "${BUILD_ROOT}/kernel"
        tar xf "$KERNEL_TARBALL" -C "${BUILD_ROOT}/kernel/"
        mv "${BUILD_ROOT}/kernel/linux-${KERNEL_VERSION}" "$KERNEL_SRC"
        echo "$KERNEL_VERSION" > "$KERNEL_SRC/.xenon_kernel_version"
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

# Force options the Xbox 360 boot path actually needs.  Free60's 6.18
# defconfig leaves ZRAM as a module and omits framebuffer console / generic
# HID keyboard support, which makes tty0 silent and USB keyboards inert.
if [ -x scripts/config ] || [ -f scripts/config ]; then
    scripts/config --file .config \
        --enable CONFIG_ZRAM \
        --enable CONFIG_ZSWAP \
        --enable CONFIG_ZSWAP_DEFAULT_ON \
        --enable CONFIG_VT \
        --enable CONFIG_VT_CONSOLE \
        --enable CONFIG_FRAMEBUFFER_CONSOLE \
        --enable CONFIG_FONTS \
        --enable CONFIG_FONT_8x16 \
        --enable CONFIG_DRM_FBDEV_EMULATION \
        --enable CONFIG_INPUT_KEYBOARD \
        --enable CONFIG_HID_GENERIC \
        --enable CONFIG_USB_HID \
        --enable CONFIG_MSDOS_PARTITION \
        --enable CONFIG_FHANDLE \
        --enable CONFIG_PROC_FS \
        --enable CONFIG_SYSFS \
        --enable CONFIG_UNIX98_PTYS || \
        warn "scripts/config could not apply one or more boot options"
else
    warn "scripts/config not found; kernel .config was not adjusted"
fi

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
