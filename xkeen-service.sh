#!/bin/sh
# xkeen-service.sh - Управление бэкапами и обновлением конфигурации XKeen (jameszeroX/XKeen)
# Расположение: /opt/sbin/xkeen-service.sh (симлинк: /opt/sbin/xkeen-service, /opt/bin/xkeen-service)
# Настройки:   /opt/etc/xkeen/xkeen-service.json
# Установка:   curl -Ls https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main/setup.sh | sh
#
# Скрипт рассчитан на форк XKeen (https://github.com/jameszeroX/XKeen) и управляет
# им через штатный бинарник xkeen (xkeen -start/-stop/-restart/-status).
#
# Запуск без аргументов в интерактивном терминале открывает меню (как в setup.sh
# самого XKeen/XKeen-UI): экран перерисовывается при каждом действии, старый вывод
# не остаётся на экране. Флаги (-b, -u, -restart, ...) по-прежнему работают
# напрямую, без меню - это нужно для cron и скриптов.

VERSION="1.2.0"

# ------------------------- НАСТРОЙКИ -------------------------
BACKUP_DIR="/opt/backups"
LOG_FILE="${BACKUP_DIR}/xkeen-service.log"
CONFIG_FILE="/opt/etc/xkeen/xkeen-service.json"

REPO_SCRIPTS="https://github.com/ChapaGG/Xkeen-Service"
SELF_RAW="https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main/xkeen-service.sh"

# Источник обновляемых конфигов (config.yaml, xkeen.json, *.lst)
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
CONFIG_XRAY_DIR="/opt/etc/xray/config"         # 03_inbounds.json, 04_outbounds.json, 05_routing.json...
LST_IP_EXCLUDE="${XKEEN_CFG_DIR}/ip_exclude.lst"
LST_PORT_EXCLUDE="${XKEEN_CFG_DIR}/port_exclude.lst"
LST_PORT_PROXYING="${XKEEN_CFG_DIR}/port_proxying.lst"
XKEEN_JSON="${XKEEN_CFG_DIR}/xkeen.json"

# Манифест версий конфигов - сюда пишем "что и когда обновилось" вместо
# комментария "Обновлено: <дата>" внутри самих файлов (см. update_configs).
CONFIG_STATE_FILE="${XKEEN_CFG_DIR}/.xkeen-service-config-state.json"

# Бинарь XKeen (обычно доступен как xkeen через /opt/sbin или /opt/bin в PATH)
XKEEN_BIN="xkeen"

INSTALL_PATH="/opt/sbin/xkeen-service.sh"
LINK_PATH_SBIN="/opt/sbin/xkeen-service"
LINK_PATH_BIN="/opt/bin/xkeen-service"

# Флаг: были ли реально изменены конфиги при последнем update_configs (0/1).
# Используется, чтобы не перезапускать XKeen впустую, если содержимое не менялось.
CONFIGS_CHANGED=0

# ---------- ЦВЕТА / СИМВОЛЫ (в стиле setup.sh) ----------
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
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

