#!/bin/sh
# setup.sh — Установщик/обновление/удаление xkeen-service для Keenetic + Entware
# Запуск: curl -Ls https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main/setup.sh | sh

# ---------- КОНФИГ ----------
REPO_RAW="https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main"
REPO_URL="https://github.com/ChapaGG/Xkeen-Service"
SCRIPT_NAME="xkeen-service"
INSTALL_DIR="/opt/sbin"
LINK_DIR="/opt/bin"
PROFILE_FILE="/opt/etc/profile"
CONFIG_FILE="/opt/etc/xkeen/xkeen-service.json"
BACKUP_DIR="/opt/backups"

# ---------- ЦВЕТА ----------
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'

# ---------- ЭМОДЗИ ----------
OK="✅"
FAIL="❌"
INFO="ℹ️"
WARN="⚠️"
ROCKET="🚀"
TRASH="🗑️"
GEAR="⚙️"
BOX="📦"
KEY="🔑"
BAR="────────────────────────────────────────────"

# ---------- ВЫВОД ----------
msg_ok()    { printf "  ${GREEN}${OK}${NC}  %s\n" "$*"; }
msg_fail()  { printf "  ${RED}${FAIL}${NC}  %s\n" "$*"; }
msg_info()  { printf "  ${CYAN}${INFO}${NC}  %s\n" "$*"; }
msg_warn()  { printf "  ${YELLOW}${WARN}${NC}  %s\n" "$*"; }
msg_plain() { printf "     %s\n" "$*"; }
die()       { msg_fail "$*"; exit 1; }

# ---------- TTY / ЧТЕНИЕ ВВОДА ----------
HAS_TTY=0
[ -r /dev/tty ] && [ -w /dev/tty ] && HAS_TTY=1

read_tty() {
    local prompt="$1"
    if [ "$HAS_TTY" -eq 1 ]; then
        printf "%s" "$prompt" >&2
        IFS= read -r answer < /dev/tty || answer=""
        echo "$answer"
    else
        echo ""
    fi
}

# ---------- SPINNER ----------
if sleep 0.1 2>/dev/null; then
    SPIN_SLEEP="0.1"
else
    SPIN_SLEEP="1"
fi

run_spinner() {
    local msg="$1"; shift
    local out="/tmp/_spin_out.$$"
    "$@" >"$out" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        for c in '|' '/' '-' '\'; do
            kill -0 "$pid" 2>/dev/null || break
            printf "\r  ${CYAN}%s${NC}  %s" "$c" "$msg"
            sleep "$SPIN_SLEEP"
        done
    done
    wait "$pid"
    local rc=$?
    printf "\r\033[K"
    [ -s "$out" ] && cat "$out"
    rm -f "$out"
    return $rc
}

