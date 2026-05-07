# Changelog

## Alpha 1.08 - Rootfs package failure handling and default password

- Commit: `d50432d`
- Change: Removed the nonexistent `vi` package target from Step 3, made manual pacman bootstrap failures fatal, and changed the default root password to `arch` with a `--root-password` override.
- Why: Pacman aborts the whole transaction when any requested package is missing. The old script warned but still packaged the incomplete rootfs, producing a tiny tarball with missing systemd, SSH, and password tools. Failing fast prevents unusable rootfs images, and the password default now matches the requested first-boot password.

## Alpha 1.07 - Correct ArchPOWER rootfs repositories

- Commit: `7d47215`
- Change: Updated Step 3 pacman configs to use ArchPOWER's actual `[base]` and `[base-any]` repositories and added an early metadata check for `base.db` and `base-any.db`.
- Why: ArchPOWER stores architecture-specific packages under `/base/powerpc64/` as `base.db` and architecture-independent packages under `/base/any/` as `base-any.db`. The previous `[core]`/`[extra]` config made pacman request nonexistent `core.db` and `extra.db` files, causing confusing mirrorlist or 404 failures during rootfs bootstrap.

## Alpha 1.06 - QEMU package sync guidance

- Commit: `d5bf4d1`
- Change: Updated rootfs prerequisite messages and documentation to install `qemu-user-static` with synchronized package databases (`pacman -Syu`) and to force-refresh stale databases (`pacman -Syyu`) when pacman reports package download `404` errors.
- Why: A `qemu-user-static-...pkg.tar.zst failed to download` 404 usually means pacman is using stale sync metadata or stale mirrors, not that the rootfs script is broken. The new guidance points users to refresh pacman before retrying Step 3.

## Alpha 1.05 - Kernel host prerequisite check

- Commit: `52423ed`
- Change: Added an early host-tool check to `02_build_kernel.sh` for `bc`, `bison`, `flex`, `make`, `patch`, `tar`, and `wget`.
- Why: The kernel build requires `bc` while generating `include/generated/timeconst.h`; without it, Step 2 fails deep inside `make` with `/bin/sh: bc: command not found`. Failing fast gives the exact Arch package command before a long build starts.

## Alpha 1.04 - Disable optional GCC sanitizer runtime

- Commit: `ec11faa`
- Change: Configured both GCC build stages with `--disable-libsanitizer`.
- Why: GCC 12's optional sanitizer runtime expects `crypt.h`, which modern or minimal target sysroots often omit because crypt support is provided by libxcrypt. Sanitizers are not needed for the Xbox 360 cross-toolchain, so disabling them keeps the C/C++ toolchain build focused and avoids the `fatal error: crypt.h: No such file or directory` failure.

## Alpha 1.03 - Normalize glibc startup files before GCC stage 2

- Commit: `a7ff1a6`
- Change: Added a post-glibc sysroot normalization step that ensures `crt1.o`, `crti.o`, and `crtn.o` are visible in `$SYSROOT/usr/lib` before GCC stage 2 runs.
- Why: PowerPC64 glibc can install ABI64 startup files under `lib64`, while GCC stage 2 searches through `usr/lib`/`lib` paths. Normalizing those files prevents `ld: cannot find crti.o`.

## Alpha 1.02 - Fix glibc cross-build tool selection

- Commit: `5c3b56e`
- Change: Forced the glibc bootstrap to use the stage-1 PowerPC64 C tools (`CC`, `AR`, `RANLIB`), kept host-only helpers on `BUILD_CC=gcc`, and disabled C++ detection during the glibc build.
- Why: glibc could discover the host `g++` and produce x86_64 objects such as `support/links-dso-program.o`, which were then handed to the PowerPC64 linker and failed with `Relocations in generic ELF (EM: 62)`.

## Alpha 1.01 - Handle checkout paths containing spaces

- Commit: `0427157`
- Change: Added `--prefix` parsing and routed toolchain source/build paths through a temporary no-space symlink when the checkout directory contains spaces.
- Why: GNU binutils and GCC configure scripts reject source/build paths with spaces even when shell quoting is correct. The no-space alias lets builds continue from user-friendly checkout locations.

## Alpha 1.0 - Initial uploaded build scripts

- Commit: `255afdc`
- Change: Added the initial Xbox 360 Arch Linux build system scripts, patches, Dockerfile, and documentation.
- Why: Established the baseline workflow for fetching patches, building the Xenon cross-toolchain, compiling the kernel, creating the ArchPOWER rootfs, and assembling a bootable USB image.