ensure_config() {
    local cfg_dir
    cfg_dir=$(dirname "$CONFIG_FILE")
    [ -d "$cfg_dir" ] || mkdir -p "$cfg_dir"
    if [ ! -f "$CONFIG_FILE" ]; then
        printf '{}\n' > "$CONFIG_FILE"
        log "Создан файл настроек: $CONFIG_FILE"
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
# Бэкапится только то, что реально нельзя переустановить одной командой:
# конфиги XKeen/Xray/Mihomo. Бинарники ядер и geodata-файлы (geosite/geoip)
# сюда намеренно не входят - они перекачиваются заново через xkeen/geodata-репозитории.

backup_xkeen() {
    if [ ! -d "$XKEEN_CFG_DIR" ]; then
        warn "Каталог $XKEEN_CFG_DIR не найден - пропуск бэкапа XKeen"
        return 0
    fi
    log "Создание бэкапа конфигурации XKeen ($XKEEN_CFG_DIR)..."
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local archive="${BACKUP_DIR}/xkeen_backup_${ts}.tar.gz"
    tar -czf "$archive" -C "$XKEEN_CFG_DIR" . 2>/dev/null || {
        error "Ошибка при создании бэкапа XKeen"
        return 1
    }
    success "Бэкап XKeen сохранён: $archive"
}

backup_xray() {
    if [ ! -d "$CONFIG_XRAY_DIR" ]; then
        warn "Каталог $CONFIG_XRAY_DIR не найден - ядро Xray не установлено или не сконфигурировано, пропуск"
        return 0
    fi
    log "Создание бэкапа конфигурации Xray ($CONFIG_XRAY_DIR)..."
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local archive="${BACKUP_DIR}/xray_backup_${ts}.tar.gz"
    tar -czf "$archive" -C "$CONFIG_XRAY_DIR" . 2>/dev/null || {
        error "Ошибка при создании бэкапа Xray"
        return 1
    }
    success "Бэкап Xray сохранён: $archive"
}

backup_mihomo() {
    if [ ! -d "$CONFIG_MIHOMO_DIR" ]; then
        warn "Каталог $CONFIG_MIHOMO_DIR не найден - ядро Mihomo не установлено или не сконфигурировано, пропуск"
        return 0
    fi
    log "Создание бэкапа конфигурации Mihomo ($CONFIG_MIHOMO_DIR)..."
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local archive="${BACKUP_DIR}/mihomo_backup_${ts}.tar.gz"
    tar -czf "$archive" -C "$CONFIG_MIHOMO_DIR" . 2>/dev/null || {
        error "Ошибка при создании бэкапа Mihomo"
        return 1
    }
    success "Бэкап Mihomo сохранён: $archive"
}

backup_firmware() {
    log "Создание бэкапа прошивки Keenetic..."
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local dest="${BACKUP_DIR}/firmware_${ts}.bin"
    ndmc -c "copy flash:/firmware $dest" 2>/dev/null || {
        error "Ошибка при создании бэкапа прошивки (возможно, ndmc недоступен)"
        return 1
    }
    success "Бэкап прошивки сохранён: $dest"
}

backup_startup_config() {
    log "Создание бэкапа startup-config..."
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local dest="${BACKUP_DIR}/startup-config_${ts}.txt"
    ndmc -c "copy running-config startup-config" 2>/dev/null || {
        error "Ошибка при сохранении running-config в startup-config"
        return 1
    }
    ndmc -c "copy startup-config $dest" 2>/dev/null || {
        error "Ошибка при копировании startup-config (возможно, путь недоступен)"
        return 1
    }
    success "Бэкап startup-config сохранён: $dest"
}

backup_all() {
    backup_xkeen
    backup_xray
    backup_mihomo
    backup_firmware
    backup_startup_config
}

# ------------------------- ВЕРСИОНИРОВАНИЕ КОНФИГОВ -------------------------
# Вместо строки "# Обновлено: <дата>" внутри самих конфигов (что ломает JSON
# и не несёт информации о том, ЧТО именно изменилось) - отдельный манифест
# CONFIG_STATE_FILE с меткой времени в UTC/ISO-8601, upstream-коммитом и
# sha256 каждого файла. Это даёт настоящую версию (привязанную к содержимому),
# а не просто дату последнего запуска скрипта.

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    else
        echo "unavailable"
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

    local files="config.yaml port_proxying.lst port_exclude.lst ip_exclude.lst xkeen.json"
    for f in $files; do
        local url="${REPO_CONFIG_RAW}/$f"
        if ! curl -fsSL "$url" -o "${TMP_DIR}/$f"; then
            error "Не удалось скачать $f"
            rm -rf "$TMP_DIR"
            return 1
        fi
    done

    # Убеждаемся, что целевые каталоги существуют (например, после чистой
    # установки XKeen без предварительной конфигурации Mihomo/Xray)
    mkdir -p "$CONFIG_MIHOMO_DIR" "$XKEEN_CFG_DIR"

    # Сравниваем хэши новых файлов со старыми ДО копирования - это даёт нам
    # флаг "реально что-то поменялось" (CONFIGS_CHANGED), чтобы не дёргать
    # XKeen перезапуском впустую, если апстрим не менялся с прошлого раза.
    CONFIGS_CHANGED=0
    local new_hash old_hash target
    for f in $files; do
        case "$f" in
            config.yaml)        target="$CONFIG_MIHOMO" ;;
            port_proxying.lst)  target="$LST_PORT_PROXYING" ;;
            port_exclude.lst)   target="$LST_PORT_EXCLUDE" ;;
            ip_exclude.lst)     target="$LST_IP_EXCLUDE" ;;
            xkeen.json)         target="$XKEEN_JSON" ;;
        esac
        new_hash=$(hash_file "${TMP_DIR}/$f")
        old_hash="none"
        [ -f "$target" ] && old_hash=$(hash_file "$target")
        if [ "$new_hash" != "$old_hash" ]; then
            CONFIGS_CHANGED=1
        fi
    done

    local ok=1
    cp "${TMP_DIR}/config.yaml" "$CONFIG_MIHOMO" || ok=0
    cp "${TMP_DIR}/ip_exclude.lst" "$LST_IP_EXCLUDE" || ok=0
    cp "${TMP_DIR}/port_exclude.lst" "$LST_PORT_EXCLUDE" || ok=0
    cp "${TMP_DIR}/port_proxying.lst" "$LST_PORT_PROXYING" || ok=0
    cp "${TMP_DIR}/xkeen.json" "$XKEEN_JSON" || ok=0

    if [ "$ok" -ne 1 ]; then
        rm -rf "$TMP_DIR"
        error "Не все конфигурационные файлы удалось скопировать - проверьте лог"
        return 1
    fi

    # Пишем манифест версий (английский, UTC ISO-8601 + upstream commit + sha256)
    local updated_at commit
    updated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    commit=$(get_upstream_commit)

    cat > "$CONFIG_STATE_FILE" <<EOF
{
  "updated_at": "${updated_at}",
  "source_repo": "${REPO_CONFIG_OWNER}/${REPO_CONFIG_REPO}",
  "source_branch": "${REPO_CONFIG_BRANCH}",
  "source_commit": "${commit}",
  "changed": $( [ "$CONFIGS_CHANGED" -eq 1 ] && echo true || echo false ),
  "files": {
    "config.yaml": { "sha256": "$(hash_file "$CONFIG_MIHOMO")" },
    "xkeen.json": { "sha256": "$(hash_file "$XKEEN_JSON")" },
    "port_proxying.lst": { "sha256": "$(hash_file "$LST_PORT_PROXYING")" },
    "port_exclude.lst": { "sha256": "$(hash_file "$LST_PORT_EXCLUDE")" },
    "ip_exclude.lst": { "sha256": "$(hash_file "$LST_IP_EXCLUDE")" }
  }
}
EOF

    rm -rf "$TMP_DIR"

    if [ "$CONFIGS_CHANGED" -eq 1 ]; then
        success "Конфигурационные файлы обновлены (commit ${commit})"
    else
        log "Конфигурационные файлы актуальны, изменений нет (commit ${commit})"
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
  -b        Создать все бэкапы (XKeen, Xray, Mihomo, прошивка, startup-config)
  -u        Обновить конфигурации из GitHub и перезапустить XKeen (только если что-то изменилось)
  -start    Запустить XKeen (xkeen -start)
  -stop     Остановить XKeen (xkeen -stop)
  -restart  Перезапустить XKeen (xkeen -restart)
  -status   Показать статус XKeen (xkeen -status)
  -c        Показать текущие задания cron
  -a        Добавить задание cron для ежедневного обновления в 4:00
  -s        Обновить сам скрипт xkeen-service до последней версии
  -cfg      Показать содержимое файла настроек
  -cfgstate Показать манифест версий конфигов (даты/коммит/sha256)
  -m        Открыть интерактивное меню
  -v        Показать версию скрипта
  -h        Показать эту справку

