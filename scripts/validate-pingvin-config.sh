#!/usr/bin/env bash

set -euo pipefail

ENV_FILE="${1:-.env.example}"
BASE_CONFIG_JSON="$(mktemp)"
OVERRIDE_ENV="$(mktemp)"
OVERRIDE_CONFIG_JSON="$(mktemp)"

cleanup() {
  rm -f "$BASE_CONFIG_JSON" "$OVERRIDE_ENV" "$OVERRIDE_CONFIG_JSON"
}
trap cleanup EXIT

render_compose_config() {
  local env_file="$1"
  local output_file="$2"

  docker compose --env-file "$env_file" config --format json >"$output_file"
}

validate_rendered_config() {
  local compose_json="$1"
  local scenario="$2"

  ruby - "$compose_json" "$scenario" <<'RUBY'
require "json"
require "yaml"

compose_json, scenario = ARGV
compose = JSON.parse(File.read(compose_json))
content = compose.fetch("configs").fetch("pingvin_config").fetch("content")
config = YAML.safe_load(content, aliases: false)

abort "pingvin_config did not parse to a YAML mapping" unless config.is_a?(Hash)

string_paths = [
  %w[general appName],
  %w[general appUrl],
  %w[general secureCookies],
  %w[general showHomePage],
  %w[general sessionDuration],
  %w[appearance customCss],
  %w[share allowRegistration],
  %w[share allowUnauthenticatedShares],
  %w[share maxSize],
  %w[email enableShareEmailRecipients],
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
  value = config.fetch(category).fetch(key)
  abort "#{category}.#{key} must render as a YAML string, got #{value.class}" unless value.is_a?(String)
end

boolean_paths = [
  %w[initUser enabled],
  %w[initUser isAdmin]
]

boolean_paths.each do |category, key|
  value = config.fetch(category).fetch(key)
  abort "#{category}.#{key} must render as a YAML boolean, got #{value.class}" unless value == true || value == false
end

if scenario == "override"
  expectations = {
    %w[general appName] => "Example Transfer",
    %w[general appUrl] => "https://files.example.test",
    %w[smtp email] => "sender@example.test",
    %w[smtp username] => "smtp-login@example.test",
    %w[oauth oidc-usernameClaim] => "preferred_username"
  }

  expectations.each do |path, expected|
    category, key = path
    actual = config.fetch(category).fetch(key)
    abort "#{category}.#{key} expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
  end
end
RUBY
}

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  exit 1
fi

render_compose_config "$ENV_FILE" "$BASE_CONFIG_JSON"
validate_rendered_config "$BASE_CONFIG_JSON" "base"

cat >"$OVERRIDE_ENV" <<'EOF'
APP_HOSTNAME=files.example.test
APP_NAME=Example Transfer
SMTP_EMAIL=sender@example.test
SMTP_USERNAME=smtp-login@example.test
OIDC_USERNAME_CLAIM=preferred_username
EOF

render_compose_config "$OVERRIDE_ENV" "$OVERRIDE_CONFIG_JSON"
validate_rendered_config "$OVERRIDE_CONFIG_JSON" "override"

echo "Rendered Pingvin config is valid."
