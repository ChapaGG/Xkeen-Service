#!/bin/sh
# xkeen-service.sh - Управление бэкапами и обновлением конфигурации XKeen (jameszeroX/XKeen)
# Расположение: /opt/sbin/xkeen-service.sh (симлинк: /opt/sbin/xkeen-service, /opt/bin/xkeen-service)
# Настройки:   /opt/etc/xkeen/xkeen-service.json
# Установка:   curl -Ls https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main/setup.sh | sh
#
# Скрипт рассчитан на форк XKeen (https://github.com/jameszeroX/XKeen) и управляет
# им через штатный бинарник xkeen (xkeen -start/-stop/-restart/-status).
#
# Запуск без аргументов в интерактивном терминале открывает меню. Флаги
# (-b, -u, -restart, ...) по-прежнему работают напрямую, без меню - это нужно
# для cron и скриптов.

VERSION="1.3.0"

# ------------------------- НАСТРОЙКИ -------------------------
BACKUP_DIR="/opt/backups"
LOG_FILE="${BACKUP_DIR}/xkeen-service.log"
CONFIG_FILE="/opt/etc/xkeen/xkeen-service.json"

REPO_SCRIPTS="https://github.com/ChapaGG/Xkeen-Service"
SELF_RAW="https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main/xkeen-service.sh"

# Источник обновляемых конфигов (config.yaml, *.lst)
REPO_CONFIG_OWNER="ChapaGG"
REPO_CONFIG_REPO="Mihomo"
REPO_CONFIG_BRANCH="main"
REPO_CONFIG_RAW="https://raw.githubusercontent.com/${REPO_CONFIG_OWNER}/${REPO_CONFIG_REPO}/${REPO_CONFIG_BRANCH}"
REPO_CONFIG_API="https://api.github.com/repos/${REPO_CONFIG_OWNER}/${REPO_CONFIG_REPO}/commits/${REPO_CONFIG_BRANCH}"

TMP_DIR="/tmp/xkeen-service_$$"

# --- Каталоги/файлы XKeen (структура форка jameszeroX/XKeen) ---
XKEEN_CFG_DIR="/opt/etc/xkeen"                 # xkeen.json, *_exclude.lst, port_proxying.lst
CONFIG_MIHOMO_DIR="/opt/etc/mihomo"            # config.yaml (и прочее, если есть)
CONFIG_MIHOMO="${CONFIG_MIHOMO_DIR}/config.yaml"
LST_IP_EXCLUDE="${XKEEN_CFG_DIR}/ip_exclude.lst"
LST_PORT_EXCLUDE="${XKEEN_CFG_DIR}/port_exclude.lst"
LST_PORT_PROXYING="${XKEEN_CFG_DIR}/port_proxying.lst"
# xkeen.json временно НЕ управляется этим скриптом (обновление отключено по
# просьбе пользователя - планируется вернуть в одной из следующих версий).
XKEEN_JSON="${XKEEN_CFG_DIR}/xkeen.json"

# Манифест версий конфигов - сюда пишем "что и когда обновилось".
CONFIG_STATE_FILE="${XKEEN_CFG_DIR}/.xkeen-service-config-state.json"

# Бинарь XKeen (обычно доступен как xkeen через /opt/sbin или /opt/bin в PATH)
XKEEN_BIN="xkeen"

INSTALL_PATH="/opt/sbin/xkeen-service.sh"
LINK_PATH_SBIN="/opt/sbin/xkeen-service"
LINK_PATH_BIN="/opt/bin/xkeen-service"

# Флаг: были ли реально изменены конфиги при последнем update_configs (0/1).
CONFIGS_CHANGED=0

