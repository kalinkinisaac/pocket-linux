# pocket-linux → macOS: задание для агента

## Проект одним абзацем
pocket-linux — «карманная» Linux-VM: на машине без root/sudo, без установки пакетов и без KVM
скачать из своего (приватного) GitHub-репо несколько файлов и одной командой получить Alpine Linux
с Docker, интернетом, SSH, общей папкой и опционально рабочим столом (XFCE через noVNC).
Лаунчер `pocket` (POSIX sh): `pocket up | ssh [cmd] | down | run | desktop | status | log | reset`.
Сборка всех артефактов воспроизводимая (Docker `make.sh` + GitHub Actions), бинарники статические.

## Что уже есть и проверено (Linux-хосты)
- `pocket` — лаунчер. Движки: QEMU+KVM (есть /dev/kvm), **UML** (x86_64 без KVM: ядро Linux как
  обычный процесс, загрузка ~6 с, Docker с bridge/NAT работает), QEMU TCG (остальное, медленно).
  Env: POCKET_ENGINE, POCKET_ACCEL, POCKET_MEM, POCKET_CPUS, POCKET_DISK, POCKET_PORTS, POCKET_SSH_PORT,
  POCKET_SHARE (~/.pocket/share ↔ /host), POCKET_VARIANT (base|desktop), POCKET_URL/REPO/TAG, GH_TOKEN.
- `build.sh` — образ гостя: Alpine 3.22 через apk.static, `mke2fs -d` (без root) → qcow2 (+ raw .img.gz
  для UML). Один образ грузится в QEMU (/dev/vda, 9p-шара) и в UML (/dev/ubda, hostfs).
  Глюе: `/etc/local.d/00-pocket.start` (шара, authorized_keys, CA хоста, tz, online resize2fs,
  хук on-boot.sh), сервис `pocket-uml` (vec0→eth0).
- `Dockerfile` + `make.sh --arch x86_64|aarch64|riscv64 [--guest ARCH] [--variant base|desktop|all]` —
  статический QEMU 10.2.4 на musl (+libslirp 4.9.1 из исходников), образы; результат `dist/<arch>/`.
- `uml/` — ядро UML 7.2.8 (static, SMP, NAT, Docker-опции; 2 патча) + `pocket-net.c`
  (libslirp поверх `vec0:transport=fd` через socketpair SEQPACKET).
- `.github/workflows/build.yml` — матрица x86_64 (ubuntu-24.04) и aarch64 (ubuntu-24.04-arm),
  релиз по тегу v*. Образы **aarch64 для гостя уже собираются** — на Apple Silicon использовать их.
- `docs/RESEARCH.md` — бенчмарки и все грабли. Прочитай перед работой.

## Цель на macOS
Тот же UX (`pocket up/ssh/down`, без sudo, Docker внутри, интернет, шара, проброс портов),
на Apple Silicon (главное) и Intel Mac. Требования пользователя: без sudo; воспроизводимая сборка;
бинарники самодостаточные (статика, если не раздувает размер; на macOS статика невозможна —
значит бандл с относительными путями); всё в приватный GitHub-репо; инструкции в README.

## План
### Фаза 1 — QEMU + HVF (минимум изменений, почти нативная скорость)
- Hypervisor.framework доступен без root; нужен только entitlement `com.apple.security.hypervisor`
  у бинарника QEMU. Ad-hoc подпись достаточно: `codesign -s - --entitlements hv.plist -f qemu-system-aarch64`.
- Гость = архитектура Mac: aarch64 на Apple Silicon (`-M virt,highmem=on -accel hvf -cpu host`),
  x86_64 на Intel (`-M q35 -accel hvf -cpu host`). Ядро/initramfs/qcow2 — готовые aarch64-артефакты.
  Проверь, что `vmlinuz-aarch64` из Alpine linux-virt грузится через `-kernel` (формат Image/EFI zboot);
  если нет — распаковать при сборке или грузить через UEFI (edk2-aarch64-code.fd из QEMU).
- Сеть: `-netdev user` (slirp) — без root. vmnet НЕ использовать (нужен root/entitlement от Apple).
- Шара: `-virtfs local,...` (9p на macOS-хосте поддерживается QEMU ≥ 7). Проверить права/симлинки.
- Сборка QEMU для macOS — не в Docker (нельзя). Скрипт `mac/build-qemu.sh`: закреплённые версии
  QEMU 10.2.4 и зависимостей (glib, pixman, libslirp), `--target-list=aarch64-softmmu,x86_64-softmmu`
  (или по одному), без GUI/звука. Бандл: bin/ + lib/ c `install_name_tool` → `@executable_path/../lib`
  (или dylibbundler), затем codesign с entitlement. CI: `macos-14` (arm64) и `macos-13` (x86_64).
  Артефакт: `qemu-darwin-arm64-aarch64.tar.gz`, `qemu-darwin-x86_64-x86_64.tar.gz`.
- Лаунчер: `uname -s` = Darwin → accel hvf; `nproc` нет → `sysctl -n hw.ncpu`; `truncate`
  и `cp --sparse` нет → `mkfile -n`/`dd seek=`; движок uml на macOS недоступен;
  `setsid` нет (не нужен для qemu `-daemonize`). curl не ставит quarantine, но если файлы пришли
  из браузера — `xattr -dr com.apple.quarantine ~/.pocket`.
- x86_64-гость на Apple Silicon — только TCG (медленно, как худший случай на Linux). Docker-образы
  брать arm64/multi-arch.

### Фаза 2 — Virtualization.framework (Apple VZ) + Rosetta (быстрые x86-программы)
- VZ даёт virtio-fs, NAT без root (VZNATNetworkDeviceAttachment, гость получает 192.168.64.x,
  доступен с хоста напрямую) и **Rosetta для Linux** (VZLinuxRosettaDirectoryShare + binfmt в госте) —
  x86_64-бинарники и `docker run --platform linux/amd64` в arm64-госте почти нативно.
- Не писать Swift с нуля: взять **vfkit** (open source, один бинарник, используется podman machine;
  умеет linux boot, virtio-fs, NAT, rosetta). Нужен entitlement `com.apple.security.virtualization`
  (ad-hoc подпись работает для локального запуска). Лаунчер: POCKET_ENGINE=vz на Darwin.
- IP гостя узнавать через `/var/db/dhcpd_leases` или пусть гость пишет IP в шару при загрузке.

## Критерии готовности
1. На чистом Mac без brew/sudo: `curl ... pocket && ./pocket up && ./pocket ssh docker run --rm hello-world`.
2. Внутри: интернет (HTTPS), `docker run -p 8080:80 nginx` открывается с хоста, шара /host в обе стороны.
3. Сборка артефактов воспроизводима скриптом + CI; SHA256SUMS; README обновлён.
4. Замеры (загрузка, docker run, gzip, fork) добавлены в docs/RESEARCH.md.

## Как работать
- Репозиторий: ветка main (или git bundle `pocket-linux.bundle`: `git clone pocket-linux.bundle pocket-linux`).
- Сначала прочитать README.md и docs/RESEARCH.md. При блокерах — спросить, не гадать.
- Работать в фоне: не выводить окна на передний план, не перекрывать экран.
- Коммитить небольшими шагами; секреты/токены в репо не класть.
