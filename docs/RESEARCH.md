# Исследование: как запустить «свой Linux» без root и без KVM

Тестовый стенд — худший случай: 1 vCPU, 4 ГБ RAM, нет `/dev/kvm`, нет vmx/svm,
запуск от непривилегированного пользователя. Хост Ubuntu 24.04, ядро 6.18.

## Сравнение подходов

Время в мс (меньше — лучше). `userns` — chroot через `unshare -r`.

| тест | хост | userns | UML | QEMU TCG |
|---|---|---|---|---|
| sha256 100 МБ (busybox) | 566 | 566 | 844 | 3684 |
| gzip 20 МБ | 780 | 789 | 880 | 4686 |
| 300 fork+exec | 264 | 99 | 951 | 4548 |
| запись 200 МБ + fsync | 286 | 291 | 568 | 2819 |
| 2000 мелких файлов | 183 | 52 | 420 | 2232 |
| старт Docker-контейнера | — | ✗ | 650 | 8400 |
| сеть без root | да (хоста) | да | ✗ (см. ниже) | да, ~2.8 МБ/с при 16 на хосте |

### 1. QEMU TCG (выбран как основной)
Работает везде, где можно запустить процесс. Полноценное ядро → Docker, bridge-сеть,
iptables, overlay2, cgroup v2 — всё как на обычной машине. Цена — замедление в 6–30 раз.
С KVM тот же образ работает почти нативно.

### 2. User namespaces (`unshare -r` + chroot/pivot_root)
Нативная скорость, `apk add` работает. Но:
- на многих серверах выключены (`kernel.unprivileged_userns_clone=0`, AppArmor в Ubuntu 24.04);
- без `newuidmap`/`/etc/subuid` (ставит админ) доступен ровно один UID → podman
  скачивает образ, но `crun` падает на `devpts`/cgroups. Docker — нет.
Кандидат на будущий «быстрый режим без контейнеров».

### 3. User-Mode Linux (выбран как быстрый режим без KVM на x86_64)
Ядро Linux как обычный процесс: код гостя исполняет настоящий CPU, перехватываются только
системные вызовы (seccomp или ptrace — оба доступны любому пользователю для своих процессов).

**Первая попытка — пакет Debian `user-mode-linux` 7.2:** Docker работал (контейнер 0.65 с), но
(а) в конфиге нет NAT → только `--network host`; (б) сети без root нет: legacy slirp-транспорт
удалён, а `vector:transport=l2tpv3` + QEMU-«роутер» падал в `vector_net_open` → `napi_disable`
на неинициализированной структуре → kernel panic.

**Решение (uml/):**
- Своё ядро 7.2.8 (текущая стабильная; в 7.x у UML впервые есть SMP — `ncpus=`), статическая
  линковка, всё встроено (без модулей): NAT/nftables/iptables-legacy, veth/bridge, overlayfs,
  cgroup v2 + BPF, hostfs, `UML_NET_VECTOR`. После `olddefconfig` сборка проверяет, что ни одна
  опция из фрагмента не потерялась. 10 минут на 1 ядре, бинарник 10 МБ.
- Патч 1: `UML_NET_VECTOR` делает `select MAY_HAVE_RUNTIME_DEPS` (из-за getaddrinfo для gre/l2tpv3),
  что запрещает `STATIC_LINK`. Убираем select — нам нужен только fd-транспорт.
- Патч 2 (из проекта Haven, github.com/GlassOnTin/uml-transport): `vector_poll` завершал NAPI при
  `work_done == budget` → под нагрузкой RX «засыпает».
- Сеть: транспорт `vec0:transport=fd,fd=N` (есть в ядре с 6.x) + свой помощник `pocket-net`
  (~300 строк C, libslirp статически на musl, 1.2 МБ): создаёт `socketpair(AF_UNIX, SOCK_SEQPACKET)`,
  запускает ядро с одним концом, на другом крутит slirp (DHCP/DNS/NAT/hostfwd как у QEMU `-netdev user`).
  SEQPACKET, а не DGRAM: у DGRAM очередь приёмника ограничена `max_dgram_qlen`=10 → потери.
  Та же идея у Haven (passt вместо libslirp, Android arm64).
