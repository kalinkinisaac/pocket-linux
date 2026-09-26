# syntax=docker/dockerfile:1.7
# Reproducible build of pocket-linux release files. Use ./make.sh, not this file directly.
#   HOST_PLATFORM  — where `pocket` + QEMU will RUN   (linux/amd64, linux/arm64, linux/riscv64)
#   GUEST_PLATFORM — architecture of the VM itself   (defaults to the same)
ARG HOST_PLATFORM=linux/amd64
ARG GUEST_PLATFORM=${HOST_PLATFORM}
ARG ALPINE=3.22

# ---------- base: Alpine + optional extra CA (corporate TLS proxies) ----------
FROM --platform=${HOST_PLATFORM} alpine:${ALPINE} AS base-host
RUN --mount=type=secret,id=hostca,required=false \
    if [ -s /run/secrets/hostca ]; then cat /run/secrets/hostca >> /etc/ssl/certs/ca-certificates.crt; fi

# ---------- static QEMU (musl), runs on HOST, emulates GUEST ----------
FROM base-host AS qemu
ARG QEMU_VERSION=10.2.4
ARG SLIRP_VERSION=4.9.1
ARG GUEST_ARCH=x86_64
ARG STATIC=1
RUN apk add --no-cache build-base python3 py3-setuptools meson ninja-build pkgconf bash perl flex bison \
      linux-headers curl xz git glib-dev glib-static pixman-dev pixman-static zlib-dev zlib-static \
      pcre2-dev pcre2-static gettext-static libffi-dev
# libslirp (user-mode NAT networking) has no static package in Alpine -> build it
RUN curl -fsSL --retry 5 --retry-all-errors https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v${SLIRP_VERSION}/libslirp-v${SLIRP_VERSION}.tar.gz | tar -xz -C /tmp \
 && cd /tmp/libslirp-v${SLIRP_VERSION} && meson setup b --prefix=/usr --default-library=both --buildtype=release \
 && ninja -C b install
RUN curl -fsSL --retry 5 --retry-all-errors https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz | tar -xJ -C /tmp
WORKDIR /tmp/qemu-${QEMU_VERSION}/b
# minimal feature set: TCG + KVM, virtio, slirp NAT, 9p share. No GUI/audio/USB/net-block backends.
RUN set -e; FDT=--enable-fdt=internal; [ "$GUEST_ARCH" = x86_64 ] && FDT=--disable-fdt; \
    ../configure --target-list=${GUEST_ARCH}-softmmu --prefix=/opt/pq $( [ "$STATIC" = 1 ] && echo --static ) \
      --disable-docs --disable-modules --disable-user --disable-gtk --disable-sdl --disable-opengl --disable-spice \
      --disable-vnc-jpeg --disable-vnc-sasl --disable-png --audio-drv-list= --disable-alsa --disable-pa --disable-jack \
      --disable-oss --disable-pipewire --disable-sndio --disable-libusb --disable-usb-redir --disable-curl \
      --disable-rbd --disable-glusterfs --disable-libiscsi --disable-libnfs --disable-xen --disable-gnutls \
      --disable-nettle --disable-gcrypt --disable-capstone --disable-libssh --disable-bpf --disable-seccomp \
      --disable-libudev --disable-guest-agent --disable-linux-io-uring --disable-libdw --disable-zstd \
      --enable-tools --enable-slirp --enable-virtfs --enable-kvm --enable-tcg $FDT --disable-werror; \
    test -f build.ninja; \
    ninja qemu-system-${GUEST_ARCH} qemu-img \
 && mkdir -p /out/qemu/bin /out/qemu/share \
 && cp qemu-system-${GUEST_ARCH} qemu-img /out/qemu/bin/ && strip -s /out/qemu/bin/* \
 && for f in bios-256k.bin linuxboot_dma.bin kvmvapic.bin vgabios-stdvga.bin; do \
      [ -f ../pc-bios/$f ] && cp ../pc-bios/$f /out/qemu/share/ || true; done \
 && if [ "$STATIC" != 1 ]; then \
      mkdir -p /out/qemu/lib && for b in /out/qemu/bin/*; do ldd $b | grep -oE '/[^ ]+\.so[^ ]*'; done | sort -u | xargs -I{} cp -L {} /out/qemu/lib/; fi; \
    ls -la /out/qemu/bin

# ---------- guest image: Alpine rootfs + kernel, built natively for GUEST ----------
FROM --platform=${GUEST_PLATFORM} alpine:${ALPINE} AS image
RUN --mount=type=secret,id=hostca,required=false \
    if [ -s /run/secrets/hostca ]; then cat /run/secrets/hostca >> /etc/ssl/certs/ca-certificates.crt; fi
RUN apk add --no-cache bash curl e2fsprogs e2fsprogs-extra tar gzip
ARG VARIANT=base
ARG FS_SIZE=2G
COPY --from=qemu /out/qemu/bin/qemu-img /usr/local/bin/qemu-img-host
COPY build.sh /build.sh
# qemu-img is only needed to write qcow2; if host arch != guest arch, use the one from apk
RUN if /usr/local/bin/qemu-img-host --version >/dev/null 2>&1; then ln -s qemu-img-host /usr/local/bin/qemu-img; \
    else apk add --no-cache qemu-img; fi \
 && ARCH=$(uname -m) FS_SIZE=${FS_SIZE} bash /build.sh ${VARIANT} /dist

# ---------- export: only the release files ----------
FROM scratch
COPY --from=qemu /out/ /
COPY --from=image /dist/ /
COPY pocket /pocket
