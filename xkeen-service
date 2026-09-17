#!/bin/sh
# xkeen-service - Управление бэкапами и обновлением конфигурации XKeen/Mihomo
# Расположение: /opt/sbin/xkeen-service
# Настройки:   /opt/etc/xkeen/xkeen-service.json
# Установка:   curl -Ls https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main/setup.sh | sh

VERSION="1.0.0"

set -e

# ------------------------- НАСТРОЙКИ -------------------------
BACKUP_DIR="/opt/backups"
LOG_FILE="${BACKUP_DIR}/xkeen-service.log"
CONFIG_FILE="/opt/etc/xkeen/xkeen-service.json"

# Репозиторий со скриптами (этот)
REPO_SCRIPTS="https://github.com/ChapaGG/Xkeen-Service"
# Репозиторий с конфигурациями
REPO_CONFIG_RAW="https://raw.githubusercontent.com/ChapaGG/Mihomo/main"

TMP_DIR="/tmp/xkeen-service_$$"

CONFIG_MIHOMO="/opt/etc/mihomo/config.yaml"
LST_IP_EXCLUDE="/opt/etc/xkeen/ip_exclude.lst"
LST_PORT_EXCLUDE="/opt/etc/xkeen/port_exclude.lst"
LST_PORT_PROXYING="/opt/etc/xkeen/port_proxying.lst"
XKEEN_JSON="/opt/etc/xkeen/xkeen.json"

# ------------------------- ФУНКЦИИ -------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

success() {
    echo -e "\033[32m$*\033[0m" | tee -a "$LOG_FILE"
}

error() {
    echo -e "\033[31m$*\033[0m" | tee -a "$LOG_FILE"
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

backup_xkeen() {
    log "Создание бэкапа XKeen..."
    local ts=$(date '+%Y%m%d_%H%M%S')
    local archive="${BACKUP_DIR}/xkeen_backup_${ts}.tar.gz"
    tar -czf "$archive" -C /opt/etc/xkeen . 2>/dev/null || {
        error "Ошибка при создании бэкапа XKeen"
        return 1
    }
    success "Бэкап XKeen сохранён: $archive"
}

backup_mihomo() {
    log "Создание бэкапа Mihomo..."
    local ts=$(date '+%Y%m%d_%H%M%S')
    local archive="${BACKUP_DIR}/mihomo_backup_${ts}.tar.gz"
    tar -czf "$archive" -C /opt/etc/mihomo . 2>/dev/null || {
        error "Ошибка при создании бэкапа Mihomo"
        return 1
    }
    success "Бэкап Mihomo сохранён: $archive"
}

backup_firmware() {
    log "Создание бэкапа прошивки Keenetic..."
    local ts=$(date '+%Y%m%d_%H%M%S')
    local dest="${BACKUP_DIR}/firmware_${ts}.bin"
    ndmc -c "copy flash:/firmware $dest" 2>/dev/null || {
        error "Ошибка при создании бэкапа прошивки (возможно, ndmc недоступен)"
        return 1
    }
    success "Бэкап прошивки сохранён: $dest"
}

backup_startup_config() {
    log "Создание бэкапа startup-config..."
    local ts=$(date '+%Y%m%d_%H%M%S')
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

    local dt=$(date '+%Y-%m-%d_%H_%M')
    for f in $files; do
        echo "# Обновлено: $dt" | cat - "${TMP_DIR}/$f" > "${TMP_DIR}/tmp_$f"
        mv "${TMP_DIR}/tmp_$f" "${TMP_DIR}/$f"
    done

    cp "${TMP_DIR}/config.yaml" "$CONFIG_MIHOMO"
    cp "${TMP_DIR}/ip_exclude.lst" "$LST_IP_EXCLUDE"
    cp "${TMP_DIR}/port_exclude.lst" "$LST_PORT_EXCLUDE"
    cp "${TMP_DIR}/port_proxying.lst" "$LST_PORT_PROXYING"
    cp "${TMP_DIR}/xkeen.json" "$XKEEN_JSON"

    rm -rf "$TMP_DIR"
    success "Конфигурационные файлы обновлены"
}

restart_xkeen() {
    log "Перезапуск XKeen..."
    /opt/etc/init.d/S99xkeen stop 2>/dev/null || true
    sleep 2
    if /opt/etc/init.d/S99xkeen start 2>/dev/null; then
        sleep 3
        local log_line=$(tail -n 5 /opt/var/log/xkeen/xkeen.log 2>/dev/null | grep -i "error\|fail" || true)
        if [ -z "$log_line" ]; then
            success "XKeen успешно перезапущен. Ошибок в логе не обнаружено."
        else
            error "XKeen перезапущен, но в логе найдены ошибки: $log_line"
        fi
    else
        error "Не удалось запустить XKeen. Проверьте конфигурацию."
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
    log "Обновление самого скрипта xkeen-service из ${REPO_SCRIPTS}..."
    local tmp_self="/tmp/xkeen-service.update.$$"
    if ! curl -fsSL "https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main/xkeen-service" -o "$tmp_self"; then
        error "Не удалось скачать обновление xkeen-service"
        return 1
    fi
    chmod +x "$tmp_self"
    mv "$tmp_self" "/opt/sbin/xkeen-service"
    ln -sf "/opt/sbin/xkeen-service" "/opt/bin/xkeen-service" 2>/dev/null || true
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

Опции:
  -b        Создать все бэкапы (XKeen, Mihomo, прошивка, startup-config)
  -u        Обновить конфигурации из GitHub и перезапустить XKeen
  -c        Показать текущие задания cron
  -a        Добавить задание cron для ежедневного обновления в 4:00
  -s        Обновить сам скрипт xkeen-service до последней версии
  -cfg      Показать содержимое файла настроек
  -v        Показать версию скрипта
  -h        Показать эту справку

Файлы:
  Настройки:  ${CONFIG_FILE}
  Лог:        ${LOG_FILE}
  Бэкапы:     ${BACKUP_DIR}

Примеры:
  xkeen-service -b          # Сделать полный бэкап
  xkeen-service -u          # Обновить конфиги и перезапустить XKeen
  xkeen-service -a          # Добавить автообновление в cron
  xkeen-service -c          # Посмотреть cron
  xkeen-service -s          # Обновить сам скрипт
  xkeen-service -cfg        # Показать текущие настройки
  xkeen-service -v          # Показать версию
EOF
}

# ------------------------- ОСНОВНАЯ ЛОГИКА -------------------------
ensure_backup_dir
ensure_config

case "$1" in
    -b)
        backup_xkeen
        backup_mihomo
        backup_firmware
        backup_startup_config
        ;;
    -u)
        update_configs
        restart_xkeen
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
    -v)
        show_version
        ;;
    -h)
        show_help
        ;;
    *)
        show_help
        ;;
esac

exit 0
