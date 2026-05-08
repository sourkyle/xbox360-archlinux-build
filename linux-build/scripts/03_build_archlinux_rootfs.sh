#!/bin/bash
#
# 03_build_archlinux_rootfs.sh
#
# Creates an Arch Linux (ArchPOWER) root filesystem for Xbox 360 using
# pacstrap and QEMU user-mode emulation for ppc64 big-endian.
#
# This script:
#   1. Verifies QEMU binfmt_misc for ppc64 emulation is active
#   2. Configures pacman for ArchPOWER ppc64 repositories
#   3. Installs base system packages via pacstrap or manual pacman bootstrap
#   4. Configures the system (locale, timezone, hostname, networking)
#   5. Installs kernel modules from the build output
#   6. Applies Xbox 360 hardware tweaks (ZRAM, framebuffer getty)
#   7. Packages the rootfs as a tarball
#
# Usage: ./03_build_archlinux_rootfs.sh [--output /path/to/rootfs.tar.gz] [--root-password arch]
#
# Prerequisites (Arch Linux host):
#   pacman -Syu qemu-user-static arch-install-scripts dosfstools e2fsprogs parted
#   yay -S qemu-user-static-binfmt
#   sudo systemctl restart systemd-binfmt
#
# Must be run as root (or with sudo).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$(dirname "$SCRIPT_DIR")"

ROOTFS_DIR="${BUILD_ROOT}/rootfs/archlinux-xenon"
OUTPUT_DIR="${BUILD_ROOT}/output"
OUTPUT_TARBALL="${OUTPUT_DIR}/archlinux-xenon-rootfs.tar.gz"
HOSTNAME="xenon360"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
ROOT_PASSWORD="arch"

# ArchPOWER repository configuration
ARCHPOWER_MIRROR="https://repo.archlinuxpower.org"
ARCHPOWER_ISO_MIRROR="https://archlinuxpower.org/iso"
ARCH="powerpc64"
ROOTFS_PACKAGES=(
    filesystem bash coreutils glibc pacman
    systemd systemd-sysvcompat
    iptables iproute2 iputils dhcpcd openssh
    nano less grep sed gawk
    procps-ng psmisc which file findutils
    tar gzip xz bzip2
    shadow util-linux e2fsprogs kmod
)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_TARBALL="$2"; shift 2 ;;
        --hostname) HOSTNAME="$2"; shift 2 ;;
        --timezone) TIMEZONE="$2"; shift 2 ;;
        --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

info()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (sudo)"
fi

# ─── Locate QEMU ppc64 static binary ─────────────────────────────
# Arch Linux: /usr/bin/qemu-ppc64-static (from qemu-user-static AUR)
# Debian/Ubuntu: /usr/bin/qemu-ppc64-static (from qemu-user-static)
QEMU_BIN=""
for candidate in \
    /usr/bin/qemu-ppc64-static \
    /usr/libexec/qemu-binfmt/ppc64-binfmt-P \
    /usr/bin/qemu-ppc64; do
    if [ -f "$candidate" ]; then
        QEMU_BIN="$candidate"
        break
    fi
done
if [ -z "$QEMU_BIN" ]; then
    error "qemu-ppc64-static not found. Install it first:
  Arch:   sudo pacman -Syu qemu-user-static && yay -S qemu-user-static-binfmt
          If pacman returns 404s, refresh stale sync databases/mirrors:
          sudo pacman -Syyu qemu-user-static
  Debian: apt install qemu-user-static binfmt-support"
fi
info "QEMU binary: $QEMU_BIN"

# ─── Verify binfmt_misc for ppc64 ────────────────────────────────
info "=== Checking QEMU binfmt_misc for ppc64 ==="
if [ ! -d /proc/sys/fs/binfmt_misc ]; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi

# On Arch with qemu-user-static-binfmt, systemd-binfmt handles registration.
# Check if ppc64 is registered under any name.
BINFMT_OK=0
for entry in /proc/sys/fs/binfmt_misc/qemu-ppc64*; do
    if [ -f "$entry" ]; then
        BINFMT_OK=1
        info "binfmt ppc64 handler registered: $(basename "$entry")"
        break
    fi
done

