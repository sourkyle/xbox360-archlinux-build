#!/bin/bash
#
# fetch_patches.sh
#
# Downloads the required GCC and kernel patches for Xbox 360 (Xenon) support.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="${BUILD_ROOT}/patches"

info()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

mkdir -p "$PATCHES_DIR/gcc" "$PATCHES_DIR/kernel"

# ─── GCC VMX128 patch ─────────────────────────────────────────────
GCC_PATCH="$PATCHES_DIR/gcc/0004-disable-extra-altivec-instructions.patch"
if [ ! -f "$GCC_PATCH" ]; then
    info "Downloading GCC Xenon VMX128 patch..."
    wget -q -O "$GCC_PATCH" \
        "https://raw.githubusercontent.com/rwf93/buildroot/xbox360/package/gcc/12.3.0/0004-disable-extra-altivec-instructions.patch" || {
        warn "Failed to download from rwf93/buildroot, trying Free60Project..."
        wget -q -O "$GCC_PATCH" \
            "https://raw.githubusercontent.com/Free60Project/buildroot/xbox360_new/package/gcc/12.3.0/0004-disable-extra-altivec-instructions.patch" || {
            warn "Could not download GCC patch. You may need to obtain it manually."
            warn "Check: https://github.com/Free60Project/buildroot/tree/xbox360_new/package/gcc/"
        }
    }
    [ -f "$GCC_PATCH" ] && info "GCC patch saved to: $GCC_PATCH"
else
    info "GCC patch already exists: $GCC_PATCH"
fi

# ─── Free60 kernel patches ────────────────────────────────────────
info "Checking for Free60 kernel patches..."
KERNEL_PATCHES_REPO="https://github.com/Free60Project/linux-kernel-xbox360.git"
KERNEL_PATCHES_CLONE="$PATCHES_DIR/kernel/free60-patches"

# Check if patches are already present (shipped in-repo or previously cloned)
if ls "$KERNEL_PATCHES_CLONE"/patch-*.diff &>/dev/null 2>&1; then
    info "Free60 kernel patches already present at $KERNEL_PATCHES_CLONE"
elif [ -d "$KERNEL_PATCHES_CLONE/.git" ]; then
    info "Free60 kernel patches already cloned"
else
    info "Cloning Free60 kernel patch repository..."
    git clone --depth=1 "$KERNEL_PATCHES_REPO" "$KERNEL_PATCHES_CLONE" 2>/dev/null || \
        warn "Could not clone Free60 kernel patches repo"
fi

info ""
info "Patches directory contents:"
find "$PATCHES_DIR" -type f -name "*.patch" | sort
info ""
info "Done! Run 01_build_toolchain.sh next."
