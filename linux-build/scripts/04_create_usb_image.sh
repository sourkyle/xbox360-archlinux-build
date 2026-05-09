#!/bin/bash
#
# 04_create_usb_image.sh
#
# Creates a bootable USB disk image for Xbox 360 Linux.
#
# The image has the partition layout expected by XeLL:
#   Partition 1 (FAT32, 256MB): kboot.conf + kernel image
#   Partition 2 (swap, 4GB):    swap space
#   Partition 3 (ext4, rest):   root filesystem
#
# The resulting .img file can be written to a USB drive with:
#   dd if=xbox360-archlinux.img of=/dev/sdX bs=4M status=progress
#
# Usage: ./04_create_usb_image.sh [--size 8G] [--output xbox360-archlinux.img]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${BUILD_ROOT}/output"

IMAGE_SIZE="8G"
IMAGE_FILE="${OUTPUT_DIR}/xbox360-archlinux.img"
BOOT_SIZE_MB=256
SWAP_SIZE_MB=4096

KERNEL_IMAGE="${OUTPUT_DIR}/vmlinux-xenon"
ROOTFS_TARBALL="${OUTPUT_DIR}/archlinux-xenon-rootfs.tar.gz"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --size)   IMAGE_SIZE="$2"; shift 2 ;;
        --output) IMAGE_FILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

info()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

ensure_loop_device_available() {
    if losetup -f &>/dev/null; then
        return 0
    fi

    if command -v modprobe &>/dev/null; then
        modprobe loop 2>/dev/null || true
    fi

    if losetup -f &>/dev/null; then
        return 0
    fi

    error "No usable loop device is available on this host.
The loop driver could not be loaded for the running kernel: $(uname -r)

On Arch Linux this usually means the installed kernel modules do not match
the running kernel after an update. Try:
  sudo pacman -Syu linux
  sudo reboot

After reboot, verify:
  sudo modprobe loop
  losetup -f

If you are using a custom kernel, enable CONFIG_BLK_DEV_LOOP."
}

if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
fi

# Verify inputs
[ -f "$KERNEL_IMAGE" ]   || error "Kernel image not found: $KERNEL_IMAGE (run 02_build_kernel.sh first)"
[ -f "$ROOTFS_TARBALL" ] || error "Rootfs tarball not found: $ROOTFS_TARBALL (run 03_build_archlinux_rootfs.sh first)"

for cmd in truncate parted losetup mkfs.vfat mkswap mkfs.ext4 mount umount blkid tar; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command not found: $cmd
  On Arch Linux: sudo pacman -S coreutils parted util-linux dosfstools e2fsprogs tar"
    fi
done

# ─── Create disk image ───────────────────────────────────────────
info "=== Creating ${IMAGE_SIZE} disk image ==="
mkdir -p "$(dirname "$IMAGE_FILE")"
rm -f "$IMAGE_FILE"
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
[ -f "$IMAGE_FILE" ] || error "Failed to create disk image: $IMAGE_FILE"

# ─── Partition the image ──────────────────────────────────────────
info "=== Partitioning image (MBR) ==="
parted -s "$IMAGE_FILE" \
    mklabel msdos \
    mkpart primary fat32 1MiB ${BOOT_SIZE_MB}MiB \
    mkpart primary linux-swap ${BOOT_SIZE_MB}MiB $((BOOT_SIZE_MB + SWAP_SIZE_MB))MiB \
    mkpart primary ext4 $((BOOT_SIZE_MB + SWAP_SIZE_MB))MiB 100%
[ -f "$IMAGE_FILE" ] || error "Disk image disappeared after partitioning: $IMAGE_FILE"

# ─── Set up loop device ──────────────────────────────────────────
ensure_loop_device_available
if ! LOOP_DEV=$(losetup --find --show --partscan "$IMAGE_FILE" 2>&1); then
    error "Failed to attach disk image to a loop device:
$LOOP_DEV

Image path: $IMAGE_FILE
Image exists: $(if [ -f "$IMAGE_FILE" ]; then echo yes; else echo no; fi)
Running kernel: $(uname -r)

