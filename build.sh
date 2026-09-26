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
# /dev/root: same image boots as /dev/vda (QEMU) and /dev/ubda (UML)
echo "/dev/root / ext4 rw,noatime 0 0" > $R/etc/fstab
printf '%s\n' "$M/main" "$M/community" > $R/etc/apk/repositories
sed -i 's|^tty[1-6]:|#&|' $R/etc/inittab
CON=ttyS0; [ "$ARCH" = aarch64 ] && CON=ttyAMA0
# root shell on every console the engine may provide: QEMU $CON, Apple VZ hvc0, UML tty0;
# consoles that do not exist just sleep instead of respawning in a loop
mkdir -p $R/usr/local/sbin; cat > $R/usr/local/sbin/pocket-getty <<'EOF2'
#!/bin/sh
[ -c /dev/$1 ] && [ -r /sys/class/tty/$1 ] || exec sleep 2147483647
exec /sbin/getty -n -l /bin/bash -L 115200 $1 vt100
EOF2
chmod +x $R/usr/local/sbin/pocket-getty
for c in $CON hvc0; do echo "::respawn:/usr/local/sbin/pocket-getty $c" >> $R/etc/inittab; done   # no id: init must not open it
[ "$ARCH" = x86_64 ] && echo "tty0::respawn:/sbin/getty -n -l /bin/bash 38400 tty0 vt100" >> $R/etc/inittab
sed -i 's|^root:[^:]*:|root:*:|' $R/etc/shadow          # no password login at all
sed -i 's|^root:\(.*\):/bin/sh$|root:\1:/bin/bash|' $R/etc/passwd
cat >> $R/etc/ssh/sshd_config <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
UseDNS no
EOF
echo 'rc_cgroup_mode="unified"' >> $R/etc/rc.conf
echo 'rc_parallel="YES"' >> $R/etc/rc.conf
printf '%s\n' virtio_net virtio_blk virtiofs 9p 9pnet_virtio overlay br_netfilter > $R/etc/modules
printf 'net.ipv4.ip_forward=1\n' > $R/etc/sysctl.d/pocket.conf
mkdir -p $R/etc/docker && echo '{"features":{"buildkit":true}}' > $R/etc/docker/daemon.json

en() { ln -sf /etc/init.d/$2 $R/etc/runlevels/$1/$2; }
for s in devfs dmesg mdev hwdrivers; do en sysinit $s; done
for s in modules sysctl hostname bootmisc syslog pocket-uml pocket-host networking cgroups; do en boot $s; done
for s in ntpd sshd docker local; do en default $s; done
for s in mount-ro killprocs savecache; do en shutdown $s; done

# ---- UML engine glue: the vector NIC is called vec0 -> rename to eth0 before networking ----
cat > $R/etc/init.d/pocket-uml <<'EOF'
#!/sbin/openrc-run
description="pocket-linux: User-Mode Linux glue (NIC name)"
depend() { before net networking; }
start() {
  [ -e /sys/class/net/vec0 ] && ip link set vec0 name eth0
  return 0
}
EOF
chmod +x $R/etc/init.d/pocket-uml

# ---- every-boot glue: host share, keys, CA, tz, Rosetta, disk grow -- before sshd and docker ----
cat > $R/etc/init.d/pocket-host <<'EOF'
#!/sbin/openrc-run
description="pocket-linux: host share, ssh key, host CA, timezone, disk grow"
depend() { need localmount; after modules; before sshd docker; }
start() {
mkdir -p /host
mount -t virtiofs host /host 2>/dev/null ||                                  # Apple VZ (macOS)
mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 host /host 2>/dev/null || {
  S=$(sed -n 's/.*pocket\.share=\([^ ]*\).*/\1/p' /proc/cmdline)   # UML: hostfs
  [ -n "$S" ] && mount -t hostfs -o "$S" none /host
}
P=/host/.pocket
if [ -d $P ]; then
  [ -f $P/authorized_keys ] && install -Dm600 $P/authorized_keys /root/.ssh/authorized_keys
  if [ -f $P/host-ca.crt ]; then   # corporate MITM proxies: trust the host's CAs
    cp $P/host-ca.crt /usr/local/share/ca-certificates/host.crt && update-ca-certificates >/dev/null 2>&1
  fi
  [ -f $P/tz ] && ln -sf /usr/share/zoneinfo/$(cat $P/tz) /etc/localtime
fi
# Apple VZ on Apple Silicon: run x86_64 binaries (and amd64 containers) through Rosetta
if mkdir -p /mnt/rosetta && mount -t virtiofs rosetta /mnt/rosetta 2>/dev/null; then
  mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null
  printf '%s' ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/rosetta/rosetta:OCF' \
    > /proc/sys/fs/binfmt_misc/register
fi
for d in /dev/vda /dev/ubda; do [ -b $d ] && { resize2fs $d >/dev/null 2>&1 & }; done   # grow fs to disk size (online)
return 0
}
EOF
chmod +x $R/etc/init.d/pocket-host
# user hook, last in boot (docker is up by then)
printf '#!/bin/sh\n[ -x /host/.pocket/on-boot.sh ] && /host/.pocket/on-boot.sh &\nexit 0\n' > $R/etc/local.d/00-pocket.start
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
# raw ext4 for the UML (x86_64) and Apple VZ (macOS) engines; pocket unpacks it sparse and grows it
gzip -c "$W/disk.raw" > "$OUT/pocket-$VARIANT-$ARCH.img.gz"
ls -la "$OUT"
