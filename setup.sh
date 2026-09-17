#!/bin/sh
# setup.sh — Установщик/обновление/удаление xkeen-service для Keenetic + Entware
# Запуск: curl -Ls https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main/setup.sh | sh

# ---------- КОНФИГ ----------
REPO_RAW="https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main"
REPO_URL="https://github.com/ChapaGG/Xkeen-Service"

# Физическое имя файла в репозитории и на устройстве
SCRIPT_FILE="xkeen-service.sh"
# Имя команды (симлинк без расширения)
SCRIPT_CMD="xkeen-service"

INSTALL_DIR="/opt/sbin"
LINK_DIR="/opt/bin"
PROFILE_FILE="/opt/etc/profile"
CONFIG_FILE="/opt/etc/xkeen/xkeen-service.json"
BACKUP_DIR="/opt/backups"

INSTALL_PATH="${INSTALL_DIR}/${SCRIPT_FILE}"
LINK_PATH_SBIN="${INSTALL_DIR}/${SCRIPT_CMD}"
LINK_PATH_BIN="${LINK_DIR}/${SCRIPT_CMD}"

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

# ---------- СИМВОЛЫ (ASCII, гарантированно работают) ----------
OK="[+]"
FAIL="[-]"
INFO="[i]"
WARN="[!]"
ROCKET=">>"
TRASH="XX"
GEAR="**"
BOX="[]"
KEY="*"
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
    if [ -f "$INSTALL_PATH" ] || [ -f "$LINK_PATH_SBIN" ]; then
        INSTALLED=1
        local check_file="$INSTALL_PATH"
        [ -f "$check_file" ] || check_file="$LINK_PATH_SBIN"
        INSTALLED_VERSION=$(grep -m1 '^VERSION=' "$check_file" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
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
    msg_info "${ROCKET} Установка ${SCRIPT_FILE}..."

    # Автопереустановка: удаляем старую версию
    if [ -f "$INSTALL_PATH" ] || [ -L "$LINK_PATH_SBIN" ] || [ -L "$LINK_PATH_BIN" ]; then
        msg_warn "Найдена существующая установка — переустанавливаю..."
        rm -f "$INSTALL_PATH" "$LINK_PATH_SBIN" "$LINK_PATH_BIN" 2>/dev/null || true
    fi

    local tmp="/tmp/${SCRIPT_FILE}.install.$$"
    if run_spinner "Скачивание ${SCRIPT_FILE} из репозитория..." \
        curl -Lsfo "$tmp" "${REPO_RAW}/${SCRIPT_FILE}"; then
        msg_ok "Скрипт скачан"
    else
        die "Не удалось скачать ${SCRIPT_FILE}. Проверьте URL."
    fi

    mkdir -p "${INSTALL_DIR}"
    mv "$tmp" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    msg_ok "Установлен: ${INSTALL_PATH}"

    # Симлинк без .sh в /opt/sbin — вызов xkeen-service
    ln -sf "$INSTALL_PATH" "$LINK_PATH_SBIN"
    msg_ok "Создан симлинк: ${LINK_PATH_SBIN}"

    # Симлинк без .sh в /opt/bin — на случай если /opt/sbin не в PATH
    if [ -d "$LINK_DIR" ]; then
        ln -sf "$INSTALL_PATH" "$LINK_PATH_BIN"
        msg_ok "Создан симлинк: ${LINK_PATH_BIN}"
    fi

    # Файл настроек — не перезаписываем существующий
    local cfg_dir
    cfg_dir=$(dirname "$CONFIG_FILE")
    [ -d "$cfg_dir" ] || mkdir -p "$cfg_dir"

    if [ -f "$CONFIG_FILE" ]; then
        msg_info "Файл настроек уже существует: ${CONFIG_FILE}"
    else
        printf '{}\n' > "$CONFIG_FILE"
        msg_ok "Создан файл настроек: ${CONFIG_FILE}"
    fi

    # PATH
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
    msg_info "${GEAR} Обновление ${SCRIPT_FILE}..."

    if [ ! -f "$INSTALL_PATH" ]; then
        msg_warn "Скрипт не установлен. Выполняю установку..."
        do_install
        return 0
    fi

    [ -d "$BACKUP_DIR" ] || mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    cp "$INSTALL_PATH" "${BACKUP_DIR}/${SCRIPT_FILE}.bak_${ts}"
    msg_ok "Бэкап старой версии: ${BACKUP_DIR}/${SCRIPT_FILE}.bak_${ts}"

    local tmp="/tmp/${SCRIPT_FILE}.update.$$"
    if run_spinner "Скачивание обновления..." \
        curl -Lsfo "$tmp" "${REPO_RAW}/${SCRIPT_FILE}"; then
        msg_ok "Обновление скачано"
    else
        die "Не удалось скачать обновление ${SCRIPT_FILE}."
    fi

    chmod +x "$tmp"
    mv "$tmp" "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" "$LINK_PATH_SBIN" 2>/dev/null || true
    ln -sf "$INSTALL_PATH" "$LINK_PATH_BIN" 2>/dev/null || true

    msg_ok "Обновление завершено"
    msg_info "Файл настроек не затронут: ${CONFIG_FILE}"
}

# ---------- УДАЛЕНИЕ ----------
do_uninstall() {
    echo ""
    msg_info "${TRASH} Удаление ${SCRIPT_FILE}..."

    if crontab -l 2>/dev/null | grep -q "xkeen-service -u"; then
        crontab -l 2>/dev/null | grep -v "xkeen-service -u" | crontab -
        msg_ok "Задание cron удалено"
    fi

    if [ -f "$INSTALL_PATH" ]; then
        rm -f "$INSTALL_PATH"
        msg_ok "Удалён ${INSTALL_PATH}"
    fi
    if [ -L "$LINK_PATH_SBIN" ] || [ -f "$LINK_PATH_SBIN" ]; then
        rm -f "$LINK_PATH_SBIN"
        msg_ok "Удалён ${LINK_PATH_SBIN}"
    fi
    if [ -L "$LINK_PATH_BIN" ] || [ -f "$LINK_PATH_BIN" ]; then
        rm -f "$LINK_PATH_BIN"
        msg_ok "Удалён ${LINK_PATH_BIN}"
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
    msg_plain "           или ${WHITE}xkeen-service.sh -h${NC}"
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
