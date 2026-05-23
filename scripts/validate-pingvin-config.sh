#!/usr/bin/env bash

set -euo pipefail

# Render Compose's inline Pingvin config and validate the contract Pingvin
# expects after Compose interpolation.
ENV_FILE="${1:-.env.example}"
TMP_FILES=()

cleanup() {
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup EXIT

make_temp() {
  local tmp_file
  tmp_file="$(mktemp)"
  TMP_FILES+=("$tmp_file")
  printf '%s\n' "$tmp_file"
}

assert_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool not found: $tool" >&2
    exit 1
  fi
}

COMPOSE_ENV_VARS=(
  APP_HOSTNAME
  APP_NAME
  APP_URL
  SECURE_COOKIES
  SHOW_HOME_PAGE
  SESSION_DURATION
  DEFAULT_LANGUAGE
  CUSTOM_CSS
  SHARE_ALLOW_REGISTRATION
  SHARE_ALLOW_UNAUTHENTICATED_SHARES
  SHARE_MAX_SIZE
  EMAIL_ENABLE_SHARE_RECIPIENTS
  EMAIL_SHARE_RECIPIENTS_SUBJECT
  EMAIL_RESET_PASSWORD_SUBJECT
  EMAIL_INVITE_SUBJECT
  EMAIL_REVERSE_SHARE_SUBJECT
  EMAIL_SHARE_RECIPIENTS_MESSAGE
  EMAIL_RESET_PASSWORD_MESSAGE
  EMAIL_INVITE_MESSAGE
  EMAIL_REVERSE_SHARE_MESSAGE
  SMTP_ENABLED
  SMTP_ALLOW_UNAUTHORIZED_CERTIFICATES
  SMTP_HOST
  SMTP_PORT
  SMTP_EMAIL
  SMTP_USERNAME
  SMTP_PASSWORD
  OAUTH_ALLOW_REGISTRATION
  OAUTH_IGNORE_TOTP
  OAUTH_DISABLE_PASSWORD
  OIDC_ENABLED
  OIDC_DISCOVERY_URI
  OIDC_SIGN_OUT
  OIDC_SCOPE
  OIDC_USERNAME_CLAIM
  OIDC_ROLE_PATH
  OIDC_ROLE_GENERAL_ACCESS
  OIDC_ROLE_ADMIN_ACCESS
  OIDC_CLIENT_ID
  OIDC_CLIENT_SECRET
  INIT_USER_ENABLED
  INIT_USER_USERNAME
  INIT_USER_EMAIL
  INIT_USER_PASSWORD
  INIT_USER_IS_ADMIN
  INIT_USER_LDAP_DN
)

render_compose_config() {
  local env_file="$1"
  local output_file="$2"

  (
    unset "${COMPOSE_ENV_VARS[@]}"
    docker compose --env-file "$env_file" config --format json >"$output_file"
  )
}

