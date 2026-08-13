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
  APPEARANCE_UPLOAD_PROGRESS_STYLE
  SHARE_ALLOW_REGISTRATION
  SHARE_ALLOW_UNAUTHENTICATED_SHARES
  SHARE_ENABLE_USER_RECIPIENTS
  SHARE_MAX_SIZE
  EMAIL_ENABLE_SHARE_RECIPIENTS
  EMAIL_ENABLE_SHARE_DOWNLOAD_NOTIFICATIONS
  EMAIL_SHARE_RECIPIENTS_REPLY_TO_CREATOR
  EMAIL_SHARE_RECIPIENTS_SUBJECT
  EMAIL_SHARE_DOWNLOAD_NOTIFICATION_SUBJECT
  EMAIL_RESET_PASSWORD_SUBJECT
  EMAIL_INVITE_SUBJECT
  EMAIL_REVERSE_SHARE_SUBJECT
  EMAIL_SHARE_RECIPIENTS_MESSAGE
  EMAIL_SHARE_DOWNLOAD_NOTIFICATION_MESSAGE
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
  S3_ENABLED
  S3_ENDPOINT
  S3_REGION
  S3_BUCKET_NAME
  S3_BUCKET_PATH
  S3_KEY
  S3_SECRET
  S3_USE_CHECKSUM
)

assert_compose_env_vars_current() {
  local script_path="$1"

  ruby - "$script_path" <<'RUBY'
require "yaml"

script_path = ARGV.fetch(0)

begin
  compose = YAML.safe_load(File.read("docker-compose.yml"), aliases: true)
  content = compose.fetch("configs").fetch("pingvin_config").fetch("content")
rescue Psych::Exception => e
  abort "ERROR: failed to parse docker-compose.yml while checking COMPOSE_ENV_VARS: #{e.message}"
rescue KeyError => e
  abort "ERROR: docker-compose.yml no longer contains configs.pingvin_config.content: #{e.message}"
end

compose_vars = content.scan(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?=[-:}])/).flatten.uniq.sort

script = File.read(script_path)
vars_block = script[/^COMPOSE_ENV_VARS=\(\n(.*?)^\)/m, 1]
abort "ERROR: failed to locate COMPOSE_ENV_VARS in #{script_path}" unless vars_block

listed_vars = vars_block.scan(/^\s*([A-Z][A-Z0-9_]*)\s*$/).flatten.uniq.sort

missing = compose_vars - listed_vars
extra = listed_vars - compose_vars

unless missing.empty? && extra.empty?
  messages = []
  messages << "missing from COMPOSE_ENV_VARS: #{missing.join(", ")}" unless missing.empty?
  messages << "not used by pingvin_config: #{extra.join(", ")}" unless extra.empty?
  abort "ERROR: COMPOSE_ENV_VARS is out of sync with docker-compose.yml pingvin_config tokens (#{messages.join("; ")})"
end
RUBY
}

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
require "uri"
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
  %w[appearance uploadProgressStyle],
  %w[share allowRegistration],
  %w[share allowUnauthenticatedShares],
  %w[share enableUserRecipients],
  %w[share maxSize],
  %w[email enableShareEmailRecipients],
  %w[email enableShareDownloadNotifications],
  %w[email shareRecipientsReplyToCreator],
  %w[email shareRecipientsSubject],
  %w[email shareDownloadNotificationSubject],
  %w[email resetPasswordSubject],
  %w[email inviteSubject],
  %w[email reverseShareSubject],
  %w[email shareRecipientsMessage],
  %w[email shareDownloadNotificationMessage],
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
  %w[initUser ldapDN],
  %w[s3 enabled],
  %w[s3 endpoint],
  %w[s3 region],
  %w[s3 bucketName],
  %w[s3 bucketPath],
  %w[s3 key],
  %w[s3 secret],
  %w[s3 useChecksum]
]

string_paths.each do |category, key|
  value = fetch_path(config, scenario, category, key)
  fail!(scenario, "#{category}.#{key} must render as a YAML string, got #{value.class}") unless value.is_a?(String)
end

upload_progress_style = fetch_path(config, scenario, "appearance", "uploadProgressStyle")
valid_upload_progress_styles = %w[circle circle-percentage percentage-time]
unless valid_upload_progress_styles.include?(upload_progress_style)
  fail!(scenario, "appearance.uploadProgressStyle must be one of #{valid_upload_progress_styles.join(", ")}, got #{upload_progress_style.inspect}")
end

feature_boolean_paths = [
  %w[share enableUserRecipients],
  %w[email shareRecipientsReplyToCreator]
]

