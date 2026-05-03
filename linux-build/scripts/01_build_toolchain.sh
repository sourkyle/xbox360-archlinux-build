#!/bin/bash
#
# 01_build_toolchain.sh
#
# Builds a powerpc64-linux-gnu cross-compiler toolchain with the Xenon VMX128
# patch applied to GCC. This toolchain is used for both kernel and userland
# compilation targeting the Xbox 360's Xenon CPU.
#
# The Xenon CPU supports a subset of AltiVec (VMX128), so GCC must be patched
# to avoid emitting unsupported instructions that cause illegal instruction
# exceptions at runtime.
#
# Prerequisites:
#   - rsync must be installed (pacman -S rsync)
#   - base-devel, libmpc, mpfr, gmp, wget, texinfo, flex, bison
#
# Usage: ./01_build_toolchain.sh [--prefix /path/to/install]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$(dirname "$SCRIPT_DIR")"

BINUTILS_VERSION="2.42"
GCC_VERSION="12.4.0"
GLIBC_VERSION="2.39"
LINUX_VERSION="6.5"

TARGET="powerpc64-linux-gnu"
PREFIX="${1:-/usr/local/xenon-linux}"
SYSROOT="${PREFIX}/${TARGET}/sysroot"

JOBS="$(nproc)"
SRC_DIR="${BUILD_ROOT}/toolchain/src"
BUILD_DIR="${BUILD_ROOT}/toolchain/build"

BINUTILS_URL="https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz"
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz"
GLIBC_URL="https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VERSION}.tar.xz"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz"

export PATH="${PREFIX}/bin:${PATH}"

info()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

download() {
    local url="$1" dest="$2"
    if [ -f "$dest" ]; then
        info "Already downloaded: $(basename "$dest")"
        return 0
    fi
    info "Downloading $(basename "$dest")..."
    wget -q --show-progress -O "$dest" "$url"
}

# ─── Verify host prerequisites ────────────────────────────────────
for cmd in rsync make gcc g++ wget tar bison flex makeinfo; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command not found: $cmd
  On Arch Linux: sudo pacman -S rsync base-devel texinfo wget"
    fi
done

mkdir -p "$SRC_DIR" "$BUILD_DIR" "$PREFIX" "$SYSROOT"

# ─── Download sources ──────────────────────────────────────────────
info "=== Downloading toolchain sources ==="
download "$BINUTILS_URL" "$SRC_DIR/binutils-${BINUTILS_VERSION}.tar.xz"
download "$GCC_URL"      "$SRC_DIR/gcc-${GCC_VERSION}.tar.xz"
download "$GLIBC_URL"    "$SRC_DIR/glibc-${GLIBC_VERSION}.tar.xz"
download "$LINUX_URL"    "$SRC_DIR/linux-${LINUX_VERSION}.tar.xz"

# ─── Extract sources ───────────────────────────────────────────────
extract_if_needed() {
    local archive="$1" dir="$2"
    if [ -d "$dir" ]; then
        info "Already extracted: $(basename "$dir")"
        return 0
    fi
    info "Extracting $(basename "$archive")..."
    tar xf "$archive" -C "$SRC_DIR"
}

extract_if_needed "$SRC_DIR/binutils-${BINUTILS_VERSION}.tar.xz" "$SRC_DIR/binutils-${BINUTILS_VERSION}"
extract_if_needed "$SRC_DIR/gcc-${GCC_VERSION}.tar.xz"           "$SRC_DIR/gcc-${GCC_VERSION}"
extract_if_needed "$SRC_DIR/glibc-${GLIBC_VERSION}.tar.xz"       "$SRC_DIR/glibc-${GLIBC_VERSION}"
extract_if_needed "$SRC_DIR/linux-${LINUX_VERSION}.tar.xz"       "$SRC_DIR/linux-${LINUX_VERSION}"

# ─── Apply Xenon VMX128 patch to GCC ──────────────────────────────
GCC_SRC="$SRC_DIR/gcc-${GCC_VERSION}"
PATCH_FILE="${BUILD_ROOT}/patches/gcc/0004-disable-extra-altivec-instructions.patch"

if [ -f "$PATCH_FILE" ]; then
    if [ ! -f "$GCC_SRC/.xenon_patched" ]; then
        info "Applying Xenon VMX128 GCC patch..."
        cd "$GCC_SRC"
        patch -p1 < "$PATCH_FILE" || warn "Patch may have already been applied"
        touch "$GCC_SRC/.xenon_patched"
    else
        info "Xenon GCC patch already applied"
    fi
else
    warn "Xenon GCC patch not found at $PATCH_FILE"
    warn "The toolchain will build but binaries may use unsupported AltiVec instructions."
    warn "Download the patch from:"
    warn "  https://raw.githubusercontent.com/rwf93/buildroot/xbox360/package/gcc/12.3.0/0004-disable-extra-altivec-instructions.patch"
fi

# ─── Fix libcody for newer host compilers (GCC 14+) ──────────────
#
# GCC 12's libcody is missing #include <cstdint> which GCC 14+ (as shipped
# by Arch Linux) enforces strictly. Without this fix, the build fails with:
#   make[1]: *** [Makefile:58: client.o] Error 1
#   make: *** [Makefile:9163: all-libcody] Error 2
#
for cody_file in "$GCC_SRC"/libcody/client.cc "$GCC_SRC"/libcody/server.cc; do
    if [ -f "$cody_file" ]; then
        if ! grep -q '#include <cstdint>' "$cody_file"; then
            info "Patching $(basename "$cody_file"): adding missing #include <cstdint>"
            sed -i '/#include.*<cstdlib>/a #include <cstdint>' "$cody_file" 2>/dev/null || \
            sed -i '1s/^/#include <cstdint>\n/' "$cody_file"
        fi
        if ! grep -q '#include <cstdlib>' "$cody_file"; then
            info "Patching $(basename "$cody_file"): adding missing #include <cstdlib>"
            sed -i '1s/^/#include <cstdlib>\n/' "$cody_file"
        fi
    fi
