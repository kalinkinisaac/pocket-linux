# pocket-linux

Карманная Linux-VM, которая запускается **без root, без установки пакетов и без KVM**.
Качается из GitHub Releases одной командой, внутри — Alpine с Docker, SSH, интернетом
и (в варианте `desktop`) XFCE-рабочим столом через браузер.

- QEMU собран **статически** (musl) — один бинарник, не зависит от библиотек хоста.
- Есть `/dev/kvm` с доступом → скорость почти нативная. Нет → программная эмуляция (TCG),
  медленнее, но работает везде.
- Сеть — user-mode NAT (slirp), root не нужен. SSH и нужные порты пробрасываются на `127.0.0.1`.
- Общая папка с хостом: `~/.pocket/share` ↔ `/host` в госте.
- CA-сертификаты хоста автоматически прокидываются внутрь (корпоративные TLS-прокси).

## Быстрый старт

Публичный репозиторий:

```sh
curl -fsSLO https://github.com/OWNER/pocket-linux/releases/latest/download/pocket && chmod +x pocket
POCKET_REPO=OWNER/pocket-linux ./pocket up      # скачает ~200 МБ, загрузит VM
./pocket ssh                                     # вы внутри, root
```

Приватный репозиторий — нужен токен (fine-grained, `Contents: read` на этот репо):

```sh
export GH_TOKEN=github_pat_xxx POCKET_REPO=OWNER/pocket-linux
curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/$POCKET_REPO/contents/pocket -o pocket && chmod +x pocket
./pocket up
```

Рабочий стол:

```sh
POCKET_VARIANT=desktop ./pocket up
# браузер: http://localhost:6080/vnc.html   или VNC-клиент: localhost:5901
```

С удалённой машины пробросьте порт: `ssh -L 6080:localhost:6080 user@remote`.

## Команды

| команда | что делает |
|---|---|
| `pocket up` | скачать (если нужно) и запустить VM в фоне |
| `pocket ssh [cmd]` | зайти внутрь или выполнить команду |
| `pocket down` | выключить |
| `pocket run` | запустить на переднем плане с консолью (выход `Ctrl-A X`) |
| `pocket desktop` | поднять XFCE + noVNC (вариант desktop) |
| `pocket status` / `log` | состояние / последние строки консоли |
| `pocket reset` | вернуть диск к исходному образу |

## Настройки (переменные окружения)

| переменная | по умолчанию | |
|---|---|---|
| `POCKET_VARIANT` | `base` | `base` (Docker, SSH) или `desktop` (+ XFCE/noVNC) |
| `POCKET_MEM` | `2048` | МБ RAM |
| `POCKET_CPUS` | `auto` (≤4) | vCPU; в TCG каждый vCPU — отдельный поток хоста |
| `POCKET_DISK` | `20G` | максимальный размер диска (растёт по мере записи) |
| `POCKET_PORTS` | — | доп. пробросы: `"8080:80 3000"` → `127.0.0.1:8080→:80`, `3000→3000` |
| `POCKET_ACCEL` | `auto` | `kvm` / `tcg` принудительно |
| `POCKET_SSH_PORT` | `2222` | порт SSH на хосте |
| `POCKET_GUEST` | = арх. хоста | архитектура VM (чужая → только эмуляция) |
| `POCKET_HOME` | `~/.pocket` | где лежат образы и диски |
| `POCKET_SHARE` | `~/.pocket/share` | папка, видимая в госте как `/host` |
| `POCKET_TAG` | `latest` | версия релиза |
| `POCKET_URL` | GitHub Releases | свой адрес с файлами (зеркало, локальный HTTP) |
| `GH_TOKEN` | — | токен для приватного репо |

Хук: исполняемый `~/.pocket/share/.pocket/on-boot.sh` выполняется в госте при каждой загрузке.

## Сборка (воспроизводимая, в Docker)

Нужны только Docker с buildx. Root на целевых машинах не нужен никогда.

```sh
./make.sh --arch x86_64  --variant all      # → dist/x86_64/
./make.sh --arch aarch64 --variant base     # чужая арх. — через qemu-user binfmt (медленно)
./make.sh --arch x86_64 --guest aarch64     # QEMU для x86-хоста, эмулирующий ARM-гостя
./make.sh --dynamic                         # не статически: bin/ + lib/ + свой загрузчик
```

Результат `dist/<arch>/`:

```
pocket                          лаунчер (POSIX sh)
qemu-<host>-<guest>.tar.gz      статический qemu-system-<guest> + qemu-img + прошивки
vmlinuz-<guest>, initramfs-<guest>
pocket-base-<guest>.qcow2       образ диска (сжатый)
pocket-desktop-<guest>.qcow2
SHA256SUMS-<arch>
```

Всё тяжёлое (пакеты, рабочий стол) ставится при сборке нативно, а не внутри медленной VM.
Если сборка идёт за корпоративным TLS-прокси, `make.sh` сам передаёт CA хоста
в сборку через build secret (отключается `--no-host-ca`).

### CI / релизы

`.github/workflows/build.yml` собирает x86_64 и aarch64 на нативных раннерах.
Push тега `v*` → GitHub Release со всеми файлами. Ручной запуск — `workflow_dispatch`.
Для приватных репозиториев раннеры `ubuntu-24.04-arm` могут быть недоступны на вашем плане —
тогда уберите строку aarch64 или соберите его локально.

## Производительность

Замеры на 1 vCPU без KVM (подробнее — `docs/RESEARCH.md`). Время в мс, меньше — лучше.

| тест | хост | QEMU TCG | 
|---|---|---|
| gzip 20 МБ | 780 | 4686 |
| 300 fork+exec | 264 | 4548 |
| запись 200 МБ | 286 | 2819 |
| старт Docker-контейнера | — | ~8000 |
| загрузка до SSH | — | ~110 с |

Практически: интерактивная работа, `apk add`, git, лёгкие контейнеры — нормально.
Сборки больших проектов и тяжёлые контейнеры — медленно. С KVM всё близко к нативу.

## Безопасность

SSH слушает только `127.0.0.1`, но на общей машине туда могут подключиться другие
пользователи, поэтому вход только по ключу (`~/.pocket/id_ed25519`), пароль root отключён.
Проброшенные через `POCKET_PORTS` сервисы (и noVNC в desktop-варианте, он без пароля)
доступны всем локальным пользователям хоста.

## Ограничения

- Хост — только Linux (x86_64 / aarch64 / riscv64). macOS/Windows — не цель (там свои гипервизоры).
- Без KVM всё медленное; это цена «работает где угодно».
- Если в госте не работает DNS/сеть — проверьте, что хосту разрешены исходящие соединения;
  slirp использует обычные сокеты процесса.
