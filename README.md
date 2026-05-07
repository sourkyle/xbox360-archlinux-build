# Xbox 360 Arch Linux Build System

Build scripts for compiling and deploying Arch Linux (ArchPOWER) on Xbox 360 consoles via XeLL bootloader.

> **You need**: An RGH/JTAG-modded Xbox 360 running XeLL Reloaded, a USB HDD (16GB+), and an Arch Linux build machine.

See [`CHANGELOG.md`](CHANGELOG.md) for alpha version history and the rationale behind each build fix.

---

## Host Dependencies (Arch Linux)

```bash
# Official repos
sudo pacman -Syu base-devel bc cpio wget git python texinfo \
               libmpc mpfr gmp rsync \
               qemu-user-static arch-install-scripts \
               dosfstools e2fsprogs parted squashfs-tools \
               xz unzip file kmod

# AUR — registers binfmt handlers so the host can chroot into ppc64 rootfs
yay -S qemu-user-static-binfmt

# Activate the binfmt handlers
sudo systemctl restart systemd-binfmt
```

> **Note:** `rsync` is required by the GCC build system. If you see `rsync: command not found` during the toolchain build, install it with `sudo pacman -S rsync`.

> If pacman fails with package download `404` errors, your local sync database or mirror list is stale. Run `sudo pacman -Syyu` to force-refresh package databases, then retry the install. If it still fails, refresh `/etc/pacman.d/mirrorlist` to current HTTPS mirrors and run `sudo pacman -Syyu` again.

> `qemu-user-static-binfmt` is the current AUR package name (replaces older `binfmt-qemu-static`). It registers QEMU as the interpreter for foreign ELF binaries via systemd-binfmt, which is what lets your x86_64 Arch machine execute ppc64 binaries inside a chroot.

---

## Build Steps

All commands are run from inside the `linux-build/` directory.

### Step 0 — Fetch patches

Downloads the GCC VMX128 patch and Free60 kernel patches from GitHub.

```bash
./scripts/fetch_patches.sh
```

### Step 1 — Build the cross-compiler toolchain

Builds `powerpc64-linux-gnu` GCC 12.4 with the Xenon VMX128 patch applied. This is the longest step.

```bash
./scripts/01_build_toolchain.sh
```

If your checkout path contains spaces, such as `~/Downloads/xbox 360 modding/linux-build`, the script creates a temporary no-space symlink under `/tmp` and builds through that path. GNU binutils/GCC configure scripts reject source/build paths with spaces, so keep any custom `--prefix` path free of spaces too.

Installs to `/usr/local/xenon-linux` by default. To use a different path:

```bash
./scripts/01_build_toolchain.sh --prefix $HOME/xenon-toolchain
```

> Takes ~30-90 minutes depending on your CPU. The script is idempotent — if interrupted, re-run it and it resumes where it left off.

### Step 2 — Build the Linux kernel

Cross-compiles Linux 6.18 with Free60's Xenon platform patches applied.

```bash
./scripts/02_build_kernel.sh
```

Options:

```bash
# Use a different kernel version (must have a matching Free60 patch)
./scripts/02_build_kernel.sh --kver 6.17

# Use the rwf93/linux fork instead of vanilla+patches
./scripts/02_build_kernel.sh --method rwf93 --branch 6.5-xenon
```

> Takes ~10-20 minutes. Produces `output/vmlinux-xenon`.

### Step 3 — Create the Arch Linux rootfs

Bootstraps an ArchPOWER ppc64 root filesystem using pacman + QEMU user-mode emulation. **Requires sudo.**

```bash
sudo ./scripts/03_build_archlinux_rootfs.sh
```

Options:

```bash
sudo ./scripts/03_build_archlinux_rootfs.sh --hostname myxbox --timezone America/New_York
```

> Takes ~10-15 minutes. Produces `output/archlinux-xenon-rootfs.tar.gz`. Default root password is `xenon360`.