Файлы:
  Настройки:       ${CONFIG_FILE}
  Лог:             ${LOG_FILE}
  Бэкапы:          ${BACKUP_DIR}
  Конфиг XKeen:    ${XKEEN_CFG_DIR}
  Конфиг Xray:     ${CONFIG_XRAY_DIR}
  Конфиг Mihomo:   ${CONFIG_MIHOMO_DIR}
  Манифест версий: ${CONFIG_STATE_FILE}

Примеры:
  xkeen-service -b          # Сделать полный бэкап конфигов
  xkeen-service -u          # Обновить конфиги и перезапустить XKeen при изменениях
  xkeen-service -status     # Посмотреть статус XKeen
  xkeen-service -a          # Добавить автообновление в cron
  xkeen-service -cfgstate   # Посмотреть версию/коммит текущих конфигов
EOF
}

# ------------------------- ИНТЕРАКТИВНОЕ МЕНЮ -------------------------
# Стиль и поведение зеркалят setup.sh (и, соответственно, установщики XKeen/
# XKeen-UI): статус перечитывается и экран очищается перед каждой отрисовкой
# меню, а также сразу после выбора пункта - старый вывод не остаётся на экране.

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

    MENU_LAST_BACKUP=$(ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | head -n1)
    [ -n "$MENU_LAST_BACKUP" ] && MENU_LAST_BACKUP=$(basename "$MENU_LAST_BACKUP")

    if [ -f "$CONFIG_STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
        MENU_CFG_UPDATED_AT=$(jq -r '.updated_at // empty' "$CONFIG_STATE_FILE" 2>/dev/null)
        MENU_CFG_COMMIT=$(jq -r '.source_commit // empty' "$CONFIG_STATE_FILE" 2>/dev/null)
    else
        MENU_CFG_UPDATED_AT=""
        MENU_CFG_COMMIT=""
    fi
}

