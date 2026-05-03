FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV DEVKITXENON=/usr/local/xenon
ENV PATH="${PATH}:${DEVKITXENON}/bin:${DEVKITXENON}/usr/bin"

RUN apt-get update && apt-get install -y \
    build-essential gcc g++ gcc-multilib \
    binutils flex bison texinfo \
    libgmp-dev libmpfr-dev libmpc-dev \
    wget curl git bc cpio \
    qemu-user-static binfmt-support \
    debootstrap arch-install-scripts \
    dosfstools e2fsprogs parted \
    python3 python3-pip \
    xz-utils unzip file \
    libssl-dev libelf-dev \
    kmod rsync \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY . /build/

RUN chmod +x /build/scripts/*.sh

ENTRYPOINT ["/bin/bash"]
