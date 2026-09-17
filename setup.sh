#!/bin/sh
# setup.sh — Установщик/обновление/удаление xkeen-service для Keenetic + Entware
# Запуск: curl -Ls https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main/setup.sh | sh

set -e

REPO_RAW="https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main"
SCRIPT_NAME="xkeen-service"
INSTALL_DIR="/opt/sbin"
LINK_DIR="/opt/bin"
PROFILE_FILE="/opt/etc/profile"
CONFIG_FILE="/opt/etc/xkeen/xkeen-service.json"
BACKUP_DIR="/opt/backups"

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; exit 1; }

# -------------------- ЧТЕНИЕ ВВОДА --------------------
# При запуске через `curl | sh` stdin занят, поэтому читаем из /dev/tty.
HAS_TTY=0
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    exec 3</dev/tty
    HAS_TTY=1
fi

read_input() {
    # $1 - приглашение
    if [ "$HAS_TTY" -eq 1 ]; then
        printf "%s" "$1" >&2
        IFS= read -r line <&3 || line=""
        echo "$line"
    else
        echo ""
    fi
}

# -------------------- ПРОВЕРКИ --------------------
[ "$(id -u)" -eq 0 ] || error "Скрипт нужно запускать от имени root."

# -------------------- УСТАНОВКА --------------------
do_install() {
    info "Установка ${SCRIPT_NAME}..."

    curl -Lsfo "${INSTALL_DIR}/${SCRIPT_NAME}" "${REPO_RAW}/${SCRIPT_NAME}" || \
        error "Не удалось скачать ${SCRIPT_NAME}. Проверьте URL."

    chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
    info "Скрипт установлен в ${INSTALL_DIR}/${SCRIPT_NAME}"

    if [ -d "$LINK_DIR" ]; then
        ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${LINK_DIR}/${SCRIPT_NAME}"
        info "Создана ссылка в ${LINK_DIR}/${SCRIPT_NAME}"
    fi

    # Файл настроек — не перезаписываем существующий
    local cfg_dir
    cfg_dir=$(dirname "$CONFIG_FILE")
    [ -d "$cfg_dir" ] || mkdir -p "$cfg_dir"

    if [ -f "$CONFIG_FILE" ]; then
        info "Файл настроек уже существует: $CONFIG_FILE (не перезаписываю)"
    else
        printf '{}\n' > "$CONFIG_FILE"
        info "Создан файл настроек: $CONFIG_FILE"
    fi

    # PATH
    if [ -f "$PROFILE_FILE" ]; then
        if ! grep -q "/opt/sbin" "$PROFILE_FILE" 2>/dev/null; then
            echo 'export PATH=/opt/sbin:/opt/bin:$PATH' >> "$PROFILE_FILE"
            info "PATH обновлён в ${PROFILE_FILE}"
        else
            info "PATH уже содержит /opt/sbin в ${PROFILE_FILE}"
        fi
    else
        warn "Файл ${PROFILE_FILE} не найден. PATH не изменён."
    fi

    info "Установка завершена!"
    info "Теперь можно вызывать: ${SCRIPT_NAME} -h"
    info "Для применения PATH перезайдите по SSH или выполните: . ${PROFILE_FILE}"
}

# -------------------- ОБНОВЛЕНИЕ --------------------
do_update() {
    info "Обновление ${SCRIPT_NAME}..."

    if [ ! -f "${INSTALL_DIR}/${SCRIPT_NAME}" ]; then
        warn "Скрипт не установлен. Выполняю установку..."
        do_install
        return 0
    fi

    # Бэкап текущей версии перед обновлением
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    [ -d "$BACKUP_DIR" ] || mkdir -p "$BACKUP_DIR"
    cp "${INSTALL_DIR}/${SCRIPT_NAME}" "${BACKUP_DIR}/${SCRIPT_NAME}.bak_${ts}" 2>/dev/null || true
    info "Бэкап старой версии: ${BACKUP_DIR}/${SCRIPT_NAME}.bak_${ts}"

    local tmp_self="/tmp/${SCRIPT_NAME}.update.$$"
    curl -Lsfo "$tmp_self" "${REPO_RAW}/${SCRIPT_NAME}" || \
        error "Не удалось скачать обновление ${SCRIPT_NAME}."

    chmod +x "$tmp_self"
    mv "$tmp_self" "${INSTALL_DIR}/${SCRIPT_NAME}"
    ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${LINK_DIR}/${SCRIPT_NAME}" 2>/dev/null || true

    info "Обновление завершено. Файл настроек не затронут: $CONFIG_FILE"
}