# ---------- ЦВЕТА / СИМВОЛЫ -----------------------------------------------
# ВАЖНО: цвета "запекаются" через printf в переменные (а не интерпретируются
# на лету через `echo -e`), потому что `echo -e` - башизм и не гарантированно
# работает под /bin/sh (dash/ash без соответствующей опции). Если полагаться
# на `echo -e`, на части прошивок в терминале вместо цвета видны сырые
# последовательности вида \033[1;32m - собственно то, что вы наблюдали.
# Здесь же escape-байт уже "зашит" в переменную на этапе присвоения через
# printf (который интерпретирует \033 по стандарту POSIX всегда), поэтому
# дальше используется обычный `echo`/`printf '%s'` без каких-либо -e/-b флагов.
RED=$(printf '\033[1;31m')
GREEN=$(printf '\033[1;32m')
YELLOW=$(printf '\033[1;33m')
CYAN=$(printf '\033[1;36m')
WHITE=$(printf '\033[1;37m')
GRAY=$(printf '\033[0;90m')
NC=$(printf '\033[0m')
OK_SYM="[+]"
FAIL_SYM="[-]"
INFO_SYM="[i]"
WARN_SYM="[!]"
BAR="────────────────────────────────────────────"

HAS_TTY=0
[ -r /dev/tty ] && [ -w /dev/tty ] && HAS_TTY=1

read_tty() {
    local prompt="$1"
    local answer=""
    if [ "$HAS_TTY" -eq 1 ]; then
        printf "%s" "$prompt" >&2
        IFS= read -r answer < /dev/tty || answer=""
        echo "$answer"
    else
        echo ""
    fi
}

# ------------------------- ВРЕМЯ (МСК) -------------------------
# Москва с 2014 года не переходит на летнее/зимнее время, поэтому
# фиксированный офсет UTC+3 через POSIX-строку TZ безопасен и не требует
# наличия базы часовых поясов (zoneinfo) на роутере.
moscow_now() {   # для заголовков файлов и манифеста: 2026-09-18_14:32
    TZ='MSK-3' date '+%Y-%m-%d_%H:%M'
}
moscow_ts() {    # для имён файлов бэкапов: 20260918_140532
    TZ='MSK-3' date '+%Y%m%d_%H%M%S'
}
moscow_day() {   # для каталога бэкапов за день: 2026_09_18
    TZ='MSK-3' date '+%Y_%m_%d'
}

# ------------------------- ФУНКЦИИ ВЫВОДА -------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"
    echo "$*"
}

success() {
    printf "\033[32m%s\033[0m\n" "$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"
}

error() {
    printf "\033[31m%s\033[0m\n" "$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $*" >> "$LOG_FILE"
}

warn() {
    printf "\033[33m%s\033[0m\n" "$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARN: $*" >> "$LOG_FILE"
}

ensure_backup_dir() {
    [ -d "$BACKUP_DIR" ] || mkdir -p "$BACKUP_DIR"
}