### Step 4 — Create the bootable USB image

Assembles the kernel and rootfs into a partitioned disk image. **Requires sudo.**

```bash
sudo ./scripts/04_create_usb_image.sh
```

Options:

```bash
# Larger image for a bigger USB drive
sudo ./scripts/04_create_usb_image.sh --size 32G
```

> Produces `output/xbox360-archlinux.img`.

### Or run all steps at once

```bash
./scripts/fetch_patches.sh
sudo ./scripts/build_all.sh
```

Skip individual stages if re-running:

```bash
sudo ./scripts/build_all.sh --skip-toolchain --skip-kernel
```

---

## Flashing to USB

**Identify your USB drive first.** Get it wrong and you overwrite the wrong disk.

```bash
# List all disks — find your USB drive (e.g. /dev/sdb)
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

# MAKE SURE /dev/sdX is your USB drive, not your system disk!
```

**Write the image:**

```bash
sudo dd if=output/xbox360-archlinux.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Replace `/dev/sdX` with your actual USB device (e.g. `/dev/sdb`). **Do not use a partition like `/dev/sdb1`** — use the whole disk device.

`conv=fsync` ensures all data is flushed to disk before dd exits. `status=progress` shows write speed and bytes written.

**Safely eject:**

```bash
sync
sudo eject /dev/sdX
```

### Partition Layout on the USB Drive

| # | Type  | Size   | Contents |
|---|-------|--------|----------|
| 1 | FAT32 | 256MB  | `kboot.conf` + kernel image (`vmlinux`) |
| 2 | swap  | 4GB    | Swap space |
| 3 | ext4  | Rest   | Arch Linux root filesystem |

---

## Booting on Xbox 360

1. Plug the USB drive into your Xbox 360
2. Boot into XeLL:
   - **RGH**: Power on, console boots to XeLL automatically (or eject button depending on your setup)
   - **JTAG**: Power button
3. XeLL reads `kboot.conf` from the FAT32 partition and shows a boot menu
4. Select **archlinux** or wait 30 seconds for auto-boot
5. Linux boots to a root shell on the framebuffer (or connect via SSH at the DHCP address)

### If it doesn't boot

- **"root partition not found"**: The kernel tells you which devices it detected and their UUIDs. Mount the FAT32 partition on your PC, edit `kboot.conf`, and fix the `root=UUID=...` to match. Also update `/etc/fstab` on the ext4 partition.
- **No video output**: Try adding `videomode=0` to `kboot.conf` for 640x480 VGA, or `videomode=10` for HDMI 720p.
- **Devices not detected**: Power-cycle the console fully — unplug the PSU for 30 seconds. The 360's USB detection is unreliable on cold boot.
- **XeLL too old**: If XeLL won't boot the kernel, you need to rebuild XeLL with the current toolchain. See the XeLL section below.

### KBoot Configuration

The generated `kboot.conf` on the FAT32 partition:

```ini
#KBOOTCONFIG
speedup=1
timeout=30

archlinux="usb:/vmlinux root=UUID=... rootfstype=ext4 console=tty0 panic=60 maxcpus=6 coherent_pool=16M rootwait video=xenosfb"
archlinux_safe="usb:/vmlinux root=UUID=... rootfstype=ext4 console=tty0 panic=60 maxcpus=2 coherent_pool=16M rootwait video=xenosfb single"
```

Key parameters you can tweak:

| Parameter | What it does |
|-----------|-------------|
| `maxcpus=6` | Number of CPU threads (1-6). Lower = more stable, less performance |
| `coherent_pool=16M` | DMA pool size, required for framebuffer on 5.x+ kernels |
| `video=xenosfb` | Xenon framebuffer driver |
| `rootwait` | Wait for USB storage to enumerate before mounting root |
| `single` | Boot to single-user mode (troubleshooting) |

---

## Post-Boot Setup

After booting on the 360:

```bash
# Change the default password immediately
passwd