# ---------- СТАТУС ----------
get_status() {
    if [ -f "${INSTALL_DIR}/${SCRIPT_NAME}" ]; then
        INSTALLED=1
        INSTALLED_VERSION=$(grep -m1 '^VERSION=' "${INSTALL_DIR}/${SCRIPT_NAME}" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
        [ -n "$INSTALLED_VERSION" ] || INSTALLED_VERSION="unknown"
    else
        INSTALLED=0
        INSTALLED_VERSION=""
    fi

    if crontab -l 2>/dev/null | grep -q "xkeen-service -u"; then
        CRON_ACTIVE=1
    else
        CRON_ACTIVE=0
    fi

    if [ -f "$CONFIG_FILE" ]; then
        CONFIG_EXISTS=1
    else
        CONFIG_EXISTS=0
    fi
}

# ---------- ПРОВЕРКА ROOT ----------
[ "$(id -u)" -eq 0 ] || die "Скрипт нужно запускать от имени root."

# ---------- УСТАНОВКА ----------
do_install() {
    echo ""
    msg_info "${ROCKET} Установка ${SCRIPT_NAME}..."

    if [ -f "${INSTALL_DIR}/${SCRIPT_NAME}" ]; then
        msg_warn "Найдена существующая установка — переустанавливаю..."
        rm -f "${INSTALL_DIR}/${SCRIPT_NAME}"
        [ -L "${LINK_DIR}/${SCRIPT_NAME}" ] && rm -f "${LINK_DIR}/${SCRIPT_NAME}"
    fi

    local tmp="/tmp/${SCRIPT_NAME}.install.$$"
    if run_spinner "Скачивание ${SCRIPT_NAME} из репозитория..." \
        curl -Lsfo "$tmp" "${REPO_RAW}/${SCRIPT_NAME}"; then
        msg_ok "Скрипт скачан"
    else
        die "Не удалось скачать ${SCRIPT_NAME}. Проверьте URL."
    fi

    mkdir -p "${INSTALL_DIR}"
    mv "$tmp" "${INSTALL_DIR}/${SCRIPT_NAME}"
    chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
    msg_ok "Установлен: ${INSTALL_DIR}/${SCRIPT_NAME}"

    if [ -d "$LINK_DIR" ]; then
        ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${LINK_DIR}/${SCRIPT_NAME}"
        msg_ok "Создан симлинк: ${LINK_DIR}/${SCRIPT_NAME}"
    fi

    local cfg_dir
    cfg_dir=$(dirname "$CONFIG_FILE")
    [ -d "$cfg_dir" ] || mkdir -p "$cfg_dir"

    if [ -f "$CONFIG_FILE" ]; then
        msg_info "Файл настроек уже существует: ${CONFIG_FILE}"
    else
        printf '{}\n' > "$CONFIG_FILE"
        msg_ok "Создан файл настроек: ${CONFIG_FILE}"
    fi

    if [ -f "$PROFILE_FILE" ]; then
        if ! grep -q "/opt/sbin" "$PROFILE_FILE" 2>/dev/null; then
            echo 'export PATH=/opt/sbin:/opt/bin:$PATH' >> "$PROFILE_FILE"
            msg_ok "PATH обновлён в ${PROFILE_FILE}"
        else
            msg_info "PATH уже содержит /opt/sbin"
        fi
    else
        msg_warn "Файл ${PROFILE_FILE} не найден. PATH не изменён."
    fi

    finish_setup
}

# ---------- ОБНОВЛЕНИЕ ----------
do_update() {
    echo ""
    msg_info "${GEAR} Обновление ${SCRIPT_NAME}..."

    if [ ! -f "${INSTALL_DIR}/${SCRIPT_NAME}" ]; then
        msg_warn "Скрипт не установлен. Выполняю установку..."
        do_install
        return 0
    fi

    [ -d "$BACKUP_DIR" ] || mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    cp "${INSTALL_DIR}/${SCRIPT_NAME}" "${BACKUP_DIR}/${SCRIPT_NAME}.bak_${ts}"
    msg_ok "Бэкап старой версии: ${BACKUP_DIR}/${SCRIPT_NAME}.bak_${ts}"

    local tmp="/tmp/${SCRIPT_NAME}.update.$$"
    if run_spinner "Скачивание обновления..." \
        curl -Lsfo "$tmp" "${REPO_RAW}/${SCRIPT_NAME}"; then
        msg_ok "Обновление скачано"
    else
        die "Не удалось скачать обновление ${SCRIPT_NAME}."
    fi

    chmod +x "$tmp"
    mv "$tmp" "${INSTALL_DIR}/${SCRIPT_NAME}"
    ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${LINK_DIR}/${SCRIPT_NAME}" 2>/dev/null || true

    msg_ok "Обновление завершено"
    msg_info "Файл настроек не затронут: ${CONFIG_FILE}"
}

# ---------- УДАЛЕНИЕ ----------
do_uninstall() {
    echo ""
    msg_info "${TRASH} Удаление ${SCRIPT_NAME}..."

    if crontab -l 2>/dev/null | grep -q "xkeen-service -u"; then
        crontab -l 2>/dev/null | grep -v "xkeen-service -u" | crontab -
        msg_ok "Задание cron удалено"
    fi

    if [ -f "${INSTALL_DIR}/${SCRIPT_NAME}" ]; then
        rm -f "${INSTALL_DIR}/${SCRIPT_NAME}"
        msg_ok "Удалён ${INSTALL_DIR}/${SCRIPT_NAME}"
    fi
    if [ -L "${LINK_DIR}/${SCRIPT_NAME}" ]; then
        rm -f "${LINK_DIR}/${SCRIPT_NAME}"
        msg_ok "Удалён симлинк ${LINK_DIR}/${SCRIPT_NAME}"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        local ans
        ans=$(read_tty "  ${WARN} Удалить файл настроек ${CONFIG_FILE}? [y/N]: ")
        case "$ans" in
            y|Y|yes|YES)
                rm -f "$CONFIG_FILE"
                msg_ok "Файл настроек удалён"
                ;;
            *)
                msg_info "Файл настроек сохранён: ${CONFIG_FILE}"
                ;;
        esac
    fi

    if [ -d "$BACKUP_DIR" ]; then
        local ans2
        ans2=$(read_tty "  ${WARN} Удалить каталог бэкапов ${BACKUP_DIR}? [y/N]: ")
        case "$ans2" in
            y|Y|yes|YES)
                rm -rf "$BACKUP_DIR"
                msg_ok "Каталог бэкапов удалён"
                ;;
            *)
                msg_info "Каталог бэкапов сохранён: ${BACKUP_DIR}"
                ;;
        esac
    fi

    echo ""
    msg_ok "Удаление завершено."
}