# Создаёт (при необходимости) файл настроек и поддерживает в нём актуальными
# служебные, не редактируемые пользователем поля: версию скрипта и репозиторий
# конфигов. Поле backup_retention - пользовательское, трогаем только если его
# ещё нет (задаём дефолт 5 и не перезаписываем при последующих запусках).
ensure_config() {
    local cfg_dir
    cfg_dir=$(dirname "$CONFIG_FILE")
    [ -d "$cfg_dir" ] || mkdir -p "$cfg_dir"
    if [ ! -f "$CONFIG_FILE" ]; then
        printf '{}\n' > "$CONFIG_FILE"
        log "Создан файл настроек: $CONFIG_FILE"
    fi

    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="${CONFIG_FILE}.tmp.$$"
        if jq --arg v "$VERSION" \
              --arg owner "$REPO_CONFIG_OWNER" \
              --arg repo "$REPO_CONFIG_REPO" \
              --arg branch "$REPO_CONFIG_BRANCH" \
              '.script_version = $v
               | .config_repo = {owner:$owner, repo:$repo, branch:$branch}
               | .backup_retention = (.backup_retention // 5)' \
              "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$CONFIG_FILE"
        else
            rm -f "$tmp"
            warn "Не удалось обновить служебные поля в $CONFIG_FILE (jq вернул ошибку)"
        fi
    fi
}

cfg_get() {
    local key="$1"
    local default="$2"
    if command -v jq >/dev/null 2>&1 && [ -s "$CONFIG_FILE" ]; then
        local val
        val=$(jq -r --arg k "$key" '.[$k] // empty' "$CONFIG_FILE" 2>/dev/null)
        [ -n "$val" ] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

# ------------------------- БЭКАПЫ -------------------------
# Каждый запуск -b кладёт архивы в датированный подкаталог BACKUP_DIR/YYYY_MM_DD
# (время - МСК), а не вперемешку в один общий каталог. После бэкапа лишние
# датированные каталоги (старше backup_retention штук, по умолчанию 5)
# удаляются через prune_old_backups().
#
# Бэкап Xray сюда намеренно НЕ входит - отключён по просьбе пользователя,
# планируется в одной из следующих версий.

backup_run_dir() {
    local d dir
    d=$(moscow_day)
    dir="${BACKUP_DIR}/${d}"
    mkdir -p "$dir"
    echo "$dir"
}

backup_xkeen() {
    if [ ! -d "$XKEEN_CFG_DIR" ]; then
        warn "Каталог $XKEEN_CFG_DIR не найден - пропуск бэкапа XKeen"
        return 0
    fi
    local dir ts archive
    dir=$(backup_run_dir)
    log "Создание бэкапа конфигурации XKeen ($XKEEN_CFG_DIR)..."
    ts=$(moscow_ts)
    archive="${dir}/xkeen_backup_${ts}.tar.gz"
    tar -czf "$archive" -C "$XKEEN_CFG_DIR" . 2>/dev/null || {
        error "Ошибка при создании бэкапа XKeen"
        return 1
    }
    success "Бэкап XKeen сохранён: $archive"
}

backup_mihomo() {
    if [ ! -d "$CONFIG_MIHOMO_DIR" ]; then
        warn "Каталог $CONFIG_MIHOMO_DIR не найден - ядро Mihomo не установлено или не сконфигурировано, пропуск"
        return 0
    fi
    local dir ts archive
    dir=$(backup_run_dir)
    log "Создание бэкапа конфигурации Mihomo ($CONFIG_MIHOMO_DIR)..."
    ts=$(moscow_ts)
    archive="${dir}/mihomo_backup_${ts}.tar.gz"
    tar -czf "$archive" -C "$CONFIG_MIHOMO_DIR" . 2>/dev/null || {
        error "Ошибка при создании бэкапа Mihomo"
        return 1
    }
    success "Бэкап Mihomo сохранён: $archive"
}

# Прошивка Keenetic: ndmc понимает только свои виртуальные ФС (flash:, temp:,
# running-config...) и не умеет копировать напрямую в /opt/... - именно
# поэтому раньше падало с "unknown filesystem". Правильный путь: скопировать
# во временную зону KeenetOS (temp:, которая маппится в /tmp), а затем уже
# средствами Entware перенести файл в наш архивный каталог.
backup_firmware() {
    local dir ts tmp_name
    dir=$(backup_run_dir)
    ts=$(moscow_ts)
    tmp_name="firmware_${ts}.bin"
    log "Создание бэкапа прошивки Keenetic..."
    if ! ndmc -c "copy flash:/firmware temp:/${tmp_name}" 2>/dev/null; then
        error "Ошибка при копировании прошивки во временную область KeenetOS (temp:), возможно ndmc недоступен"
        return 1
    fi
    if [ -f "/tmp/${tmp_name}" ]; then
        mv "/tmp/${tmp_name}" "${dir}/${tmp_name}"
        success "Бэкап прошивки сохранён: ${dir}/${tmp_name}"
    else
        error "Файл ${tmp_name} не найден в /tmp после copy temp: (на вашем устройстве temp: может маппиться в другой каталог)"
        return 1
    fi
}

# startup-config: сначала штатно persist-им running-config в startup-config
# на самом устройстве (аналог "write memory"), а текстовую копию для архива
# снимаем перенаправлением вывода "show running-config" в файл - это обходит
# то же ограничение виртуальной ФС ndmc, что и с прошивкой.
backup_startup_config() {
    local dir ts dest
    dir=$(backup_run_dir)
    ts=$(moscow_ts)

    log "Сохранение running-config в startup-config на устройстве..."
    ndmc -c "copy running-config startup-config" 2>/dev/null || \
        warn "Не удалось сохранить running-config в startup-config на устройстве (текстовый бэкап всё равно будет снят)"

    log "Снятие текстового бэкапа running-config..."
    dest="${dir}/running-config_${ts}.txt"
    if ndmc -c "show running-config" > "$dest" 2>/dev/null && [ -s "$dest" ]; then
        success "Бэкап running-config сохранён: $dest"
    else
        rm -f "$dest"
        error "Не удалось сохранить running-config в $dest"
        return 1
    fi
}

prune_old_backups() {
    local retention old_dirs
    retention=$(cfg_get "backup_retention" "5")
    case "$retention" in ''|*[!0-9]*) retention=5 ;; esac

    old_dirs=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]_[0-9][0-9]_[0-9][0-9]' 2>/dev/null | sort -r | tail -n +$((retention + 1)))
    if [ -n "$old_dirs" ]; then
        echo "$old_dirs" | while IFS= read -r d; do
            [ -n "$d" ] && rm -rf "$d" && log "Удалён устаревший бэкап: $d"
        done
        success "Ротация бэкапов: хранится последних ${retention}"
    else
        log "Ротация бэкапов: удалять нечего (каталогов <= ${retention})"
    fi
}

