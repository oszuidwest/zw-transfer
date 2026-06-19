#!/usr/bin/env bash

set -euo pipefail

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

dotenv_quote() {
  local value="$1"
  local escaped_quote="\\'"
  # Values are interpolated into double-quoted YAML inside docker-compose.yml.
  # Single-quote the dotenv value to stop Compose from expanding $ in secrets.
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\'/$escaped_quote}"
  printf "'%s'" "$value"
}

write_env_var() {
  local key="$1"
  local value="$2"

  printf "%s=%s\n" "$key" "$(dotenv_quote "$value")"
}

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

verify_containers_running() {
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

clear || true

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

if [ "$EXISTING_INSTALL" == "y" ] && [ -f "$ENV_FILE" ]; then
  prompt_user "KEEP_CONFIG" "y" "Keep existing .env configuration? (y/n)" "y/n"
else
  if [ "$EXISTING_INSTALL" == "y" ]; then
    echo -e "${YELLOW}Existing deployment files found, but no .env exists yet. A new .env will be written.${NC}\n"
  fi
  KEEP_CONFIG="n"
fi

if [ "$KEEP_CONFIG" == "n" ]; then
  prompt_required "APP_HOSTNAME" "Public hostname" "host"
  prompt_required "SMTP_HOST" "SMTP host" "host"
  prompt_required "SMTP_EMAIL" "SMTP sender address" "email"
  prompt_secret "SMTP_PASSWORD" "SMTP password"
  prompt_required "OIDC_DISCOVERY_URI" "OIDC discovery URI" "str"
  prompt_required "OIDC_CLIENT_ID" "OIDC client ID" "str"
  prompt_secret "OIDC_CLIENT_SECRET" "OIDC client secret"
fi

# Configure host time settings
set_timezone Europe/Amsterdam
set_time_sync

# Configure journald storage limits
set_journald_limits

if [ "$DO_UPDATES" == "y" ]; then
  apt_update --silent
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
  {
    cat <<'EOF'
# Deployment-specific overrides written by install.sh.
# Compose defaults provide everything else; see docker-compose.yml for supported overrides.

EOF
    write_env_var "APP_HOSTNAME" "$APP_HOSTNAME"
    printf "\n"
    write_env_var "SMTP_ENABLED" "true"
    write_env_var "SMTP_HOST" "$SMTP_HOST"
    write_env_var "SMTP_EMAIL" "$SMTP_EMAIL"
    write_env_var "SMTP_PASSWORD" "$SMTP_PASSWORD"
    printf "\n"
    write_env_var "OIDC_ENABLED" "true"
    write_env_var "OIDC_DISCOVERY_URI" "$OIDC_DISCOVERY_URI"
    write_env_var "OIDC_CLIENT_ID" "$OIDC_CLIENT_ID"
    write_env_var "OIDC_CLIENT_SECRET" "$OIDC_CLIENT_SECRET"
  } > "$ENV_FILE"
fi

chmod 600 "$ENV_FILE"

echo -e "\n${GREEN}✓ Installation files are ready in ${INSTALL_DIR}${NC}"

prompt_user "START_SERVICES" "y" "Start deployment now? (y/n)" "y/n"
if [ "$START_SERVICES" == "y" ]; then
  cd "$INSTALL_DIR" || exit
  echo -e "${BLUE}►► Validating Docker Compose configuration${NC}"
  docker compose --env-file .env config -q
  "${EXTRACT_DIR}/scripts/validate-pingvin-config.sh" .env

  echo -e "${BLUE}►► Pulling images${NC}"
  docker compose --env-file .env pull

  if [ "$EXISTING_INSTALL" == "y" ] || containers_running; then
    echo -e "${BLUE}►► Stopping existing containers${NC}"
    stop_existing_stack
  fi

  echo -e "${BLUE}►► Starting containers${NC}"
  docker compose --env-file .env up -d

  echo -e "${BLUE}►► Checking container runtime state${NC}"
  if ! verify_containers_running; then
    echo -e "${RED}*** Some containers are not running. Check 'docker compose logs'. ***${NC}"
    docker compose --env-file .env ps || true
    exit 1
  fi
  echo -e "${GREEN}✓ All containers are running${NC}"

  echo -e "${BLUE}►► Container status${NC}"
  docker compose --env-file .env ps
else
  echo -e "${YELLOW}To start later: cd ${INSTALL_DIR} && docker compose --env-file .env up -d${NC}"
fi