validate_rendered_config() {
  local compose_json="$1"
  local scenario="$2"

  ruby - "$compose_json" "$scenario" <<'RUBY'
require "json"
require "yaml"

compose_json, scenario = ARGV

def fail!(scenario, message)
  abort "[#{scenario}] #{message}"
end

def fetch_path(config, scenario, category, key)
  category_config = config.fetch(category) do
    fail!(scenario, "missing category #{category}")
  end
  category_config.fetch(key) do
    fail!(scenario, "missing key #{category}.#{key}")
  end
end

begin
  compose = JSON.parse(File.read(compose_json))
  content = compose.fetch("configs").fetch("pingvin_config").fetch("content")
rescue JSON::ParserError => e
  fail!(scenario, "compose JSON is invalid: #{e.message}")
rescue KeyError => e
  fail!(scenario, "compose JSON no longer contains configs.pingvin_config.content: #{e.message}")
end

begin
  config = YAML.safe_load(content, aliases: false)
rescue Psych::Exception => e
  fail!(scenario, "pingvin_config content is not valid YAML: #{e.message}")
end

fail!(scenario, "pingvin_config did not parse to a YAML mapping") unless config.is_a?(Hash)

string_paths = [
  %w[general appName],
  %w[general appUrl],
  %w[general secureCookies],
  %w[general showHomePage],
  %w[general sessionDuration],
  %w[general defaultLanguage],
  %w[appearance customCss],
  %w[share allowRegistration],
  %w[share allowUnauthenticatedShares],
  %w[share maxSize],
  %w[email enableShareEmailRecipients],
  %w[email shareRecipientsSubject],
  %w[email resetPasswordSubject],
  %w[email inviteSubject],
  %w[email reverseShareSubject],
  %w[email shareRecipientsMessage],
  %w[email resetPasswordMessage],
  %w[email inviteMessage],
  %w[email reverseShareMessage],
  %w[smtp enabled],
  %w[smtp allowUnauthorizedCertificates],
  %w[smtp host],
  %w[smtp port],
  %w[smtp email],
  %w[smtp username],
  %w[smtp password],
  %w[oauth allowRegistration],
  %w[oauth ignoreTotp],
  %w[oauth disablePassword],
  %w[oauth oidc-enabled],
  %w[oauth oidc-discoveryUri],
  %w[oauth oidc-signOut],
  %w[oauth oidc-scope],
  %w[oauth oidc-usernameClaim],
  %w[oauth oidc-rolePath],
  %w[oauth oidc-roleGeneralAccess],
  %w[oauth oidc-roleAdminAccess],
  %w[oauth oidc-clientId],
  %w[oauth oidc-clientSecret],
  %w[initUser username],
  %w[initUser email],
  %w[initUser password],
  %w[initUser ldapDN]
]

string_paths.each do |category, key|
  value = fetch_path(config, scenario, category, key)
  fail!(scenario, "#{category}.#{key} must render as a YAML string, got #{value.class}") unless value.is_a?(String)
end

boolean_paths = [
  %w[initUser enabled],
  %w[initUser isAdmin]
]

boolean_paths.each do |category, key|
  value = fetch_path(config, scenario, category, key)
  fail!(scenario, "#{category}.#{key} must render as a YAML boolean, got #{value.class}") unless value == true || value == false
end

if scenario == "derived-overrides"
  expectations = {
    %w[general appName] => "Example Transfer",
    %w[general appUrl] => "https://files.example.test",
    %w[smtp email] => "sender@example.test",
    %w[smtp username] => "sender@example.test",
    %w[oauth oidc-usernameClaim] => "preferred_username",
    %w[email inviteSubject] => "Welkom bij Example Transfer"
  }

  contains_expectations = {
    %w[email shareRecipientsMessage] => "Example Transfer",
    %w[email resetPasswordMessage] => "Example Transfer",
    %w[email inviteMessage] => "Example Transfer"
  }
elsif scenario == "explicit-smtp-username"
  expectations = {
    %w[smtp username] => "smtp-login@example.test"
  }
  contains_expectations = {}
else
  expectations = {}
  contains_expectations = {}
end

expectations.each do |path, expected|
  category, key = path
  actual = fetch_path(config, scenario, category, key)
  fail!(scenario, "#{category}.#{key} expected #{expected.inspect}, got #{actual.inspect}") unless actual == expected
end

contains_expectations.each do |path, expected|
  category, key = path
  actual = fetch_path(config, scenario, category, key)
  fail!(scenario, "#{category}.#{key} expected to include #{expected.inspect}, got #{actual.inspect}") unless actual.include?(expected)
end
RUBY
}

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  exit 1
fi

assert_tool docker
assert_tool ruby

BASE_CONFIG_JSON="$(make_temp)"
DERIVED_ENV="$(make_temp)"
DERIVED_CONFIG_JSON="$(make_temp)"
EXPLICIT_SMTP_ENV="$(make_temp)"
EXPLICIT_SMTP_CONFIG_JSON="$(make_temp)"
BROKEN_ENV="$(make_temp)"
BROKEN_CONFIG_JSON="$(make_temp)"
BROKEN_LOG="$(make_temp)"

render_compose_config "$ENV_FILE" "$BASE_CONFIG_JSON"
validate_rendered_config "$BASE_CONFIG_JSON" "base"

# The derived-overrides scenario proves APP_HOSTNAME -> APP_URL,
# SMTP_EMAIL -> SMTP_USERNAME, and nested APP_NAME interpolation.
cat >"$DERIVED_ENV" <<'EOF'
APP_HOSTNAME=files.example.test
APP_NAME=Example Transfer
SMTP_EMAIL=sender@example.test
OIDC_USERNAME_CLAIM=preferred_username
EOF

render_compose_config "$DERIVED_ENV" "$DERIVED_CONFIG_JSON"
validate_rendered_config "$DERIVED_CONFIG_JSON" "derived-overrides"

cat >"$EXPLICIT_SMTP_ENV" <<'EOF'
SMTP_EMAIL=sender@example.test
SMTP_USERNAME=smtp-login@example.test
EOF

render_compose_config "$EXPLICIT_SMTP_ENV" "$EXPLICIT_SMTP_CONFIG_JSON"
validate_rendered_config "$EXPLICIT_SMTP_CONFIG_JSON" "explicit-smtp-username"

cat >"$BROKEN_ENV" <<'EOF'
INIT_USER_ENABLED=maybe
EOF

render_compose_config "$BROKEN_ENV" "$BROKEN_CONFIG_JSON"
if validate_rendered_config "$BROKEN_CONFIG_JSON" "negative-init-user" >"$BROKEN_LOG" 2>&1; then
  echo "ERROR: negative validation scenario unexpectedly passed" >&2
  exit 1
fi

if ! grep -q "initUser.enabled" "$BROKEN_LOG"; then
  cat "$BROKEN_LOG" >&2
  echo "ERROR: negative validation scenario failed for the wrong reason" >&2
  exit 1
fi

echo "Rendered Pingvin config is valid."