show_menu() {
    get_menu_status
    clear 2>/dev/null || true
    echo ""
    echo -e "${CYAN}   XKEEN-SERVICE${NC}  ${GRAY}v${VERSION}${NC}"
    echo -e "${GRAY}   ${BAR}${NC}"

    if [ "$MENU_XKEEN_BIN_FOUND" -eq 1 ]; then
        echo -e "   ${GREEN}${OK_SYM}${NC} Бинарник xkeen найден в PATH"
    else
        echo -e "   ${RED}${FAIL_SYM}${NC} Бинарник xkeen НЕ найден в PATH"
    fi

    if [ "$MENU_CRON_ACTIVE" -eq 1 ]; then
        echo -e "   ${GREEN}${OK_SYM}${NC} Cron:            ${GRAY}автообновление активно${NC}"
    else
        echo -e "   ${YELLOW}${WARN_SYM}${NC} Cron:            ${GRAY}не активно${NC}"
    fi

    if [ -n "$MENU_LAST_BACKUP" ]; then
        echo -e "   ${GREEN}${OK_SYM}${NC} Последний бэкап: ${GRAY}${MENU_LAST_BACKUP}${NC}"
    else
        echo -e "   ${YELLOW}${WARN_SYM}${NC} Последний бэкап: ${GRAY}нет${NC}"
    fi

    if [ -n "$MENU_CFG_UPDATED_AT" ]; then
        echo -e "   ${GREEN}${OK_SYM}${NC} Конфиги:         ${GRAY}${MENU_CFG_UPDATED_AT} (commit ${MENU_CFG_COMMIT})${NC}"
    else
        echo -e "   ${YELLOW}${WARN_SYM}${NC} Конфиги:         ${GRAY}манифест не создан${NC}"
    fi

    echo -e "${GRAY}   ${BAR}${NC}"
    echo ""
    echo -e "   ${WHITE}1)${NC}  Создать бэкапы (XKeen/Xray/Mihomo/прошивка)"
    echo -e "   ${WHITE}2)${NC}  Обновить конфиги и перезапустить XKeen"
    echo -e "   ${WHITE}3)${NC}  Запустить XKeen"
    echo -e "   ${WHITE}4)${NC}  Остановить XKeen"
    echo -e "   ${WHITE}5)${NC}  Перезапустить XKeen"
    echo -e "   ${WHITE}6)${NC}  Статус XKeen"
    echo -e "   ${WHITE}7)${NC}  Показать cron"
    echo -e "   ${WHITE}8)${NC}  Добавить автообновление в cron"
    echo -e "   ${WHITE}9)${NC}  Обновить сам xkeen-service"
    echo -e "  ${WHITE}10)${NC}  Показать манифест версий конфигов"
    echo -e "   ${WHITE}0)${NC}  Выход"
    echo ""
    echo -e "${GRAY}   ${BAR}${NC}"
    echo ""
}

pause_return() {
    if [ "$HAS_TTY" -eq 1 ]; then
        printf "\n   ${GRAY}Нажмите Enter для возврата в меню...${NC}"
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
            0|"") printf "  ${CYAN}${INFO_SYM}${NC} Выход.\n"; exit 0 ;;
            *) printf "  ${YELLOW}${WARN_SYM}${NC} Неверный пункт: %s\n" "$choice"; sleep 1 ;;
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