if [ "$BINFMT_OK" -eq 0 ]; then
    warn "No ppc64 binfmt handler found, attempting manual registration..."
    echo ":qemu-ppc64:M::\x7fELF\x02\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x15:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:${QEMU_BIN}:F" \
        > /proc/sys/fs/binfmt_misc/register 2>/dev/null || {
        warn "Manual binfmt registration failed."
        warn "Try: sudo systemctl restart systemd-binfmt"
    }
fi

# ─── Verify other prerequisites ───────────────────────────────────
for cmd in wget tar; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command not found: $cmd"
    fi
done

# ArchPOWER publishes one repository database for architecture-specific
# packages and one for architecture-independent packages.  Check both before
# pacman/pacstrap produce misleading mirrorlist or 404 output.
info "=== Checking ArchPOWER repository metadata ==="
for repo_db in \
    "${ARCHPOWER_MIRROR}/base/${ARCH}/base.db" \
    "${ARCHPOWER_MIRROR}/base/any/base-any.db"; do
    if ! wget -q --spider "$repo_db"; then
        error "ArchPOWER repository database is not reachable: $repo_db
Check your network connection or the ArchPOWER repository status."
    fi
done

# ─── Create rootfs directory ──────────────────────────────────────
if [ -d "$ROOTFS_DIR" ]; then
    info "Removing previous rootfs build..."
    rm -rf "$ROOTFS_DIR"
fi
info "=== Creating rootfs at ${ROOTFS_DIR} ==="
mkdir -p "$ROOTFS_DIR"

# ─── Bootstrap Arch Linux ppc64 rootfs ────────────────────────────
info "=== Bootstrapping Arch Linux ppc64 rootfs ==="

# Create base directory structure
mkdir -p "$ROOTFS_DIR"/{dev,proc,sys,run,tmp,var/{cache/pacman/pkg,lib/pacman,log},etc/pacman.d,usr/{bin,lib,share}}
chmod 1777 "$ROOTFS_DIR/tmp"
chmod 0555 "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys"

cleanup_mounts() {
    umount -l "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/sys"  2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev"  2>/dev/null || true
    umount -l "$ROOTFS_DIR/run"  2>/dev/null || true
}
trap cleanup_mounts EXIT

# Pacman install hooks expect these pseudo-filesystems in the target root.
mount --bind /proc "$ROOTFS_DIR/proc" 2>/dev/null || true
mount --bind /sys  "$ROOTFS_DIR/sys"  2>/dev/null || true
mount --bind /dev  "$ROOTFS_DIR/dev"  2>/dev/null || true
mount --bind /run  "$ROOTFS_DIR/run"  2>/dev/null || true

# Create pacman configuration targeting ArchPOWER ppc64 repos
cat > "$ROOTFS_DIR/etc/pacman.conf" << 'PACMAN_CONF'
[options]
HoldPkg     = pacman glibc
Architecture = powerpc64
SigLevel    = Never
LocalFileSigLevel = Optional

[base]
Server = https://repo.archlinuxpower.org/base/powerpc64/

[base-any]
Server = https://repo.archlinuxpower.org/base/any/
PACMAN_CONF

# Host-side pacman config for cross-architecture bootstrap
HOST_PACMAN_CONF=$(mktemp)
cat > "$HOST_PACMAN_CONF" << HOSTCONF
[options]
HoldPkg     = pacman glibc
Architecture = powerpc64
SigLevel    = Never
LocalFileSigLevel = Optional
DBPath      = ${ROOTFS_DIR}/var/lib/pacman/
CacheDir    = ${ROOTFS_DIR}/var/cache/pacman/pkg/
LogFile     = ${ROOTFS_DIR}/var/log/pacman.log

[base]
Server = ${ARCHPOWER_MIRROR}/base/powerpc64/

[base-any]
Server = ${ARCHPOWER_MIRROR}/base/any/
HOSTCONF

# On Arch hosts, pacstrap is available from arch-install-scripts.
# It handles cross-arch bootstrapping when binfmt is set up.
BOOTSTRAP_OK=0