backup_all() {
    backup_xkeen
    backup_mihomo
    backup_firmware
    backup_startup_config
    prune_old_backups
}

# ------------------------- ВЕРСИОНИРОВАНИЕ КОНФИГОВ -------------------------
# В сам конфиг (первой строкой, # xkeen-service: ...) пишем метку версии -
# это нужно, чтобы при просмотре файла через веб-интерфейс XKeen-UI сразу
# было видно, когда он последний раз обновлялся и из какого коммита.
# Отдельно, в CONFIG_STATE_FILE, дублируем то же самое в машиночитаемом виде
# (JSON, sha256 по каждому файлу) - для скриптов/мониторинга.
#
# Чтобы наша же строка-заголовок не портила сравнение "изменился ли конфиг
# по сути", при детекте изменений хэшируется содержимое БЕЗ первой строки.

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    else
        echo "unavailable"
    fi
}

hash_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 | awk '{print $NF}'
    else
        echo "unavailable"
    fi
}

# sha256 существующего файла без нашей служебной первой строки (если она есть)
content_hash_no_header() {
    local file="$1"
    if [ -f "$file" ]; then
        if head -n1 "$file" 2>/dev/null | grep -q '^# xkeen-service:'; then
            tail -n +2 "$file" | hash_stream
        else
            hash_file "$file"
        fi
    else
        echo "none"
    fi
}

get_upstream_commit() {
    local sha
    if command -v jq >/dev/null 2>&1; then
        sha=$(curl -fsSL "$REPO_CONFIG_API" 2>/dev/null | jq -r '.sha // empty' 2>/dev/null)
    else
        sha=$(curl -fsSL "$REPO_CONFIG_API" 2>/dev/null | sed -n 's/.*"sha": *"\([a-f0-9]\{7,40\}\)".*/\1/p' | head -n1)
    fi
    [ -n "$sha" ] && echo "$sha" || echo "unknown"
}

show_config_state() {
    if [ -f "$CONFIG_STATE_FILE" ]; then
        echo "Манифест версий конфигов: $CONFIG_STATE_FILE"
        echo "----------------------------------------"
        cat "$CONFIG_STATE_FILE"
        echo "----------------------------------------"
    else
        warn "Манифест ещё не создан (конфиги ни разу не обновлялись через -u): $CONFIG_STATE_FILE"
    fi
}

# ------------------------- ОБНОВЛЕНИЕ КОНФИГОВ -------------------------