feature_boolean_paths.each do |category, key|
  value = fetch_path(config, scenario, category, key)
  unless %w[true false].include?(value)
    fail!(scenario, "#{category}.#{key} must be exactly \"true\" or \"false\", got #{value.inspect}")
  end
end

s3_boolean_paths = [
  %w[s3 enabled],
  %w[s3 useChecksum]
]

# Pingvin config-file booleans are stored as strings and parsed with
# `value == "true"`; any other spelling silently becomes false.
s3_boolean_paths.each do |category, key|
  value = fetch_path(config, scenario, category, key)
  unless %w[true false].include?(value)
    fail!(scenario, "#{category}.#{key} must be exactly \"true\" or \"false\", got #{value.inspect}")
  end
end

s3_enabled = fetch_path(config, scenario, "s3", "enabled")
if s3_enabled == "true"
  required_s3_paths = [
    %w[s3 endpoint],
    %w[s3 region],
    %w[s3 bucketName],
    %w[s3 key],
    %w[s3 secret]
  ]

  required_s3_paths.each do |category, key|
    value = fetch_path(config, scenario, category, key)
    fail!(scenario, "#{category}.#{key} must not be empty when s3.enabled is true") if value.strip.empty?
  end

  endpoint = fetch_path(config, scenario, "s3", "endpoint")
  begin
    endpoint_uri = URI.parse(endpoint)
  rescue URI::InvalidURIError
    endpoint_uri = nil
  end

  unless endpoint_uri.is_a?(URI::HTTP) && endpoint_uri.host && !endpoint_uri.host.empty?
    fail!(scenario, "s3.endpoint must be a full HTTP(S) URL when s3.enabled is true, got #{endpoint.inspect}")
  end

  bucket_path = fetch_path(config, scenario, "s3", "bucketPath")
  if bucket_path.start_with?("/") || bucket_path.end_with?("/")
    fail!(scenario, "s3.bucketPath must not start or end with a slash, got #{bucket_path.inspect}")
  end
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
    %w[oauth oidc-usernameClaim] => "preferred_username"
  }

  contains_expectations = {
    %w[email inviteSubject] => "Example Transfer",
    %w[email shareRecipientsMessage] => "Example Transfer",
    %w[email resetPasswordMessage] => "Example Transfer",
    %w[email inviteMessage] => "Example Transfer"
  }
elsif scenario == "explicit-smtp-username"
  expectations = {
    %w[smtp username] => "smtp-login@example.test"
  }
  contains_expectations = {}
