#!/usr/bin/env bash
# Reproducible release build in Docker.
#   ./make.sh [--arch x86_64|aarch64|riscv64] [--guest <arch>] [--variant base|desktop|all]
#             [--dynamic] [--out dist] [--host-ca]
# Result: dist/<arch>/  = files that just run on that arch (see README).
set -euo pipefail
ARCH=$(uname -m); GUEST=""; VARIANT=base; OUT=dist; STATIC=1; HOSTCA=auto
while [ $# -gt 0 ]; do case $1 in
  --arch) ARCH=$2; shift 2;;  --guest) GUEST=$2; shift 2;;  --variant) VARIANT=$2; shift 2;;
  --out) OUT=$2; shift 2;;    --dynamic) STATIC=0; shift;;  --host-ca) HOSTCA=1; shift;;
  --no-host-ca) HOSTCA=0; shift;;  -h|--help) sed -n 2,6p "$0"; exit 0;;
  *) echo "unknown arg $1"; exit 1;; esac; done
GUEST=${GUEST:-$ARCH}
plat() { case $1 in x86_64|amd64) echo linux/amd64;; aarch64|arm64) echo linux/arm64;;
         riscv64) echo linux/riscv64;; *) echo "unsupported arch $1" >&2; exit 1;; esac; }
norm() { case $1 in amd64) echo x86_64;; arm64) echo aarch64;; *) echo "$1";; esac; }
ARCH=$(norm "$ARCH"); GUEST=$(norm "$GUEST"); HP=$(plat "$ARCH"); GP=$(plat "$GUEST")
cd "$(dirname "$0")"

# foreign arch -> register qemu-user binfmt once (needs a docker daemon with --privileged allowed)
for p in "$HP" "$GP"; do
  [ "$p" = "$(plat "$(uname -m)")" ] && continue
  docker buildx inspect --bootstrap 2>/dev/null | grep -q "$p" || \
    docker run --privileged --rm tonistiigi/binfmt --install "${p#linux/}" >/dev/null
done

SECRET=()
CA=${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}
if [ "$HOSTCA" != 0 ] && [ -s "$CA" ]; then SECRET=(--secret "id=hostca,src=$CA"); fi

VARIANTS=$VARIANT; [ "$VARIANT" = all ] && VARIANTS="base desktop"
D=$OUT/$ARCH; mkdir -p "$D"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for v in $VARIANTS; do
  echo "==> host=$ARCH guest=$GUEST variant=$v static=$STATIC"
  docker buildx build --progress=plain \
    --build-arg HOST_PLATFORM="$HP" --build-arg GUEST_PLATFORM="$GP" --build-arg GUEST_ARCH="$GUEST" \
    --build-arg VARIANT="$v" --build-arg STATIC="$STATIC" "${SECRET[@]}" \
    --output "type=local,dest=$T/$v" . 2>&1 | tee "$T/build-$v.log" | grep -E '^#[0-9]+ (DONE|ERROR)|ERROR|==>' || true
  [ -f "$T/$v/pocket-$v-$GUEST.qcow2" ] || { echo "build failed, log: $T/build-$v.log"; tail -40 "$T/build-$v.log"; exit 1; }
  cp "$T/$v/pocket-$v-$GUEST.qcow2" "$D/"
  cp "$T/$v/vmlinuz" "$D/vmlinuz-$GUEST"; cp "$T/$v/initramfs" "$D/initramfs-$GUEST"
  tar -C "$T/$v/qemu" -czf "$D/qemu-$ARCH-$GUEST.tar.gz" .
  cp "$T/$v/pocket" "$D/pocket"; chmod +x "$D/pocket"
done
(cd "$D" && sha256sum -- *.gz *.qcow2 vmlinuz-* initramfs-* pocket > SHA256SUMS-$ARCH)
ls -la "$D"
