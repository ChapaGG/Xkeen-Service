#!/bin/sh
# setup.sh — Установщик xkeen-service для Keenetic + Entware
# Запуск: curl -Ls https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main/setup.sh | sh

set -e

REPO_RAW="https://raw.githubusercontent.com/ChapaGG/Xkeen-Service/main"
SCRIPT_NAME="xkeen-service"
INSTALL_DIR="/opt/sbin"
LINK_DIR="/opt/bin"
PROFILE_FILE="/opt/etc/profile"

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Скрипт нужно запускать от имени root."

info "Скачивание ${SCRIPT_NAME} из репозитория..."
curl -Lsfo "${INSTALL_DIR}/${SCRIPT_NAME}" "${REPO_RAW}/${SCRIPT_NAME}" || \
  error "Не удалось скачать ${SCRIPT_NAME}. Проверьте URL."

chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
info "Скрипт установлен в ${INSTALL_DIR}/${SCRIPT_NAME}"

if [ -d "$LINK_DIR" ]; then
  ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${LINK_DIR}/${SCRIPT_NAME}"
  info "Создана ссылка в ${LINK_DIR}/${SCRIPT_NAME}"
fi

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