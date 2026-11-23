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
TEST_FILE="${REPO_ROOT}/scripts/test-email-patch.cjs"
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

# Exercise the generated service with the pinned image's dependencies. SMTP is
# intercepted by the tests, and the container has no network or persistent data.
docker run --rm --network none --entrypoint node \
  --mount "type=bind,src=${TMP_DIR}/email.service.js,dst=${TARGET_PATH},readonly" \
  --mount "type=bind,src=${TEST_FILE},dst=/tmp/test-email-patch.cjs,readonly" \
  "$IMAGE" --test /tmp/test-email-patch.cjs

cp "${TMP_DIR}/email.service.js" "$OUTPUT_FILE"

echo "Wrote patched file to: $OUTPUT_FILE"