If the error mentions missing loop devices, reboot into a kernel with matching
modules or enable CONFIG_BLK_DEV_LOOP."
fi
info "Loop device: $LOOP_DEV"

cleanup() {
    info "Cleaning up..."
    umount -l "${LOOP_DEV}p3" 2>/dev/null || true
    umount -l "${LOOP_DEV}p1" 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for partition devices
sleep 1

# ─── Format partitions ───────────────────────────────────────────
info "=== Formatting partitions ==="
mkfs.vfat -F 32 -n XBOOT "${LOOP_DEV}p1"
mkswap -L XSWAP "${LOOP_DEV}p2"
mkfs.ext4 -L XROOT -F "${LOOP_DEV}p3"

# ─── Mount and populate boot partition ─────────────────────────────
MOUNT_BOOT=$(mktemp -d)
MOUNT_ROOT=$(mktemp -d)

mount "${LOOP_DEV}p1" "$MOUNT_BOOT"
mount "${LOOP_DEV}p3" "$MOUNT_ROOT"

info "=== Populating boot partition ==="
cp "$KERNEL_IMAGE" "$MOUNT_BOOT/vmlinux"

# Get partition identifiers.  The kernel can resolve PARTUUID without an
# initramfs; filesystem UUIDs are kept for fstab once userspace starts.
ROOT_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p3")
SWAP_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p2")
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${LOOP_DEV}p3")

if [ -z "$ROOT_PARTUUID" ]; then
    error "Could not determine PARTUUID for root partition: ${LOOP_DEV}p3"
fi

# Create kboot.conf
cat > "$MOUNT_BOOT/kboot.conf" << KBOOT
#KBOOTCONFIG
; Xbox 360 Arch Linux boot configuration
; Adjust maxcpus as needed (1-6). Start with 2 for stability.
;
; Video modes:
;  0: VGA_640x480     7: VGA_1280x720
; 10: HDMI_720P      11: YUV_720P
;videomode=10
speedup=1
timeout=30

archlinux="usb:/vmlinux root=PARTUUID=${ROOT_PARTUUID} rootfstype=ext4 console=tty0 panic=60 maxcpus=6 coherent_pool=16M rootwait video=xenosfb"
archlinux_safe="usb:/vmlinux root=PARTUUID=${ROOT_PARTUUID} rootfstype=ext4 console=tty0 panic=60 maxcpus=2 coherent_pool=16M rootwait video=xenosfb single"
KBOOT

info "Boot partition contents:"
ls -la "$MOUNT_BOOT/"

# ─── Populate root partition ──────────────────────────────────────
info "=== Extracting rootfs to root partition ==="
tar xzf "$ROOTFS_TARBALL" -C "$MOUNT_ROOT"

# Update fstab with actual UUIDs
cat > "$MOUNT_ROOT/etc/fstab" << FSTAB
# Xbox 360 Arch Linux fstab (auto-generated)
UUID=${ROOT_UUID}    /       ext4    errors=remount-ro    0    1
UUID=${SWAP_UUID}    none    swap    sw                   0    0
FSTAB

info "Root partition usage:"
df -h "$MOUNT_ROOT"

# ─── Unmount ──────────────────────────────────────────────────────
umount "$MOUNT_BOOT"
umount "$MOUNT_ROOT"
rmdir "$MOUNT_BOOT" "$MOUNT_ROOT"

losetup -d "$LOOP_DEV"
trap - EXIT

info ""
info "=========================================="
info "  USB image created successfully!"
info "  Image: ${IMAGE_FILE}"
info "  Size: $(du -h "$IMAGE_FILE" | cut -f1)"
info "=========================================="
info ""
info "  Write to USB drive:"
info "    sudo dd if=${IMAGE_FILE} of=/dev/sdX bs=4M status=progress"
info ""
info "  Or use a loop device to inspect:"
info "    sudo losetup -P /dev/loop0 ${IMAGE_FILE}"
info ""