if command -v pacstrap &>/dev/null; then
    info "Using pacstrap for bootstrap (from arch-install-scripts)..."
    if pacstrap -C "$HOST_PACMAN_CONF" -K -M "$ROOTFS_DIR" "${ROOTFS_PACKAGES[@]}" 2>&1; then
        BOOTSTRAP_OK=1
        info "pacstrap completed successfully"
    else
        warn "pacstrap failed, falling back to manual pacman bootstrap"
    fi
fi

if [ "$BOOTSTRAP_OK" -eq 0 ] && command -v pacman &>/dev/null; then
    info "Performing manual pacman bootstrap..."

    # Sync package databases
    mkdir -p "$ROOTFS_DIR/var/lib/pacman/sync"
    info "Syncing package databases..."
    pacman --config "$HOST_PACMAN_CONF" -Sy

    # Install base packages into rootfs
    info "Installing base packages into rootfs..."
    pacman --config "$HOST_PACMAN_CONF" --root "$ROOTFS_DIR" \
        --noconfirm --needed -S \
        "${ROOTFS_PACKAGES[@]}" || {
            rm -f "$HOST_PACMAN_CONF"
            error "Manual pacman bootstrap failed. No rootfs tarball was created.
Check the package error above, then re-run this script."
        }
    BOOTSTRAP_OK=1
fi

