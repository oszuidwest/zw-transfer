#!/usr/bin/env bash

FUNCTIONS_LIB_URL="https://raw.githubusercontent.com/oszuidwest/bash-functions/main/common-functions.sh"
REPO_ARCHIVE_URL="https://github.com/oszuidwest/zw-transfer/archive/refs/heads/main.tar.gz"

FUNCTIONS_LIB_PATH=$(mktemp)
ARCHIVE_PATH=$(mktemp)
EXTRACT_DIR=$(mktemp -d)
INSTALL_DIR="${INSTALL_DIR:-/opt/zw-transfer}"

ENV_FILE="${INSTALL_DIR}/.env"

trap 'rm -f "$FUNCTIONS_LIB_PATH" "$ARCHIVE_PATH"; rm -rf "$EXTRACT_DIR"' EXIT

if ! curl -fsSL -o "$FUNCTIONS_LIB_PATH" "$FUNCTIONS_LIB_URL"; then
  echo "*** Failed to download functions library. Please check your network connection. ***"
  exit 1
fi

# shellcheck source=/dev/null
source "$FUNCTIONS_LIB_PATH"

set_colors
assert_user_privileged "root"
assert_os_linux
assert_os_64bit
assert_tool "curl"
assert_tool "tar"
assert_tool "docker"

CONTAINER_NAMES=("zw-transfer-caddy" "zw-transfer")

containers_running() {
  local name
  for name in "${CONTAINER_NAMES[@]}"; do
    if docker ps --filter "name=^${name}$" --format '{{.Names}}' | grep -qx "$name"; then
      return 0
    fi
  done
  return 1
}

stop_existing_stack() {
  if [ -f "${INSTALL_DIR}/docker-compose.yml" ] && [ -f "${ENV_FILE}" ]; then
    (cd "$INSTALL_DIR" && docker compose --env-file .env down --timeout 30 --remove-orphans) || true
  fi
  local name
  for name in "${CONTAINER_NAMES[@]}"; do
    if docker ps -a --filter "name=^${name}$" --format '{{.Names}}' | grep -qx "$name"; then
      docker rm -f "$name" >/dev/null 2>&1 || true
    fi
  done
}

verify_services_running() {
  sleep 3
  local failed=0
  local name status
  for name in "${CONTAINER_NAMES[@]}"; do
    status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
    if [ "$status" = "running" ]; then
      echo -e "${GREEN}✓ ${name} is ${status}${NC}"
    else
      echo -e "${RED}✗ ${name} is ${status}${NC}"
      failed=1
    fi
  done
  return "$failed"
}

clear

echo -e "${GREEN}ZuidWest Transfer deployment installer${NC}\n"

prompt_user "INSTALL_DIR" "$INSTALL_DIR" "Installation directory" "str"
ENV_FILE="${INSTALL_DIR}/.env"

