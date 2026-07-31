#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "${ROOT}/lib/common.sh"
# shellcheck source=lib/network.sh
. "${ROOT}/lib/network.sh"
# shellcheck source=lib/certificates.sh
. "${ROOT}/lib/certificates.sh"

assert_fails() {
  if "$@"; then
    printf 'Expected command to fail: %s\n' "$*" >&2
    return 1
  fi
}

domain_is_valid "edge.example.com"
domain_is_valid "panel.example.com"
assert_fails domain_is_valid "localhost"
assert_fails domain_is_valid "-panel.example.com"
assert_fails domain_is_valid "panel_.example.com"
assert_fails domain_is_valid "panel..example.com"

EXPECTED_PUBLIC_IP="2001:0db8::10"
[[ "$(discover_public_ips)" == "2001:db8::10" ]]
assert_fails normalize_ip "not-an-ip" >/dev/null 2>&1

DOMAIN="edge.example.com"
EXPECTED_PUBLIC_IP=""
SKIP_DOMAIN_IP_CHECK=0
resolve_domain_ips() {
  printf '%s\n' "122.51.110.155" "2001:db8::10"
}
discover_public_ips() {
  printf '%s\n' "122.51.110.155"
}
check_domain_points_to_server
[[ "$DOMAIN_DNS_IPS" == *"122.51.110.155"* ]]

discover_public_ips() {
  printf '%s\n' "203.0.113.20"
}
assert_fails check_domain_points_to_server
[[ "$DOMAIN_IP_VALIDATION_ERROR" == *"不匹配"* ]]

DOMAIN="s-ui-installer.invalid"
SKIP_CERT_HOST_CHECK=0
certificate_file_is_valid \
  "${ROOT}/certs/examples/development-fullchain.pem"
private_key_file_is_valid \
  "${ROOT}/certs/examples/development-private.key"
certificate_pair_is_valid \
  "${ROOT}/certs/examples/development-fullchain.pem" \
  "${ROOT}/certs/examples/development-private.key"

assert_fails certificate_file_is_valid "${ROOT}/does-not-exist.pem"
[[ "$CERT_VALIDATION_ERROR" == *"不存在"* ]]
assert_fails private_key_file_is_valid "${ROOT}/does-not-exist.key"
[[ "$KEY_VALIDATION_ERROR" == *"不存在"* ]]

printf 'input validation tests: PASS\n'