update_configs() {
    log "Обновление конфигураций из ${REPO_CONFIG_RAW}..."
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"

    # xkeen.json временно не обновляется - см. комментарий у XKEEN_JSON выше
    local files="config.yaml port_proxying.lst port_exclude.lst ip_exclude.lst"
    for f in $files; do
        local url="${REPO_CONFIG_RAW}/$f"
        if ! curl -fsSL "$url" -o "${TMP_DIR}/$f"; then
            error "Не удалось скачать $f"
            rm -rf "$TMP_DIR"
            return 1
        fi
    done

    mkdir -p "$CONFIG_MIHOMO_DIR" "$XKEEN_CFG_DIR"

    # Детект реальных изменений (без учёта нашей служебной строки-заголовка)
    CONFIGS_CHANGED=0
    local new_hash old_hash target
    for f in $files; do
        case "$f" in
            config.yaml)        target="$CONFIG_MIHOMO" ;;
            port_proxying.lst)  target="$LST_PORT_PROXYING" ;;
            port_exclude.lst)   target="$LST_PORT_EXCLUDE" ;;
            ip_exclude.lst)     target="$LST_IP_EXCLUDE" ;;
        esac
        new_hash=$(hash_file "${TMP_DIR}/$f")
        old_hash=$(content_hash_no_header "$target")
        [ "$new_hash" != "$old_hash" ] && CONFIGS_CHANGED=1
    done

    local commit commit_short header_line
    commit=$(get_upstream_commit)
    commit_short="$commit"
    [ "$commit" != "unknown" ] && commit_short=$(echo "$commit" | cut -c1-7)
    header_line="# xkeen-service: updated $(moscow_now) MSK | source ${REPO_CONFIG_OWNER}/${REPO_CONFIG_REPO}@${REPO_CONFIG_BRANCH}#${commit_short}"

    for f in $files; do
        { echo "$header_line"; cat "${TMP_DIR}/$f"; } > "${TMP_DIR}/hdr_$f"
        mv "${TMP_DIR}/hdr_$f" "${TMP_DIR}/$f"
    done

    local ok=1
    cp "${TMP_DIR}/config.yaml" "$CONFIG_MIHOMO" || ok=0
    cp "${TMP_DIR}/ip_exclude.lst" "$LST_IP_EXCLUDE" || ok=0
    cp "${TMP_DIR}/port_exclude.lst" "$LST_PORT_EXCLUDE" || ok=0
    cp "${TMP_DIR}/port_proxying.lst" "$LST_PORT_PROXYING" || ok=0

    if [ "$ok" -ne 1 ]; then
        rm -rf "$TMP_DIR"
        error "Не все конфигурационные файлы удалось скопировать - проверьте лог"
        return 1
    fi

    cat > "$CONFIG_STATE_FILE" <<EOF
{
  "updated_at": "$(moscow_now)",
  "timezone": "MSK",
  "source_repo": "${REPO_CONFIG_OWNER}/${REPO_CONFIG_REPO}",
  "source_branch": "${REPO_CONFIG_BRANCH}",
  "source_commit": "${commit}",
  "changed": $( [ "$CONFIGS_CHANGED" -eq 1 ] && echo true || echo false ),
  "files": {
    "config.yaml": { "sha256": "$(hash_file "$CONFIG_MIHOMO")" },
    "port_proxying.lst": { "sha256": "$(hash_file "$LST_PORT_PROXYING")" },
    "port_exclude.lst": { "sha256": "$(hash_file "$LST_PORT_EXCLUDE")" },
    "ip_exclude.lst": { "sha256": "$(hash_file "$LST_IP_EXCLUDE")" }
  }
}
EOF

    rm -rf "$TMP_DIR"

    if [ "$CONFIGS_CHANGED" -eq 1 ]; then
        success "Конфигурационные файлы обновлены (commit ${commit_short})"
    else
        log "Конфигурационные файлы актуальны, изменений нет (commit ${commit_short})"
    fi
    return 0
}

# ------------------------- УПРАВЛЕНИЕ XKEEN -------------------------