# ---------- ФИНАЛИЗАЦИЯ ----------
finish_setup() {
    echo ""
    echo -e "${GRAY}   ${BAR}${NC}"
    echo -e "   ${GREEN}${ROCKET} Установка завершена!${NC}"
    echo -e "${GRAY}   ${BAR}${NC}"
    echo ""
    msg_plain "Запуск:      ${WHITE}xkeen-service -h${NC}"
    msg_plain "Настройки:   ${WHITE}${CONFIG_FILE}${NC}"
    msg_plain "Лог:         ${WHITE}${BACKUP_DIR}/xkeen-service.log${NC}"
    msg_plain "Бэкапы:      ${WHITE}${BACKUP_DIR}${NC}"
    echo ""
    msg_info "Для применения PATH перезайдите по SSH или выполните:"
    echo -e "     ${WHITE}. ${PROFILE_FILE}${NC}"
    echo ""
}

# ---------- МЕНЮ ----------
show_menu() {
    get_status
    clear 2>/dev/null || true
    echo ""
    echo -e "${CYAN}   ██╗  ██╗██╗  ██╗███████╗███████╗███╗   ██╗${NC}"
    echo -e "${CYAN}   ╚██╗██╔╝██║ ██╔╝██╔════╝██╔════╝████╗  ██║${NC}"
    echo -e "${CYAN}    ╚███╔╝ █████╔╝ █████╗  █████╗  ██╔██╗ ██║${NC}"
    echo -e "${CYAN}    ██╔██╗ ██╔═██╗ ██╔══╝  ██╔══╝  ██║╚██╗██║${NC}"
    echo -e "${CYAN}   ██╔╝ ██╗██║  ██╗███████╗███████╗██║ ╚████║${NC}"
    echo -e "${CYAN}   ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═══╝${NC}"
    echo -e "${WHITE}                S E R V I C E${NC}"
    echo ""
    echo -e "${GRAY}   ${BAR}${NC}"

    if [ "$INSTALLED" -eq 1 ]; then
        echo -e "   ${GREEN}${OK}${NC} Установлен:   ${WHITE}v${INSTALLED_VERSION}${NC}"
    else
        echo -e "   ${RED}${FAIL}${NC} Не установлен"
    fi

    if [ "$CONFIG_EXISTS" -eq 1 ]; then
        echo -e "   ${GREEN}${OK}${NC} Настройки:    ${GRAY}${CONFIG_FILE}${NC}"
    else
        echo -e "   ${YELLOW}${WARN}${NC} Настройки:    ${GRAY}нет${NC}"
    fi

    if [ "$CRON_ACTIVE" -eq 1 ]; then
        echo -e "   ${GREEN}${OK}${NC} Cron:         ${GRAY}автообновление активно${NC}"
    else
        echo -e "   ${YELLOW}${WARN}${NC} Cron:         ${GRAY}не активно${NC}"
    fi

    echo -e "${GRAY}   ${BAR}${NC}"
    echo ""
    echo -e "   ${WHITE}1)${NC} ${ROCKET} Установка"
    echo -e "   ${WHITE}2)${NC} ${GEAR} Обновление"
    echo -e "   ${WHITE}3)${NC} ${TRASH} Удаление"
    echo -e "   ${WHITE}0)${NC} Выход"
    echo ""
    echo -e "${GRAY}   ${BAR}${NC}"
    echo -e "   ${GRAY}Репозиторий: ${REPO_URL}${NC}"
    echo ""
}

main_menu() {
    local choice
    while :; do
        show_menu
        choice=$(read_tty "   ${WHITE}Выберите пункт [1-3, 0]:${NC} ")
        echo ""
        case "$choice" in
            1) do_install;   pause_return ;;
            2) do_update;    pause_return ;;
            3) do_uninstall; pause_return ;;
            0|"") msg_info "Выход."; exit 0 ;;
            *) msg_warn "Неверный пункт: ${choice}"; sleep 1 ;;
        esac
    done
}

pause_return() {
    if [ "$HAS_TTY" -eq 1 ]; then
        printf "\n   ${GRAY}Нажмите Enter для возврата в меню...${NC}"
        IFS= read -r _ < /dev/tty || true
    fi
}

# ---------- ТОЧКА ВХОДА ----------
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