done

# Download GCC prerequisites (GMP, MPFR, MPC, ISL)
cd "$GCC_SRC"
if [ ! -d "gmp" ]; then
    info "Downloading GCC prerequisites..."
    ./contrib/download_prerequisites
fi

# ─── Step 1: Binutils ─────────────────────────────────────────────
BINUTILS_BUILD="$BUILD_DIR/binutils"
if [ ! -f "$PREFIX/bin/${TARGET}-as" ]; then
    info "=== Building binutils ${BINUTILS_VERSION} ==="
    mkdir -p "$BINUTILS_BUILD"
    cd "$BINUTILS_BUILD"
    "$SRC_DIR/binutils-${BINUTILS_VERSION}/configure" \
        --target="$TARGET" \
        --prefix="$PREFIX" \
        --with-sysroot="$SYSROOT" \
        --disable-nls \
        --disable-werror \
        --enable-64-bit-bfd
    make -j"$JOBS"
    make install
    info "Binutils installed"
else
    info "Binutils already installed, skipping"
fi

# ─── Step 2: Linux kernel headers ────────────────────────────────
if [ ! -d "$SYSROOT/usr/include/linux" ]; then
    info "=== Installing Linux kernel headers ==="
    cd "$SRC_DIR/linux-${LINUX_VERSION}"
    make ARCH=powerpc INSTALL_HDR_PATH="$SYSROOT/usr" headers_install
    info "Kernel headers installed"
else
    info "Kernel headers already installed, skipping"
fi

# ─── Step 3: GCC (stage 1 — C compiler only, no libc) ────────────
GCC_BUILD_S1="$BUILD_DIR/gcc-stage1"
if [ ! -f "$PREFIX/bin/${TARGET}-gcc" ]; then
    info "=== Building GCC stage 1 (C only) ==="
    # Clean any previous failed build attempt
    if [ -d "$GCC_BUILD_S1" ]; then
        info "Cleaning previous stage 1 build directory..."
        rm -rf "$GCC_BUILD_S1"
    fi
    mkdir -p "$GCC_BUILD_S1"
    cd "$GCC_BUILD_S1"
    "$GCC_SRC/configure" \
        --target="$TARGET" \
        --prefix="$PREFIX" \
        --with-sysroot="$SYSROOT" \
        --with-newlib \
        --without-headers \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libssp \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libatomic \
        --disable-libstdcxx \
        --enable-languages=c \
        --with-cpu=cell \
        --enable-altivec
    make -j"$JOBS" all-gcc all-target-libgcc
    make install-gcc install-target-libgcc
    info "GCC stage 1 installed"
else
    info "GCC stage 1 already installed, skipping"
fi

# ─── Step 4: Glibc ────────────────────────────────────────────────
GLIBC_BUILD="$BUILD_DIR/glibc"
if [ ! -f "$SYSROOT/lib/libc.so.6" ]; then
    info "=== Building glibc ${GLIBC_VERSION} ==="
    if [ -d "$GLIBC_BUILD" ]; then
        info "Cleaning previous glibc build directory..."
        rm -rf "$GLIBC_BUILD"
    fi
    mkdir -p "$GLIBC_BUILD"
    cd "$GLIBC_BUILD"

    "$SRC_DIR/glibc-${GLIBC_VERSION}/configure" \
        --host="$TARGET" \
        --build="$(gcc -dumpmachine)" \
        --prefix="/usr" \
        --with-headers="$SYSROOT/usr/include" \
        --disable-multilib \
        --disable-werror \
        libc_cv_forced_unwind=yes
    make -j"$JOBS"
    make install DESTDIR="$SYSROOT"
    info "Glibc installed"
else
    info "Glibc already installed, skipping"
fi

# ─── Step 5: GCC (stage 2 — full C/C++ with libc) ────────────────
GCC_BUILD_S2="$BUILD_DIR/gcc-stage2"
if [ ! -f "$PREFIX/bin/${TARGET}-g++" ]; then
    info "=== Building GCC stage 2 (C/C++) ==="
    if [ -d "$GCC_BUILD_S2" ]; then
        info "Cleaning previous stage 2 build directory..."
        rm -rf "$GCC_BUILD_S2"
    fi
    mkdir -p "$GCC_BUILD_S2"
    cd "$GCC_BUILD_S2"
    "$GCC_SRC/configure" \
        --target="$TARGET" \
        --prefix="$PREFIX" \
        --with-sysroot="$SYSROOT" \
        --disable-nls \
        --disable-multilib \
        --enable-shared \
        --enable-threads=posix \
        --enable-languages=c,c++ \
        --with-cpu=cell \
        --enable-altivec
    make -j"$JOBS"
    make install
    info "GCC stage 2 installed"
else
    info "GCC stage 2 already installed, skipping"
fi

info ""
info "=========================================="
info "  Toolchain build complete!"
info "  Target: ${TARGET}"
info "  Prefix: ${PREFIX}"
info "  Sysroot: ${SYSROOT}"
info "=========================================="
info ""
info "Add to your environment:"
info "  export PATH=\"${PREFIX}/bin:\$PATH\""
info ""