check_xkeen_bin() {
    if ! command -v "$XKEEN_BIN" >/dev/null 2>&1; then
        error "Бинарник '$XKEEN_BIN' не найден в PATH. Проверьте установку XKeen (jameszeroX/XKeen)."
        return 1
    fi
    return 0
}

restart_xkeen() {
    check_xkeen_bin || return 1
    log "Перезапуск XKeen (xkeen -restart)..."
    if "$XKEEN_BIN" -restart >>"$LOG_FILE" 2>&1; then
        sleep 2
        local status_out
        status_out=$("$XKEEN_BIN" -status 2>&1)
        log "Статус XKeen: $status_out"
        success "XKeen перезапущен."
    else
        error "Команда 'xkeen -restart' завершилась с ошибкой. Смотрите лог и вывод 'xkeen -status'."
        "$XKEEN_BIN" -status >>"$LOG_FILE" 2>&1
        return 1
    fi
}

start_xkeen() {
    check_xkeen_bin || return 1
    log "Запуск XKeen (xkeen -start)..."
    if "$XKEEN_BIN" -start >>"$LOG_FILE" 2>&1; then
        success "XKeen запущен."
    else
        error "Не удалось запустить XKeen ('xkeen -start')."
        return 1
    fi
}

stop_xkeen() {
    check_xkeen_bin || return 1
    log "Остановка XKeen (xkeen -stop)..."
    if "$XKEEN_BIN" -stop >>"$LOG_FILE" 2>&1; then
        success "XKeen остановлен."
    else
        error "Не удалось остановить XKeen ('xkeen -stop')."
        return 1
    fi
}

status_xkeen() {
    check_xkeen_bin || return 1
    "$XKEEN_BIN" -status
}

update_and_restart() {
    if update_configs; then
        if [ "$CONFIGS_CHANGED" -eq 1 ]; then
            restart_xkeen
        else
            log "Изменений в конфигах нет - перезапуск XKeen не требуется"
        fi
    fi
}

show_cron() {
    log "Текущие задания cron:"
    crontab -l 2>/dev/null || echo "Нет заданий cron"
}

add_cron_update() {
    log "Добавление задания cron для обновления конфигурации..."
    local cron_job="0 4 * * * /opt/sbin/xkeen-service -u >/dev/null 2>&1"
    if crontab -l 2>/dev/null | grep -q "xkeen-service -u"; then
        error "Задание уже существует в cron"
    else
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        success "Задание добавлено: $cron_job"
    fi
}

self_update() {
    log "Обновление самого скрипта xkeen-service.sh из ${REPO_SCRIPTS}..."
    local tmp_self="/tmp/xkeen-service.sh.update.$$"
    if ! curl -fsSL "$SELF_RAW" -o "$tmp_self"; then
        error "Не удалось скачать обновление xkeen-service.sh"
        return 1
    fi
    chmod +x "$tmp_self"
    mv "$tmp_self" "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" "$LINK_PATH_SBIN" 2>/dev/null || true
    ln -sf "$INSTALL_PATH" "$LINK_PATH_BIN" 2>/dev/null || true
    success "xkeen-service обновлён до последней версии."
}

show_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "Файл настроек: $CONFIG_FILE"
        echo "----------------------------------------"
        cat "$CONFIG_FILE"
        echo "----------------------------------------"
    else
        error "Файл настроек не найден: $CONFIG_FILE"
    fi
}

show_version() {
    echo "xkeen-service v${VERSION}"
}

