#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

SEARCH_ROOT="${TEST_ROOT}/root"
SUI_TEST_DIR="${TEST_ROOT}/s-ui"
BACKUP_TEST_ROOT="${TEST_ROOT}/backups"
CONFIG="${TEST_ROOT}/config.env"
DOMAIN="s-ui-installer.invalid"
mkdir -p "$SEARCH_ROOT" "${SUI_TEST_DIR}/cert" "${SUI_TEST_DIR}/db" "$BACKUP_TEST_ROOT"

cp "${ROOT}/certs/examples/development-fullchain.pem" \
  "${SEARCH_ROOT}/${DOMAIN}.pem"
cp "${ROOT}/certs/examples/development-private.key" \
  "${SEARCH_ROOT}/${DOMAIN}.key"
cp "${SEARCH_ROOT}/${DOMAIN}.pem" "${SUI_TEST_DIR}/cert/fullchain.pem"
cp "${SEARCH_ROOT}/${DOMAIN}.key" "${SUI_TEST_DIR}/cert/private.key"

cat >"$CONFIG" <<EOF
SUI_DIR=${SUI_TEST_DIR}
DOMAIN=${DOMAIN}
WEB_PORT=2095
SUB_PORT=2096
WEB_PATH=/app/
SUB_PATH=/sub/
CERT_SOURCE=/var/lib/s-ui-installer/generated-certs/${DOMAIN}/fullchain.pem
KEY_SOURCE=/var/lib/s-ui-installer/generated-certs/${DOMAIN}/private.key
CERT_DEST=${SUI_TEST_DIR}/cert/fullchain.pem
KEY_DEST=${SUI_TEST_DIR}/cert/private.key
CERT_IN_CONTAINER=/app/cert/fullchain.pem
KEY_IN_CONTAINER=/app/cert/private.key
SUI_VERSION=v1.5.4
DETECTED_REGION=global
BACKUP_ROOT=${BACKUP_TEST_ROOT}
EOF
chmod 0600 "$CONFIG"

status_output="$(SUI_MANAGER_CONFIG="$CONFIG" CERT_SEARCH_ROOT="$SEARCH_ROOT" \
  "${ROOT}/scripts/s-ui-manager" cert-status)"
grep -q "Installed cert:     ${SUI_TEST_DIR}/cert/fullchain.pem (readable)" \
  <<<"$status_output"
grep -q "Container cert:     /app/cert/fullchain.pem (unavailable)" \
  <<<"$status_output"
grep -q "Container key:      /app/cert/private.key (unavailable)" \
  <<<"$status_output"

auto_output="$(SUI_MANAGER_CONFIG="$CONFIG" CERT_SEARCH_ROOT="$SEARCH_ROOT" \
  "${ROOT}/scripts/s-ui-manager" cert-auto)"
grep -q "Certificate content is already installed" <<<"$auto_output"

# shellcheck disable=SC1090
. "$CONFIG"
[[ "$CERT_SOURCE" == "${SEARCH_ROOT}/${DOMAIN}.pem" ]]
[[ "$KEY_SOURCE" == "${SEARCH_ROOT}/${DOMAIN}.key" ]]

sync_output="$(SUI_MANAGER_CONFIG="$CONFIG" CERT_SEARCH_ROOT="$SEARCH_ROOT" \
  "${ROOT}/scripts/s-ui-manager" cert-sync)"
grep -q "Certificate content is already installed" <<<"$sync_output"

printf 'certificate management tests: PASS\n'