# -------------------- УДАЛЕНИЕ --------------------
do_uninstall() {
    warn "Удаление ${SCRIPT_NAME}..."

    # Убираем cron-задание, если было добавлено
    if crontab -l 2>/dev/null | grep -q "xkeen-service -u"; then
        crontab -l 2>/dev/null | grep -v "xkeen-service -u" | crontab -
        info "Задание cron удалено"
    fi

    [ -f "${INSTALL_DIR}/${SCRIPT_NAME}" ] && rm -f "${INSTALL_DIR}/${SCRIPT_NAME}" && info "Удалён ${INSTALL_DIR}/${SCRIPT_NAME}"
    [ -L "${LINK_DIR}/${SCRIPT_NAME}" ] && rm -f "${LINK_DIR}/${SCRIPT_NAME}" && info "Удалён симлинк ${LINK_DIR}/${SCRIPT_NAME}"

    # Спросим про конфиг
    if [ -f "$CONFIG_FILE" ]; then
        local ans
        ans=$(read_input "Удалить файл настроек ${CONFIG_FILE}? [y/N]: ")
        case "$ans" in
            y|Y|yes|YES)
                rm -f "$CONFIG_FILE"
                info "Файл настроек удалён"
                ;;
            *)
                info "Файл настроек сохранён: $CONFIG_FILE"
                ;;
        esac
    fi

    # Спросим про бэкапы
    if [ -d "$BACKUP_DIR" ]; then
        local ans2
        ans2=$(read_input "Удалить каталог бэкапов ${BACKUP_DIR}? [y/N]: ")
        case "$ans2" in
            y|Y|yes|YES)
                rm -rf "$BACKUP_DIR"
                info "Каталог бэкапов удалён"
                ;;
            *)
                info "Каталог бэкапов сохранён: $BACKUP_DIR"
                ;;
        esac
    fi

    info "Удаление завершено."
}

# -------------------- МЕНЮ --------------------
show_menu() {
    clear 2>/dev/null || true
    cat <<EOF
${CYAN}================================================${NC}
       ${CYAN}XKeen-Service — Установщик${NC}
${CYAN}================================================${NC}
  Репозиторий: ${REPO_RAW}
  Скрипт:      ${INSTALL_DIR}/${SCRIPT_NAME}
  Настройки:   ${CONFIG_FILE}

  1) Установка
  2) Обновление
  3) Удаление
  0) Выход
${CYAN}================================================${NC}
EOF
}

main_menu() {
    local choice
    while :; do
        show_menu
        choice=$(read_input "Выберите пункт [1-3, 0]: ")
        case "$choice" in
            1) do_install; break ;;
            2) do_update; break ;;
            3) do_uninstall; break ;;
            0|"") info "Выход."; exit 0 ;;
            *) warn "Неверный пункт: $choice" ; sleep 1 ;;
        esac
    done
}

# -------------------- ТОЧКА ВХОДА --------------------
# Если нет tty (запуск из cron / неинтерактивно) — сразу установка.
# Иначе — показываем меню. Также можно передать аргумент: install|update|uninstall
case "$1" in
    install)   do_install ;;
    update)    do_update ;;
    uninstall) do_uninstall ;;
    *)
        if [ "$HAS_TTY" -eq 1 ]; then
            main_menu
        else
            do_install
        fi
        ;;
esac

exit 0