show_help() {
    cat <<EOF
Использование: xkeen-service [ОПЦИЯ]
               xkeen-service.sh [ОПЦИЯ]
               xkeen-service               # без аргументов в SSH - интерактивное меню

Опции:
  -b        Создать бэкапы (XKeen, Mihomo, прошивка, running-config) в датированный каталог + ротация
  -u        Обновить конфигурации из GitHub и перезапустить XKeen (только если что-то изменилось)
  -start    Запустить XKeen (xkeen -start)
  -stop     Остановить XKeen (xkeen -stop)
  -restart  Перезапустить XKeen (xkeen -restart)
  -status   Показать статус XKeen (xkeen -status)
  -c        Показать текущие задания cron
  -a        Добавить задание cron для ежедневного обновления в 4:00
  -s        Обновить сам скрипт xkeen-service до последней версии
  -cfg      Показать содержимое файла настроек
  -cfgstate Показать манифест версий конфигов (дата МСК/коммит/sha256)
  -m        Открыть интерактивное меню
  -v        Показать версию скрипта
  -h        Показать эту справку

Файлы:
  Настройки:       ${CONFIG_FILE}
  Лог:             ${LOG_FILE}
  Бэкапы:          ${BACKUP_DIR}/<YYYY_MM_DD>/
  Конфиг XKeen:    ${XKEEN_CFG_DIR}
  Конфиг Mihomo:   ${CONFIG_MIHOMO_DIR}
  Манифест версий: ${CONFIG_STATE_FILE}

Примеры:
  xkeen-service -b          # Сделать бэкап (с ротацией по backup_retention из настроек)
  xkeen-service -u          # Обновить конфиги и перезапустить XKeen при изменениях
  xkeen-service -status     # Посмотреть статус XKeen
  xkeen-service -a          # Добавить автообновление в cron
  xkeen-service -cfgstate   # Посмотреть версию/коммит текущих конфигов
EOF
}

# ------------------------- ИНТЕРАКТИВНОЕ МЕНЮ -------------------------

get_menu_status() {
    if command -v "$XKEEN_BIN" >/dev/null 2>&1; then
        MENU_XKEEN_BIN_FOUND=1
    else
        MENU_XKEEN_BIN_FOUND=0
    fi

    if crontab -l 2>/dev/null | grep -q "xkeen-service -u"; then
        MENU_CRON_ACTIVE=1
    else
        MENU_CRON_ACTIVE=0
    fi

    MENU_LAST_BACKUP_DIR=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]_[0-9][0-9]_[0-9][0-9]' 2>/dev/null | sort -r | head -n1)
    [ -n "$MENU_LAST_BACKUP_DIR" ] && MENU_LAST_BACKUP_DIR=$(basename "$MENU_LAST_BACKUP_DIR")

    if [ -f "$CONFIG_STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
        MENU_CFG_UPDATED_AT=$(jq -r '.updated_at // empty' "$CONFIG_STATE_FILE" 2>/dev/null)
        MENU_CFG_COMMIT=$(jq -r '.source_commit // empty' "$CONFIG_STATE_FILE" 2>/dev/null | cut -c1-7)
    else
        MENU_CFG_UPDATED_AT=""
        MENU_CFG_COMMIT=""
    fi

    MENU_RETENTION=$(cfg_get "backup_retention" "5")
}