# Fix the clock (360's RTC is unreliable)
timedatectl set-ntp true

# Update packages
pacman -Syu

# Install useful packages
pacman -S htop tmux git base-devel
```

### Performance Tips

- **ZRAM is pre-configured and essential.** The 360 only has 512MB RAM. The rootfs includes a systemd service that creates a 256MB compressed swap on boot.
- **Use `make -j2`** when compiling on-console. `-j3` works with ZRAM but the system gets sluggish and OOM killer may engage.
- **SSH is your friend.** The framebuffer console is slow. Set up SSH and work remotely.
- **Power-cycle for USB issues.** Unplug the PSU for 30 seconds if USB devices aren't detected.

### Known Issues

- **libpixman**: Ships with altivec enabled, crashes on Xenon. Rebuild from source: `./configure --disable-vmx`
- **Rust**: Not supported on ppc64 big-endian. Packages that depend on Rust won't build.
- **GPU**: No GPU driver for Linux. Display is software-rendered framebuffer only.

---

## XeLL Bootloader

If your XeLL is old (v0.993 from years ago), it won't boot kernels built with the current toolchain. Rebuild it:

```bash
# Using the Free60 Docker image (easiest)
docker run -it -v $PWD:/app free60/libxenon:latest
cd /app && make
```

The output `.bin` files go on your console:
- **RGH**: Rename `xell-gggggg.bin` → `updxell.bin`, put on FAT32 USB, boot with eject button
- **JTAG**: Rename `xell-2f.bin` → `updxell.bin`, same process

> **Warning**: Using `updxell` can brick your NAND if XeLL is broken. Only do this if you have the hardware to reflash (NAND programmer or similar).

---

## Directory Structure

```
.
├── Dockerfile                  # Docker build environment (alternative to native)
├── README.md                   # This file
├── .gitignore
├── scripts/
│   ├── fetch_patches.sh        # Download GCC + kernel patches
│   ├── 01_build_toolchain.sh   # Cross-compiler (binutils + GCC + glibc)
│   ├── 02_build_kernel.sh      # Linux kernel for Xenon
│   ├── 03_build_archlinux_rootfs.sh  # ArchPOWER ppc64 rootfs
│   ├── 04_create_usb_image.sh  # Bootable USB disk image
│   └── build_all.sh            # Run all stages
├── patches/
│   ├── gcc/                    # GCC VMX128 patch (downloaded by fetch_patches.sh)
│   └── kernel/free60-patches/  # Free60 kernel patches + defconfigs
├── kernel/
│   └── xenon_defconfig         # Kernel config (copy of Free60 official)
├── toolchain/                  # (created during build)
├── rootfs/                     # (created during build)
└── output/                     # Build artifacts
    ├── vmlinux-xenon           # Kernel image
    ├── kernel-config           # Kernel .config used
    ├── modules/                # Kernel modules
    ├── archlinux-xenon-rootfs.tar.gz
    └── xbox360-archlinux.img   # ← flash this to USB
```

## Troubleshooting

### Toolchain build: `libcody` error (`client.o Error 1`, `all-libcody Error 2`)

GCC 12's `libcody` library is missing `#include <cstdint>` which Arch's GCC 14 host compiler enforces. The toolchain script patches this automatically. If you hit this error on a previous build attempt:

```bash
# Clean the failed build and re-run
rm -rf toolchain/build/gcc-stage1
./scripts/01_build_toolchain.sh
```

The script now auto-cleans failed build directories on re-run, so just re-running it should work.

### Toolchain build: `rsync: command not found`

```bash
sudo pacman -S rsync
```

Then re-run `./scripts/01_build_toolchain.sh`.

### Toolchain build: `configure: error: path to source ... contains spaces`

Update to the latest scripts and re-run:

```bash
./scripts/01_build_toolchain.sh
```

The toolchain script now builds through a temporary symlink like `/tmp/xenon-linux-build-1000` when the checkout directory has spaces in its path. If you pass `--prefix`, make sure that install path does not contain spaces.

