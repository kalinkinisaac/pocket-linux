#!/usr/bin/env bash
# macOS engine (Apple Virtualization.framework): vfkit (VM) + gvproxy (user-mode NAT, port forwards).
# Both are built from pinned source; they link only system frameworks, so they run on a clean Mac.
#   mac/build.sh [--arch aarch64|x86_64|all] [--out dist]   (needs Xcode CLT + Go >= 1.21)
# Result: dist/darwin/vz-darwin-<arch>.tar.gz  (bin/vfkit signed with the virtualization entitlement,
#         bin/gvproxy) + SHA256SUMS-darwin
set -euo pipefail
VFKIT=v0.6.4 GVPROXY=v0.8.9
ARCHS=all OUT=dist
while [ $# -gt 0 ]; do case $1 in
  --arch) ARCHS=$2; shift 2;;  --out) OUT=$2; shift 2;;  -h|--help) sed -n 2,6p "$0"; exit 0;;
  *) echo "unknown arg $1"; exit 1;; esac; done
[ "$ARCHS" = all ] && ARCHS="aarch64 x86_64"
[ "$(uname -s)" = Darwin ] || { echo "run on macOS"; exit 1; }
# upstream go.mod pins the toolchain it needs; fetch it and modules verified, whatever the local go env says
export GOTOOLCHAIN=auto GOPROXY=https://proxy.golang.org,direct GOSUMDB=sum.golang.org CGO_ENABLED=1 GOOS=darwin
cd "$(dirname "$0")/.."; D=$OUT/darwin; mkdir -p "$D"; D=$(cd "$D" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -c advice.detachedHead=false clone -q --depth 1 -b $VFKIT https://github.com/crc-org/vfkit "$T/vfkit"
git -c advice.detachedHead=false clone -q --depth 1 -b $GVPROXY https://github.com/containers/gvisor-tap-vsock "$T/gvp"
for a in $ARCHS; do
  case $a in aarch64) g=arm64;; x86_64) g=amd64;; *) echo "unsupported arch $a"; exit 1;; esac
  echo "==> darwin/$a: vfkit $VFKIT, gvproxy $GVPROXY"
  B=$T/out-$a/bin; mkdir -p "$B"
  (cd "$T/vfkit" && GOARCH=$g go build -trimpath -ldflags "-s -w -X github.com/crc-org/vfkit/pkg/cmdline.gitVersion=$VFKIT" \
     -o "$B/vfkit" ./cmd/vfkit)
  (cd "$T/gvp" && GOARCH=$g go build -trimpath -ldflags "-s -w" -o "$B/gvproxy" ./cmd/gvproxy)
  codesign -f -s - --entitlements "$T/vfkit/vf.entitlements" "$B/vfkit"
  tar -C "$T/out-$a" -czf "$D/vz-darwin-$a.tar.gz" bin
done
(cd "$D" && shasum -a 256 vz-darwin-*.tar.gz > SHA256SUMS-darwin)
ls -la "$D"
