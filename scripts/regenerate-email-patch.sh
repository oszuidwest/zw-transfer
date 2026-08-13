#!/usr/bin/env bash
#
# Regenerate patches/email.service.js by extracting the compiled email.service.js
# from the pinned Pingvin Share X image and applying patches/email.service.patch.
#
# The generated file is bind-mounted over Pingvin's compiled email service to
# support this deployment's share-recipient template:
#   - {descBlock} expands to ' en dit bericht werd toegevoegd: "...".' when a
#     share description exists, or to '.' when it does not.
#   - Shares without an expiration date render {expires} as "nooit", so the
#     template sentence reads "De link verloopt nooit."
#
# Run this whenever the image tag in docker-compose.yml is bumped.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
PATCH_FILE="${REPO_ROOT}/patches/email.service.patch"
OUTPUT_FILE="${REPO_ROOT}/patches/email.service.js"
TARGET_PATH="/opt/app/backend/dist/src/email/email.service.js"

IMAGE="$(grep -oE 'ghcr\.io/smp46/pingvin-share-x:v[0-9.]+' "$COMPOSE_FILE" | head -n1)"
if [[ -z "$IMAGE" ]]; then
  echo "ERROR: could not find pingvin-share-x image pin in $COMPOSE_FILE" >&2
  exit 1
fi

if [[ ! -f "$PATCH_FILE" ]]; then
  echo "ERROR: patch file not found: $PATCH_FILE" >&2
  exit 1
fi

echo "Using image: $IMAGE"
docker pull --quiet "$IMAGE" >/dev/null

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CID="$(docker create "$IMAGE")"
docker cp "${CID}:${TARGET_PATH}" "${TMP_DIR}/email.service.js"
docker rm --force "$CID" >/dev/null

# Apply the unified diff. patch(1) fuzzes context if upstream line numbers
# shifted; it exits non-zero on rejected hunks so we will hear about real
# upstream drift.
patch --no-backup-if-mismatch -d "$TMP_DIR" -p1 -i "$PATCH_FILE"

mkdir -p "$(dirname "$OUTPUT_FILE")"
cp "${TMP_DIR}/email.service.js" "$OUTPUT_FILE"

# Belt-and-suspenders: confirm the local descBlock/nooit behavior actually
# landed, while preserving upstream i18n fallback handling.
verify_present() {
  local needle="$1"
  if ! grep -qF -- "$needle" "$OUTPUT_FILE"; then
    echo "ERROR: expected substring missing from patched file: $needle" >&2
    exit 1
  fi
}

verify_absent() {
  local needle="$1"
  if grep -qF -- "$needle" "$OUTPUT_FILE"; then
    echo "ERROR: pre-patch substring still present in patched file: $needle" >&2
    exit 1
  fi
}

verify_present 'const trimmedDesc = (description ?? "").trim()'
verify_present 'en dit bericht werd toegevoegd:'
verify_present 'this.i18n.t("email.shareRecipientsCreatorFallback")'
verify_present '.replaceAll("{desc}", description ?? this.i18n.t("email.shareRecipientsDescFallback"))'
verify_present '.replaceAll("{descBlock}", descBlock)'
verify_present 'moment(expiration).locale(locale).fromNow()'
verify_present ': "nooit"), replyTo);'

verify_absent '?? "Someone"'
verify_absent '?? "No description"'
verify_absent '"in: never"'
verify_absent 'this.i18n.t("email.shareRecipientsExpiresNeverFallback")'

echo "Wrote patched file to: $OUTPUT_FILE"
