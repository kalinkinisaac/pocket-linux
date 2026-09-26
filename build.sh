#!/usr/bin/env bash
# Builds the pocket-linux guest image natively (no emulation): Alpine + Docker [+ desktop].
# Needs root (or fakeroot) only on the BUILD machine, e.g. GitHub Actions. Users never need it.
# Usage: sudo ./build.sh [base|desktop] [outdir]
set -euo pipefail
VARIANT=${1:-base}; OUT=${2:-dist}; ARCH=${ARCH:-x86_64}
ALP=${ALPINE:-v3.22}; M=https://dl-cdn.alpinelinux.org/alpine/$ALP
FS_SIZE=${FS_SIZE:-2G}
W=$(mktemp -d); R=$W/rootfs; mkdir -p "$R" "$OUT"
trap 'rm -rf "$W"' EXIT

# apk.static: package manager as a single static binary
curl -sfL --retry 5 --retry-all-errors $M/main/$ARCH/APKINDEX.tar.gz -o $W/idx.tgz && tar -xzf $W/idx.tgz -C $W APKINDEX
V=$(awk '/^P:apk-tools-static$/{f=1} f&&/^V:/{sub("V:","");print;exit}' $W/APKINDEX)
curl -sfL --retry 5 --retry-all-errors $M/main/$ARCH/apk-tools-static-$V.apk -o $W/apk.apk
tar -xzf $W/apk.apk -C "$W" sbin/apk.static 2>/dev/null || true
[ -x $W/sbin/apk.static ] || { echo "failed to get apk.static" >&2; exit 1; }
APK="$W/sbin/apk.static -X $M/main -X $M/community -U --allow-untrusted --root $R"

PKGS="alpine-base linux-virt openrc openssh bash curl ca-certificates iproute2 e2fsprogs-extra
      docker docker-cli-compose doas tzdata htop git"
[ "$VARIANT" = desktop ] && PKGS="$PKGS xfce4 xfce4-terminal tigervnc novnc websockify dbus
      font-dejavu adwaita-icon-theme mousepad"
$APK --initdb add $PKGS >/dev/null
# trusted keys for later apk use inside the guest
$APK add alpine-keys >/dev/null

# ---- base system config ----
echo pocket > $R/etc/hostname
printf 'auto lo\niface lo inet loopback\nauto eth0\niface eth0 inet dhcp\n' > $R/etc/network/interfaces
echo "/dev/vda / ext4 rw,noatime,discard 0 1" > $R/etc/fstab
printf '%s\n' "$M/main" "$M/community" > $R/etc/apk/repositories
sed -i 's|^tty[1-6]:|#&|' $R/etc/inittab
CON=ttyS0; [ "$ARCH" = aarch64 ] && CON=ttyAMA0
echo "$CON::respawn:/sbin/getty -n -l /bin/bash -L 115200 $CON vt100" >> $R/etc/inittab
sed -i 's|^root:[^:]*:|root:*:|' $R/etc/shadow          # no password login at all
sed -i 's|^root:\(.*\):/bin/sh$|root:\1:/bin/bash|' $R/etc/passwd
cat >> $R/etc/ssh/sshd_config <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
UseDNS no
EOF
echo 'rc_cgroup_mode="unified"' >> $R/etc/rc.conf
echo 'rc_parallel="YES"' >> $R/etc/rc.conf
printf '%s\n' virtio_net virtio_blk 9p 9pnet_virtio overlay br_netfilter > $R/etc/modules
printf 'net.ipv4.ip_forward=1\n' > $R/etc/sysctl.d/pocket.conf
mkdir -p $R/etc/docker && echo '{"features":{"buildkit":true}}' > $R/etc/docker/daemon.json

en() { ln -sf /etc/init.d/$2 $R/etc/runlevels/$1/$2; }
for s in devfs dmesg mdev hwdrivers; do en sysinit $s; done
for s in modules sysctl hostname bootmisc syslog networking cgroups; do en boot $s; done
for s in sshd docker local; do en default $s; done
for s in mount-ro killprocs savecache; do en shutdown $s; done

# ---- first-boot / every-boot glue: host share, keys, CA, disk grow ----
cat > $R/etc/local.d/00-pocket.start <<'EOF'
#!/bin/sh
mkdir -p /host
mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 host /host 2>/dev/null
P=/host/.pocket
if [ -d $P ]; then
  [ -f $P/authorized_keys ] && install -Dm600 $P/authorized_keys /root/.ssh/authorized_keys
  if [ -f $P/host-ca.crt ]; then   # corporate MITM proxies: trust the host's CAs
    cp $P/host-ca.crt /usr/local/share/ca-certificates/host.crt && update-ca-certificates >/dev/null 2>&1
    rc-service docker restart >/dev/null 2>&1 &
  fi
  [ -f $P/tz ] && ln -sf /usr/share/zoneinfo/$(cat $P/tz) /etc/localtime
  [ -x $P/on-boot.sh ] && $P/on-boot.sh &
fi
resize2fs /dev/vda >/dev/null 2>&1 &   # grow fs to overlay size (online)
EOF
if [ "$VARIANT" = desktop ]; then
cat > $R/usr/local/bin/pocket-desktop <<'EOF'
#!/bin/sh
# start XFCE on VNC :1 (5901) + noVNC web client (6080)
pgrep Xvnc >/dev/null || {
  mkdir -p /root/.vnc
  Xvnc :1 -geometry ${GEOM:-1600x900} -depth 24 -SecurityTypes None -localhost=0 -AlwaysShared >/var/log/xvnc.log 2>&1 &
  sleep 1
  DISPLAY=:1 setsid dbus-launch startxfce4 >/var/log/xfce.log 2>&1 &
}
pgrep -f websockify >/dev/null || websockify -D --web /usr/share/novnc 6080 localhost:5901 >/dev/null 2>&1
echo "desktop: VNC localhost:5901  |  browser: http://localhost:6080/vnc.html"
EOF
chmod +x $R/usr/local/bin/pocket-desktop
fi
chmod +x $R/etc/local.d/*.start

# ---- export: kernel + initramfs + compressed disk ----
cp $R/boot/vmlinuz-virt "$OUT/vmlinuz"; cp $R/boot/initramfs-virt "$OUT/initramfs"; chmod 644 "$OUT"/*
rm -rf $R/boot/* $R/var/cache/apk/*
mke2fs -q -t ext4 -L pocket -d $R "$W/disk.raw" $FS_SIZE
qemu-img convert -c -O qcow2 "$W/disk.raw" "$OUT/pocket-$VARIANT-$ARCH.qcow2"
ls -la "$OUT"