if [ "$BOOTSTRAP_OK" -eq 0 ]; then
    warn "Neither pacstrap nor pacman available on host."
    warn "Falling back to ArchPOWER ISO extraction..."

    ISO_URL="${ARCHPOWER_ISO_MIRROR}/archpower-current-powerpc64.iso"
    ISO_FILE="${BUILD_ROOT}/rootfs/archpower-powerpc64.iso"

    if [ ! -f "$ISO_FILE" ]; then
        info "Downloading ArchPOWER ppc64 ISO (~600MB)..."
        wget --show-progress -O "$ISO_FILE" "$ISO_URL"
    fi

    info "Extracting rootfs from ISO..."
    MOUNT_DIR=$(mktemp -d)
    mount -o loop,ro "$ISO_FILE" "$MOUNT_DIR"

    AIROOTFS=""
    for sfs in "$MOUNT_DIR"/arch/powerpc64/airootfs.sfs \
               "$MOUNT_DIR"/airootfs.sfs \
               "$MOUNT_DIR"/*.sfs; do
        if [ -f "$sfs" ]; then
            AIROOTFS="$sfs"
            break
        fi
    done

    if [ -n "$AIROOTFS" ]; then
        if command -v unsquashfs &>/dev/null; then
            SQFS_DIR=$(mktemp -d)
            unsquashfs -d "$SQFS_DIR" "$AIROOTFS"
            cp -a "$SQFS_DIR"/* "$ROOTFS_DIR/"
            rm -rf "$SQFS_DIR"
            BOOTSTRAP_OK=1
        else
            error "unsquashfs not found. Install squashfs-tools: pacman -S squashfs-tools"
        fi
    else
        umount "$MOUNT_DIR"
        rmdir "$MOUNT_DIR"
        error "Could not find airootfs.sfs in ISO"
    fi

    umount "$MOUNT_DIR"
    rmdir "$MOUNT_DIR"
fi

rm -f "$HOST_PACMAN_CONF"

if [ "$BOOTSTRAP_OK" -eq 0 ]; then
    error "All bootstrap methods failed. Check your internet connection and package availability."
fi

# ─── Copy QEMU static binary into rootfs for chroot ──────────────
mkdir -p "$ROOTFS_DIR/usr/bin"
cp "$QEMU_BIN" "$ROOTFS_DIR/usr/bin/qemu-ppc64-static"

# ─── Configure the rootfs via chroot ──────────────────────────────
info "=== Configuring rootfs ==="

# DNS resolution inside chroot
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true

# Hostname
echo "$HOSTNAME" > "$ROOTFS_DIR/etc/hostname"
cat > "$ROOTFS_DIR/etc/hosts" << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}
HOSTS

# Locale
if [ -f "$ROOTFS_DIR/etc/locale.gen" ]; then
    sed -i "s/^#\(${LOCALE}\)/\1/" "$ROOTFS_DIR/etc/locale.gen"
    chroot "$ROOTFS_DIR" /usr/bin/locale-gen 2>/dev/null || true
fi
echo "LANG=${LOCALE}" > "$ROOTFS_DIR/etc/locale.conf"

# Timezone
chroot "$ROOTFS_DIR" ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime 2>/dev/null || true

# fstab placeholder (real UUIDs are written by 04_create_usb_image.sh)
cat > "$ROOTFS_DIR/etc/fstab" << 'FSTAB'
# Xbox 360 Linux fstab
# UUIDs are populated automatically by 04_create_usb_image.sh
# If building manually, find your disk UUIDs with: blkid
# <filesystem>    <mount>    <type>    <options>          <dump> <pass>
#UUID=XXXXXXXX   /          ext4      errors=remount-ro  0      1
#UUID=YYYYYYYY   none       swap      sw                 0      0
FSTAB

# Network configuration (systemd-networkd DHCP on eth0)
mkdir -p "$ROOTFS_DIR/etc/systemd/network"
cat > "$ROOTFS_DIR/etc/systemd/network/20-ethernet.network" << 'NETCONF'
[Match]
Name=eth*

[Network]
DHCP=yes
NETCONF

# Enable essential services via chroot
for svc in systemd-networkd systemd-resolved systemd-timesyncd sshd; do
    chroot "$ROOTFS_DIR" systemctl enable "$svc" 2>/dev/null || \
        warn "Could not enable ${svc} (may not be installed yet)"
done

# Set root password (default: arch)
echo "root:${ROOT_PASSWORD}" | chroot "$ROOTFS_DIR" chpasswd 2>/dev/null || {
    warn "Could not set root password via chpasswd."
    warn "Set it manually after first boot with: passwd"
}

# Allow root login over SSH (needed for headless first-boot setup)
if [ -f "$ROOTFS_DIR/etc/ssh/sshd_config" ]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$ROOTFS_DIR/etc/ssh/sshd_config"
fi

# ─── Install kernel modules from build output ─────────────────────
MODULES_SRC="${OUTPUT_DIR}/modules"
if [ -d "$MODULES_SRC/lib/modules" ]; then
    info "Installing kernel modules into rootfs..."
    cp -a "$MODULES_SRC/lib/modules" "$ROOTFS_DIR/lib/"
else
    warn "No kernel modules found at $MODULES_SRC (kernel not built yet?)"
fi

# ─── Xbox 360 specific tweaks ─────────────────────────────────────
info "=== Applying Xbox 360 specific tweaks ==="

# ZRAM swap service (the 360 only has 512MB RAM, ZRAM is essential)
mkdir -p "$ROOTFS_DIR/etc/systemd/system"
cat > "$ROOTFS_DIR/etc/systemd/system/zram-swap.service" << 'ZRAM_SERVICE'
[Unit]
Description=Configure ZRAM compressed swap
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'modprobe zram && echo lz4 > /sys/block/zram0/comp_algorithm && echo 256M > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p 100 /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0 && echo 1 > /sys/block/zram0/reset'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
ZRAM_SERVICE
chroot "$ROOTFS_DIR" systemctl enable zram-swap 2>/dev/null || true

# Auto-login on tty0 (framebuffer console)
mkdir -p "$ROOTFS_DIR/etc/systemd/system/getty@tty0.service.d"
cat > "$ROOTFS_DIR/etc/systemd/system/getty@tty0.service.d/override.conf" << 'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
GETTY

# ─── Remove QEMU binary from final rootfs ────────────────────────
rm -f "$ROOTFS_DIR/usr/bin/qemu-ppc64-static"

# ─── Cleanup mounts ──────────────────────────────────────────────
cleanup_mounts
trap - EXIT

# ─── Package rootfs as tarball ────────────────────────────────────
info "=== Packaging rootfs ==="
mkdir -p "$OUTPUT_DIR"
cd "$ROOTFS_DIR"
tar czf "$OUTPUT_TARBALL" .

info ""
info "=========================================="
info "  Arch Linux rootfs build complete!"
info "  Tarball: ${OUTPUT_TARBALL}"
info "  Size: $(du -h "$OUTPUT_TARBALL" | cut -f1)"
info "=========================================="
info ""
info "  Default root password: ${ROOT_PASSWORD}"
info "  CHANGE THIS after first boot!"
info ""