- Гость тот же образ Alpine: сервис `pocket-uml` переименовывает `vec0`→`eth0`, общая папка
  монтируется через `hostfs` (ядро ограничено `hostfs=$POCKET_SHARE`), fstab на `/dev/root`.
- RAM гостя UML держит в файле в `$TMPDIR` → нужен каталог с exec и свободным местом ≥ `POCKET_MEM`
  (лаунчер проверяет `/dev/shm`, `$TMPDIR`, `~/.pocket`).

**Результат (1 vCPU, от непривилегированного пользователя):** загрузка до SSH 6 с (TCG 110 с);
Docker 28.3.3, overlay2, cgroup v2, **bridge-сеть с NAT**, контейнер выходит в интернет,
`-p 8080:80` работает; `docker run` 0.75–0.85 с (TCG 8.4 с); pull alpine 1.2 с;
gzip 742 мс против 653 на хосте; 300 fork+exec 1104 против 251; 2000 файлов 483 против 71.

### Не подходят
- Firecracker, Cloud Hypervisor, crosvm — только с KVM.
- proot — ptrace на каждый syscall, Docker невозможен.
- gVisor (runsc) — умеет без KVM (systrap), но rootless-режим ограничен, Docker внутри экспериментален.

## Грабли, на которые наступили

- **QEMU из дистрибутива модульный.** Ubuntu-шный `qemu-system-x86_64` даже TCG
  (`accel-tcg-x86_64.so`) грузит из `/usr/lib/x86_64-linux-gnu/qemu/`. Бандл «бинарник + ldd-библиотеки»
  на чистой машине не заработает. Решение — своя сборка с `--disable-modules`, лучше `--static`.
- **Корпоративный TLS-прокси** подменяет сертификаты → HTTPS в госте и в Docker-сборке падает.
  Решение — прокидывать CA хоста (в VM через общую папку, в сборку через build secret).
- **Word splitting в sh**: `$(func_that_echoes_args)` режет `-append "a b c"` на части.
  Аргументы QEMU передаются напрямую, без `echo`.
- **`a && b && c || true`** в Dockerfile глотает ошибку любого шага — сборка «успешна», файлов нет.
- **`set -o pipefail` + `tar | awk '...{exit}'`** — tar получает SIGPIPE, скрипт молча завершается.
- **`pkill -f <шаблон>`** из shell-скрипта убивает и сам скрипт, если шаблон есть в его командной строке.
- **Статический QEMU на Alpine**: есть `glib-static`, `pixman-static`, `zlib-static`, `pcre2-static`,
  `gettext-static`; `libslirp` статически нет → собираем из исходников. Для ARM-гостя нужен libfdt —
  берём встроенный (`--enable-fdt=internal`, требует git при configure).
- `mke2fs -d <dir>` собирает ext4-образ из каталога без root и без loop-устройств.
- `apk.static` ставит целую систему в каталог (`--root --initdb`) без Alpine на хосте.

## Идеи на будущее
- UML: проверить внутри Docker-контейнера хоста (seccomp-профиль Docker, маленький /dev/shm).
- UML: `seccomp=on` принудительно и замерить против ptrace; проверить SMP на многоядерном хосте.
- UML для arm64-хостов (форк zalexdev/linux-um-arm64, как у Haven) — не в mainline.
- macOS/iOS — см. `HANDOFF-MAC.md`, `IOS.md`.
- Режим `userns`: автоматически, если разрешены user namespaces, для задач без Docker.
- Снапшоты (`qemu-img snapshot`) и `pocket save/restore`.
- Образ поменьше: `linux-virt` без лишних модулей, docker без compose.