### Toolchain build: glibc `Relocations in generic ELF (EM: 62)`

This means an x86_64 host object was linked by the PowerPC64 target linker. Update to the latest scripts, remove the partial glibc build directory, and re-run Step 1:

```bash
rm -rf toolchain/build/glibc
./scripts/01_build_toolchain.sh
```

The toolchain script now forces glibc to use the stage-1 cross C compiler and disables C++ detection during the glibc bootstrap, which prevents host `g++` objects such as `support/links-dso-program.o` from entering the target link.

### Toolchain build: stage 2 GCC `cannot find crti.o`

This means stage 2 GCC cannot find glibc's startup files in the sysroot library search paths. Update to the latest scripts, remove the partial stage 2 build directory, and re-run Step 1:

```bash
rm -rf toolchain/build/gcc-stage2
./scripts/01_build_toolchain.sh
```

The toolchain script now normalizes the post-glibc sysroot library layout before stage 2 starts, including the common PowerPC64 `lib64` startup-file location.

### Toolchain build: libsanitizer `fatal error: crypt.h: No such file or directory`

This happens while GCC is building optional sanitizer runtimes. They are not needed for the Xbox 360 cross-toolchain, and GCC 12's libsanitizer expects `crypt.h`, which modern/minimal target sysroots often do not provide because crypt support lives in a separate libxcrypt package. Update to the latest scripts, remove the partial stage 2 build directory, and re-run Step 1:

```bash
rm -rf toolchain/build/gcc-stage2
./scripts/01_build_toolchain.sh
```

The toolchain script now configures GCC with `--disable-libsanitizer`.

### Kernel build: `/bin/sh: bc: command not found`

```bash
sudo pacman -S base-devel bc flex bison wget
```

Then re-run `./scripts/02_build_kernel.sh`. The kernel script checks these host tools before starting the compile so missing dependencies fail early.

### Rootfs: `binfmt` / `qemu-ppc64-static` errors

If `qemu-ppc64-static` is missing, install QEMU with a synchronized package database:

```bash
sudo pacman -Syu qemu-user-static
yay -S qemu-user-static-binfmt
sudo systemctl restart systemd-binfmt
```

If pacman reports package download `404` errors such as `qemu-user-static-...pkg.tar.zst failed to download`, force-refresh stale package databases and retry:

```bash
sudo pacman -Syyu qemu-user-static
```

Make sure the binfmt handlers are active:

```bash
sudo systemctl restart systemd-binfmt
ls /proc/sys/fs/binfmt_misc/qemu-ppc64*   # should show an entry
```

If no entry appears, your `qemu-user-static-binfmt` package may not be installed or configured correctly.

### Boot: root partition not found

The 360's USB device enumeration is non-deterministic. The device that was `/dev/sdb3` last boot might be `/dev/sdc3` next time. The kboot.conf uses `root=UUID=...` to avoid this, but if it still fails:

1. Check the kernel output — it prints detected devices and their UUIDs
2. Mount the FAT32 partition on your PC and update `kboot.conf`
3. Also update `/etc/fstab` on the ext4 partition

---

## References

- [Free60 Project](https://free60.org/) — [Debian Guide](https://free60.org/Linux/Distros/Debian/sid/) — [Kernel Patches](https://github.com/Free60Project/linux-kernel-xbox360)
- [Xbox 360 Linux — Lily Wiki](https://wiki.lilysthings.org/wiki/Xbox_360_Linux)
- [ArchPOWER](https://archlinuxpower.org/) — [ISO Downloads](https://archlinuxpower.org/iso/)
- [rwf93/linux](https://github.com/rwf93/linux) — Xbox 360 kernel fork
- [Free60Project/libxenon](https://github.com/Free60Project/libxenon) — Toolchain + XeLL
- [SED4906 Xenon Porting Notes](https://github.com/SED4906/xenon-porting-notes)
