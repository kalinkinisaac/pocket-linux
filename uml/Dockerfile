# syntax=docker/dockerfile:1.7
# Reproducible build of the "fast mode" engine: a User-Mode Linux kernel + rootless network helper.
# Use ../make.sh --engine uml (or: docker buildx build -f uml/Dockerfile --output dist-uml uml/).
# UML exists only for x86_64 hosts in mainline Linux.
ARG KERNEL_VERSION=7.2.8
ARG KERNEL_SHA256=12e8d5a973d1ad7c5a5c69882e4022b131ed715db7003fdcd760ddf8c3e51941
ARG SLIRP_VERSION=4.9.1
ARG ALPINE=3.22

# ---------- UML kernel: static glibc binary, runs on any x86_64 Linux as a normal process ----------
FROM --platform=linux/amd64 debian:trixie-slim AS kernel
ARG KERNEL_VERSION
ARG KERNEL_SHA256
RUN --mount=type=secret,id=hostca,required=false \
    apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && if [ -s /run/secrets/hostca ]; then cp /run/secrets/hostca /usr/local/share/ca-certificates/host.crt && update-ca-certificates; fi \
 && apt-get install -y --no-install-recommends build-essential bc flex bison curl xz-utils patch python3 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN curl -fsSL --retry 5 --retry-all-errors -o linux.tar.xz \
      https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/linux-${KERNEL_VERSION}.tar.xz \
 && echo "${KERNEL_SHA256}  linux.tar.xz" | sha256sum -c - \
 && tar -xJf linux.tar.xz && rm linux.tar.xz && mv linux-${KERNEL_VERSION} linux
WORKDIR /src/linux
COPY patches/ /patches/
COPY kernel.config /kernel.config
RUN for p in /patches/*.patch; do echo "applying $p"; patch -p1 --forward < "$p"; done
# defconfig + our fragment; then fail loudly if Kconfig silently dropped anything we asked for
RUN make ARCH=um SUBARCH=x86_64 defconfig >/dev/null \
 && scripts/kconfig/merge_config.sh -m .config /kernel.config >/dev/null \
 && make ARCH=um SUBARCH=x86_64 olddefconfig >/dev/null \
 && missing=0; for l in $(grep -E '^CONFIG_[A-Z0-9_]+=y' /kernel.config); do \
      grep -qx "$l" .config || { echo "MISSING: $l"; missing=1; }; done; \
    [ $missing = 0 ] || { echo "some options could not be enabled (see above)"; exit 1; }
RUN make ARCH=um SUBARCH=x86_64 -j"$(nproc)" linux 2>&1 | grep -vE '^  (CC|AR|LD|AS|GEN|HOSTCC|UPD|CHK|SYNC|WRAP|COPY|SYSHDR|SYSTBL|HDRINST|HOSTLD|MKELF|CPP|VDSO|TABLE|UNROLL|DESCEND|CALL|CHKSHA1|POLICY|KSYMS|SORTTAB|OBJCOPY|STRIP|MKCAP|ASN\.1|CERT|MODPOST|EXPORTS)' ; \
    test -x linux \
 && mkdir -p /out && strip -s -o /out/linux-uml linux && cp .config /out/uml.config \
 && file /out/linux-uml 2>/dev/null || true; ls -la /out

# ---------- network helper: libslirp user-mode NAT, static musl ----------
FROM --platform=linux/amd64 alpine:${ALPINE} AS net
ARG SLIRP_VERSION
RUN --mount=type=secret,id=hostca,required=false \
    if [ -s /run/secrets/hostca ]; then cat /run/secrets/hostca >> /etc/ssl/certs/ca-certificates.crt; fi \
 && apk add --no-cache build-base meson ninja-build pkgconf curl glib-dev glib-static pcre2-static gettext-static libffi-dev
RUN curl -fsSL --retry 5 --retry-all-errors https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v${SLIRP_VERSION}/libslirp-v${SLIRP_VERSION}.tar.gz | tar -xz -C /tmp \
 && cd /tmp/libslirp-v${SLIRP_VERSION} && meson setup b --prefix=/usr --default-library=static --buildtype=release \
 && ninja -C b install
COPY pocket-net.c /src/pocket-net.c
RUN mkdir -p /out && gcc -O2 -Wall -Wextra -static -o /out/pocket-net /src/pocket-net.c \
      $(pkg-config --static --cflags --libs slirp) \
 && strip -s /out/pocket-net && ls -la /out

# ---------- export ----------
FROM scratch
COPY --from=kernel /out/ /
COPY --from=net /out/ /