show_menu() {
    get_menu_status
    clear 2>/dev/null || true
    echo ""
    echo "${CYAN}   XKEEN-SERVICE${NC}  ${GRAY}v${VERSION}${NC}"
    echo "${GRAY}   ${BAR}${NC}"

    if [ "$MENU_XKEEN_BIN_FOUND" -eq 1 ]; then
        echo "   ${GREEN}${OK_SYM}${NC} Бинарник xkeen найден в PATH"
    else
        echo "   ${RED}${FAIL_SYM}${NC} Бинарник xkeen НЕ найден в PATH"
    fi

    if [ "$MENU_CRON_ACTIVE" -eq 1 ]; then
        echo "   ${GREEN}${OK_SYM}${NC} Cron:            ${GRAY}автообновление активно${NC}"
    else
        echo "   ${YELLOW}${WARN_SYM}${NC} Cron:            ${GRAY}не активно${NC}"
    fi

    if [ -n "$MENU_LAST_BACKUP_DIR" ]; then
        echo "   ${GREEN}${OK_SYM}${NC} Последний бэкап: ${GRAY}${MENU_LAST_BACKUP_DIR} (хранится последних ${MENU_RETENTION})${NC}"
    else
        echo "   ${YELLOW}${WARN_SYM}${NC} Последний бэкап: ${GRAY}нет${NC}"
    fi

    if [ -n "$MENU_CFG_UPDATED_AT" ]; then
        echo "   ${GREEN}${OK_SYM}${NC} Конфиги:         ${GRAY}${MENU_CFG_UPDATED_AT} МСК (commit ${MENU_CFG_COMMIT})${NC}"
    else
        echo "   ${YELLOW}${WARN_SYM}${NC} Конфиги:         ${GRAY}манифест не создан${NC}"
    fi

    echo "${GRAY}   ${BAR}${NC}"
    echo ""
    echo "   ${WHITE}1)${NC}  Создать бэкапы (XKeen/Mihomo/прошивка/running-config)"
    echo "   ${WHITE}2)${NC}  Обновить конфиги и перезапустить XKeen"
    echo "   ${WHITE}3)${NC}  Запустить XKeen"
    echo "   ${WHITE}4)${NC}  Остановить XKeen"
    echo "   ${WHITE}5)${NC}  Перезапустить XKeen"
    echo "   ${WHITE}6)${NC}  Статус XKeen"
    echo "   ${WHITE}7)${NC}  Показать cron"
    echo "   ${WHITE}8)${NC}  Добавить автообновление в cron"
    echo "   ${WHITE}9)${NC}  Обновить сам xkeen-service"
    echo "  ${WHITE}10)${NC}  Показать манифест версий конфигов"
    echo "   ${WHITE}0)${NC}  Выход"
    echo ""
    echo "${GRAY}   ${BAR}${NC}"
    echo ""
}

pause_return() {
    if [ "$HAS_TTY" -eq 1 ]; then
        printf "\n   %sНажмите Enter для возврата в меню...%s" "$GRAY" "$NC"
        IFS= read -r _ < /dev/tty || true
    fi
}

main_menu() {
    local choice
    while :; do
        show_menu
        choice=$(read_tty "   ${WHITE}Выберите пункт [0-10]:${NC} ")
        # Сразу очищаем экран после выбора - старое меню и введённый пункт
        # не остаются на экране вместе с результатом действия
        clear 2>/dev/null || true
        case "$choice" in
            1)  backup_all;          pause_return ;;
            2)  update_and_restart;  pause_return ;;
            3)  start_xkeen;         pause_return ;;
            4)  stop_xkeen;          pause_return ;;
            5)  restart_xkeen;       pause_return ;;
            6)  status_xkeen;        pause_return ;;
            7)  show_cron;           pause_return ;;
            8)  add_cron_update;     pause_return ;;
            9)  self_update;         pause_return ;;
            10) show_config_state;   pause_return ;;
            0|"") printf "  %s%s%s Выход.\n" "$CYAN" "$INFO_SYM" "$NC"; exit 0 ;;
            *) printf "  %s%s%s Неверный пункт: %s\n" "$YELLOW" "$WARN_SYM" "$NC" "$choice"; sleep 1 ;;
        esac
    done
}

# ------------------------- ОСНОВНАЯ ЛОГИКА -------------------------
ensure_backup_dir
ensure_config

case "$1" in
    -b)
        backup_all
        ;;
    -u)
        update_and_restart
        ;;
    -start)
        start_xkeen
        ;;
    -stop)
        stop_xkeen
        ;;
    -restart)
        restart_xkeen
        ;;
    -status)
        status_xkeen
        ;;
    -c)
        show_cron
        ;;
    -a)
        add_cron_update
        ;;
    -s)
        self_update
        ;;
    -cfg)
        show_config
        ;;
    -cfgstate)
        show_config_state
        ;;
    -m)
        main_menu
        ;;
    -v)
        show_version
        ;;
    -h)
        show_help
        ;;
    "")
        if [ "$HAS_TTY" -eq 1 ]; then
            main_menu
        else
            show_help
        fi
        ;;
    *)
        show_help
        ;;
esac

exit 0