elsif scenario == "s3-enabled"
  expectations = {
    %w[s3 enabled] => "true",
    %w[s3 endpoint] => "https://s3.eu-central-1.amazonaws.com",
    %w[s3 region] => "eu-central-1",
    %w[s3 bucketName] => "zw-transfer-test",
    %w[s3 bucketPath] => "shares",
    %w[s3 key] => "dummy-access-key",
    %w[s3 secret] => "dummy-secret-key",
    %w[s3 useChecksum] => "false"
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
assert_compose_env_vars_current "${BASH_SOURCE[0]}"

BASE_CONFIG_JSON="$(make_temp)"
DERIVED_ENV="$(make_temp)"
DERIVED_CONFIG_JSON="$(make_temp)"
EXPLICIT_SMTP_ENV="$(make_temp)"
EXPLICIT_SMTP_CONFIG_JSON="$(make_temp)"
S3_ENABLED_ENV="$(make_temp)"
S3_ENABLED_CONFIG_JSON="$(make_temp)"
BROKEN_ENV="$(make_temp)"
BROKEN_CONFIG_JSON="$(make_temp)"
BROKEN_LOG="$(make_temp)"
BROKEN_ADMIN_ENV="$(make_temp)"
BROKEN_ADMIN_CONFIG_JSON="$(make_temp)"
BROKEN_ADMIN_LOG="$(make_temp)"
BROKEN_S3_ENABLED_ENV="$(make_temp)"
BROKEN_S3_ENABLED_CONFIG_JSON="$(make_temp)"
BROKEN_S3_ENABLED_LOG="$(make_temp)"
BROKEN_S3_CHECKSUM_ENV="$(make_temp)"
BROKEN_S3_CHECKSUM_CONFIG_JSON="$(make_temp)"
BROKEN_S3_CHECKSUM_LOG="$(make_temp)"
BROKEN_S3_REQUIRED_ENV="$(make_temp)"
BROKEN_S3_REQUIRED_CONFIG_JSON="$(make_temp)"
BROKEN_S3_REQUIRED_LOG="$(make_temp)"
BROKEN_S3_BUCKET_PATH_ENV="$(make_temp)"
BROKEN_S3_BUCKET_PATH_CONFIG_JSON="$(make_temp)"
BROKEN_S3_BUCKET_PATH_LOG="$(make_temp)"

assert_validation_fails() {
  local config_json="$1"
  local scenario="$2"
  local expected_message="$3"
  local log_file="$4"

  # Self-tests match stable substrings from this script's own validation errors.
  if validate_rendered_config "$config_json" "$scenario" >"$log_file" 2>&1; then
    echo "ERROR: $scenario validation scenario unexpectedly passed" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_message" "$log_file"; then
    cat "$log_file" >&2
    echo "ERROR: $scenario validation scenario failed for the wrong reason" >&2
    exit 1
  fi
}

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

cat >"$S3_ENABLED_ENV" <<'EOF'
S3_ENABLED=true
S3_ENDPOINT=https://s3.eu-central-1.amazonaws.com
S3_REGION=eu-central-1
S3_BUCKET_NAME=zw-transfer-test
S3_BUCKET_PATH=shares
S3_KEY=dummy-access-key
S3_SECRET=dummy-secret-key
S3_USE_CHECKSUM=false
EOF

render_compose_config "$S3_ENABLED_ENV" "$S3_ENABLED_CONFIG_JSON"
validate_rendered_config "$S3_ENABLED_CONFIG_JSON" "s3-enabled"

cat >"$BROKEN_ENV" <<'EOF'
INIT_USER_ENABLED=maybe
EOF

render_compose_config "$BROKEN_ENV" "$BROKEN_CONFIG_JSON"
assert_validation_fails "$BROKEN_CONFIG_JSON" "negative-init-user" "initUser.enabled" "$BROKEN_LOG"

cat >"$BROKEN_ADMIN_ENV" <<'EOF'
INIT_USER_IS_ADMIN=maybe
EOF

render_compose_config "$BROKEN_ADMIN_ENV" "$BROKEN_ADMIN_CONFIG_JSON"
assert_validation_fails "$BROKEN_ADMIN_CONFIG_JSON" "negative-init-user-admin" "initUser.isAdmin" "$BROKEN_ADMIN_LOG"

cat >"$BROKEN_S3_ENABLED_ENV" <<'EOF'
S3_ENABLED=yes
EOF

render_compose_config "$BROKEN_S3_ENABLED_ENV" "$BROKEN_S3_ENABLED_CONFIG_JSON"
assert_validation_fails "$BROKEN_S3_ENABLED_CONFIG_JSON" "negative-s3-enabled" "s3.enabled must be exactly" "$BROKEN_S3_ENABLED_LOG"

cat >"$BROKEN_S3_CHECKSUM_ENV" <<'EOF'
S3_USE_CHECKSUM=on
EOF

render_compose_config "$BROKEN_S3_CHECKSUM_ENV" "$BROKEN_S3_CHECKSUM_CONFIG_JSON"
assert_validation_fails "$BROKEN_S3_CHECKSUM_CONFIG_JSON" "negative-s3-checksum" "s3.useChecksum must be exactly" "$BROKEN_S3_CHECKSUM_LOG"

cat >"$BROKEN_S3_REQUIRED_ENV" <<'EOF'
S3_ENABLED=true
S3_ENDPOINT=
S3_REGION=
S3_BUCKET_NAME=
S3_KEY=
S3_SECRET=
EOF

render_compose_config "$BROKEN_S3_REQUIRED_ENV" "$BROKEN_S3_REQUIRED_CONFIG_JSON"
assert_validation_fails "$BROKEN_S3_REQUIRED_CONFIG_JSON" "negative-s3-required-fields" "s3.endpoint must not be empty" "$BROKEN_S3_REQUIRED_LOG"

cat >"$BROKEN_S3_BUCKET_PATH_ENV" <<'EOF'
S3_ENABLED=true
S3_ENDPOINT=https://s3.eu-central-1.amazonaws.com
S3_REGION=eu-central-1
S3_BUCKET_NAME=zw-transfer-test
S3_BUCKET_PATH=/shares/
S3_KEY=dummy-access-key
S3_SECRET=dummy-secret-key
EOF

render_compose_config "$BROKEN_S3_BUCKET_PATH_ENV" "$BROKEN_S3_BUCKET_PATH_CONFIG_JSON"
assert_validation_fails "$BROKEN_S3_BUCKET_PATH_CONFIG_JSON" "negative-s3-bucket-path" "s3.bucketPath must not start or end with a slash" "$BROKEN_S3_BUCKET_PATH_LOG"

echo "Rendered Pingvin config is valid."
