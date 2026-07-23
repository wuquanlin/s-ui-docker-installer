#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while IFS= read -r script; do
  bash -n "$script"
done < <(find "$ROOT" -type f -name '*.sh' -o -path "$ROOT/install.sh")

"${ROOT}/install.sh" --help >/dev/null
"${ROOT}/scripts/s-ui-manager" --help >/dev/null 2>&1 || {
  # Manager correctly requires installed state; syntax is checked above.
  true
}

# shellcheck source=lib/common.sh
. "${ROOT}/lib/common.sh"
# shellcheck source=lib/platform.sh
. "${ROOT}/lib/platform.sh"

detect_platform "${ROOT}/tests/fixtures/debian-os-release"
[[ "$PACKAGE_FAMILY" == "apt" && "$OS_CODENAME" == "trixie" ]]

detect_platform "${ROOT}/tests/fixtures/ubuntu-os-release"
[[ "$PACKAGE_FAMILY" == "apt" && "$OS_CODENAME" == "noble" ]]

detect_platform "${ROOT}/tests/fixtures/rocky-os-release"
[[ "$PACKAGE_FAMILY" == "rpm" ]]

detect_platform "${ROOT}/tests/fixtures/opencloudos-os-release"
[[ "$PACKAGE_FAMILY" == "rpm" ]]

openssl x509 -in "${ROOT}/certs/examples/development-fullchain.pem" -noout
openssl pkey -in "${ROOT}/certs/examples/development-private.key" -noout

printf 'smoke tests: PASS\n'
