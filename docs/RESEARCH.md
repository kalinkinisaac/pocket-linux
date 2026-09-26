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

### 3. User-Mode Linux
Ядро Linux как обычный процесс; CPU исполняется нативно, системные вызовы — через ptrace.
Ядро 7.2 из пакета Debian `user-mode-linux`:
- грузит тот же Alpine-rootfs (`ubd0=disk.raw`), общая папка — `hostfs`;
- **Docker работает** (overlay2, cgroup v2), контейнер стартует за 0.65 с;
- в сборке Debian нет `CONFIG_NF_TABLES_IPV4`/`IP_NF_NAT` → bridge-сеть Docker не поднять,
  только `--network host` (решается своей сборкой ядра);
- **сеть без root не заработала**: legacy-транспорт slirp удалён из ядра, остался `vector`.
  `vector` с `transport=l2tpv3,udp=1` (обычный UDP-сокет, root не нужен) в паре с
  «роутером» `qemu-system-x86_64 -M none -netdev user ... -netdev l2tpv3 ... -netdev hubport`
  выглядел рабочей схемой, но `vector_net_open` возвращает ошибку, а обработчик ошибки
  вызывает `napi_disable` на неинициализированной структуре → kernel panic.
Перспективный путь для «быстрого Docker без KVM», но требует своей сборки ядра и
отладки/патча сети. Отложено.

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
- UML со своим ядром (NAT, исправленный vector/l2tpv3 или свой userspace-роутер) — быстрый режим без KVM.
- Режим `userns`: автоматически, если разрешены user namespaces, для задач без Docker.
- Снапшоты (`qemu-img snapshot`) и `pocket save/restore`.
- Образ поменьше: `linux-virt` без лишних модулей, docker без compose.