EXISTING_INSTALL="n"
if [ -f "${ENV_FILE}" ] || [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
  EXISTING_INSTALL="y"
  echo -e "${YELLOW}Existing installation detected in ${INSTALL_DIR}.${NC}\n"
fi

if containers_running; then
  echo -e "${YELLOW}Transfer containers are currently running.${NC}"
  echo -e "${YELLOW}Continuing will stop the service and may interrupt active uploads.${NC}\n"
  prompt_user "CONTINUE_RUNNING" "n" "Continue anyway? (y/n)" "y/n"
  if [ "$CONTINUE_RUNNING" != "y" ]; then
    echo -e "${BLUE}Aborted by operator.${NC}"
    exit 0
  fi
fi

prompt_user "DO_UPDATES" "y" "Perform OS updates? (y/n)" "y/n"

if [ "$EXISTING_INSTALL" == "y" ]; then
  prompt_user "KEEP_CONFIG" "y" "Keep existing .env configuration? (y/n)" "y/n"
else
  KEEP_CONFIG="n"
fi

if [ "$KEEP_CONFIG" == "n" ]; then
  prompt_user "APP_NAME" "ZuidWest Transfer" "Application name" "str"
  prompt_required "APP_HOSTNAME" "Public hostname" "host"
  APP_URL="https://${APP_HOSTNAME}"
  prompt_required "SMTP_HOST" "SMTP host" "host"
  prompt_user "SMTP_PORT" "587" "SMTP port" "str"
  prompt_required "SMTP_EMAIL" "SMTP sender address" "email"
  prompt_user "SMTP_USERNAME" "$SMTP_EMAIL" "SMTP username" "str"
  prompt_secret "SMTP_PASSWORD" "SMTP password"
  prompt_required "OIDC_DISCOVERY_URI" "OIDC discovery URI" "str"
  prompt_required "OIDC_CLIENT_ID" "OIDC client ID" "str"
  prompt_secret "OIDC_CLIENT_SECRET" "OIDC client secret"
  prompt_user "OIDC_USERNAME_CLAIM" "name" "OIDC username claim" "str"
fi

set_timezone Europe/Amsterdam

if [ "$DO_UPDATES" == "y" ]; then
  apt_update --silent
fi

if declare -F set_system_hardening_baseline > /dev/null; then
  set_system_hardening_baseline --silent
fi

echo -e "${BLUE}►► Creating installation directory: ${INSTALL_DIR}${NC}"
mkdir -p "${INSTALL_DIR}"

echo -e "${BLUE}►► Downloading repository archive${NC}"
if ! curl -fsSL -o "$ARCHIVE_PATH" "$REPO_ARCHIVE_URL"; then
  echo -e "${RED}*** Failed to download repository archive. Please check your network connection. ***${NC}"
  exit 1
fi

tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR" --strip-components=1

echo -e "${BLUE}►► Installing deployment files${NC}"
cp "${EXTRACT_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
cp "${EXTRACT_DIR}/Caddyfile" "${INSTALL_DIR}/Caddyfile"
cp "${EXTRACT_DIR}/.env.example" "${INSTALL_DIR}/.env.example"

mkdir -p "${INSTALL_DIR}/patches"
cp "${EXTRACT_DIR}/patches/email.service.js" "${INSTALL_DIR}/patches/email.service.js"

if [ "$KEEP_CONFIG" == "y" ] && [ -f "$ENV_FILE" ]; then
  echo -e "${BLUE}►► Keeping existing .env${NC}"
else
  echo -e "${BLUE}►► Writing .env configuration${NC}"
  cat > "$ENV_FILE" <<EOF
# Deployment-specific overrides written by install.sh.
# Compose defaults provide everything else; see .env.example for available knobs.

APP_HOSTNAME=${APP_HOSTNAME}
APP_NAME=${APP_NAME}
APP_URL=${APP_URL}

SMTP_ENABLED=true
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_EMAIL=${SMTP_EMAIL}
SMTP_USERNAME=${SMTP_USERNAME}
SMTP_PASSWORD=${SMTP_PASSWORD}

OIDC_ENABLED=true
OIDC_DISCOVERY_URI=${OIDC_DISCOVERY_URI}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID}
OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
OIDC_USERNAME_CLAIM=${OIDC_USERNAME_CLAIM}
EOF
fi

chmod 600 "$ENV_FILE"

echo -e "\n${GREEN}✓ Installation files are ready in ${INSTALL_DIR}${NC}"

prompt_user "START_SERVICES" "y" "Start deployment now? (y/n)" "y/n"
if [ "$START_SERVICES" == "y" ]; then
  cd "$INSTALL_DIR" || exit
  echo -e "${BLUE}►► Validating Docker Compose configuration${NC}"
  docker compose --env-file .env config >/tmp/zw-transfer.compose.yml

  if [ "$EXISTING_INSTALL" == "y" ] || containers_running; then
    echo -e "${BLUE}►► Stopping existing containers${NC}"
    stop_existing_stack
  fi

  echo -e "${BLUE}►► Pulling images${NC}"
  docker compose --env-file .env pull

  echo -e "${BLUE}►► Starting containers${NC}"
  docker compose --env-file .env up -d

  echo -e "${BLUE}►► Verifying service health${NC}"
  if verify_services_running; then
    echo -e "${GREEN}✓ All services are up${NC}"
  else
    echo -e "${YELLOW}⚠ Some services did not start cleanly. Check 'docker compose logs'.${NC}"
  fi

  echo -e "${BLUE}►► Container status${NC}"
  docker compose --env-file .env ps
else
  echo -e "${YELLOW}To start later: cd ${INSTALL_DIR} && docker compose --env-file .env up -d${NC}"
fi
