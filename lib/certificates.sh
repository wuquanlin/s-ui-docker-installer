#!/usr/bin/env bash

SKIP_CERT_HOST_CHECK="${SKIP_CERT_HOST_CHECK:-0}"

certificate_matches_key() {
  local cert="$1"
  local key="$2"
  local cert_hash=""
  local key_hash=""
  cert_hash="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null |
    openssl pkey -pubin -outform pem 2>/dev/null |
    sha256sum | awk '{print $1}')"
  key_hash="$(openssl pkey -in "$key" -passin pass: \
    -pubout -outform pem 2>/dev/null |
    sha256sum | awk '{print $1}')"
  [[ -n "$cert_hash" && "$cert_hash" == "$key_hash" ]]
}

certificate_matches_domain() {
  local cert="$1"
  openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" 2>/dev/null |
    grep -q 'does match'
}

certificate_file_is_valid() {
  local cert="$1"
  CERT_VALIDATION_ERROR=""

  if [[ ! -f "$cert" ]]; then
    CERT_VALIDATION_ERROR="证书文件不存在：${cert}"
    return 1
  fi
  if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
    CERT_VALIDATION_ERROR="证书不是有效的 PEM/X.509 文件：${cert}"
    return 1
  fi
  if ! openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1; then
    CERT_VALIDATION_ERROR="证书已经过期：${cert}"
    return 1
  fi
  if [[ "$SKIP_CERT_HOST_CHECK" != "1" ]] &&
     ! certificate_matches_domain "$cert"; then
    CERT_VALIDATION_ERROR="证书不匹配域名 ${DOMAIN}：${cert}"
    return 1
  fi
}

private_key_file_is_valid() {
  local key="$1"
  KEY_VALIDATION_ERROR=""

  if [[ ! -f "$key" ]]; then
    KEY_VALIDATION_ERROR="私钥文件不存在：${key}"
    return 1
  fi
  if ! openssl pkey -in "$key" -passin pass: -noout >/dev/null 2>&1; then
    KEY_VALIDATION_ERROR="私钥不是可无人值守读取的有效 PEM：${key}"
    return 1
  fi
}

certificate_pair_is_valid() {
  local cert="$1"
  local key="$2"
  PAIR_VALIDATION_ERROR=""

  certificate_file_is_valid "$cert" || {
    PAIR_VALIDATION_ERROR="$CERT_VALIDATION_ERROR"
    return 1
  }
  private_key_file_is_valid "$key" || {
    PAIR_VALIDATION_ERROR="$KEY_VALIDATION_ERROR"
    return 1
  }
  if ! certificate_matches_key "$cert" "$key"; then
    PAIR_VALIDATION_ERROR="证书和私钥不匹配"
    return 1
  fi
}

try_certificate_pair() {
  local cert="$1"
  local key="$2"
  certificate_pair_is_valid "$cert" "$key" || return 1
  CERT_SRC="$cert"
  KEY_SRC="$key"
}

detect_certificate_pair() {
  [[ -z "$CERT_SRC" && -z "$KEY_SRC" ]] || return 0

  local pair=""
  while IFS='|' read -r cert key; do
    [[ -n "$cert" ]] || continue
    if try_certificate_pair "$cert" "$key"; then
      CERT_DISCOVERY_REASON="自动发现匹配 ${DOMAIN} 的证书"
      return 0
    fi
  done <<EOF
/etc/letsencrypt/live/${DOMAIN}/fullchain.pem|/etc/letsencrypt/live/${DOMAIN}/privkey.pem
/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer|/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key
/root/.acme.sh/${DOMAIN}/fullchain.cer|/root/.acme.sh/${DOMAIN}/${DOMAIN}.key
/root/${DOMAIN}.pem|/root/${DOMAIN}.key
/root/fullchain.pem|/root/privkey.pem
${SCRIPT_DIR}/certs/live/fullchain.pem|${SCRIPT_DIR}/certs/live/private.key
EOF

  for pair in /root/*.pem /root/*.crt /root/*.cer; do
    [[ -f "$pair" ]] || continue
    local candidate_key=""
    for candidate_key in \
      "${pair%.*}.key" \
      /root/privkey.pem \
      /root/*.key; do
      [[ -f "$candidate_key" ]] || continue
      if try_certificate_pair "$pair" "$candidate_key"; then
        CERT_DISCOVERY_REASON="扫描 /root 后发现匹配证书"
        return 0
      fi
    done
  done
  return 1
}

generate_self_signed_certificate() {
  local cert_dir="/var/lib/s-ui-installer/generated-certs/${DOMAIN}"
  install -m 0700 -d "$cert_dir"
  CERT_SRC="${cert_dir}/fullchain.pem"
  KEY_SRC="${cert_dir}/private.key"

  openssl req -x509 -newkey rsa:3072 -sha256 -nodes \
    -days 825 \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN}" \
    -keyout "$KEY_SRC" \
    -out "$CERT_SRC" >/dev/null 2>&1
  chmod 0600 "$KEY_SRC"
  chmod 0644 "$CERT_SRC"
  CERT_DISCOVERY_REASON="未发现可用证书，已生成自签名证书"
  SELF_SIGNED_CERT=1
}

resolve_certificates() {
  # Used by install.sh after this library has been sourced.
  # shellcheck disable=SC2034
  SELF_SIGNED_CERT=0
  # Used by install.sh and sui.sh after this library has been sourced.
  # shellcheck disable=SC2034
  CERT_DISCOVERY_REASON=""

  if [[ -n "$CERT_SRC" || -n "$KEY_SRC" ]]; then
    [[ -n "$CERT_SRC" && -n "$KEY_SRC" ]] ||
      die "--cert 与 --key 必须同时提供"
    CERT_DISCOVERY_REASON="用户指定"
  elif [[ "$CERT_MODE" == "example" ]]; then
    [[ "${ALLOW_BUNDLED_EXAMPLE_CERT:-0}" == "1" ]] ||
      die "示例私钥仅用于测试；请同时设置 ALLOW_BUNDLED_EXAMPLE_CERT=1"
    CERT_SRC="${SCRIPT_DIR}/certs/examples/development-fullchain.pem"
    KEY_SRC="${SCRIPT_DIR}/certs/examples/development-private.key"
    # shellcheck disable=SC2034
    CERT_DISCOVERY_REASON="使用仓库内开发示例证书"
  elif [[ "$CERT_MODE" == "self-signed" ]]; then
    generate_self_signed_certificate
  elif ! detect_certificate_pair; then
    warn "没有发现匹配 ${DOMAIN} 的正式证书"
    if is_interactive; then
      if prompt_yes_no "是否生成自签名证书以完成安装" "y"; then
        generate_self_signed_certificate
      else
        die "请准备证书后用 --cert 与 --key 重新运行"
      fi
    else
      generate_self_signed_certificate
    fi
  fi

  if [[ "$CERT_MODE" == "example" ]]; then
    [[ -f "$CERT_SRC" && -f "$KEY_SRC" ]] ||
      die "开发示例证书不完整"
    openssl x509 -in "$CERT_SRC" -noout >/dev/null 2>&1 ||
      die "开发示例证书无效"
    private_key_file_is_valid "$KEY_SRC" ||
      die "$KEY_VALIDATION_ERROR"
    certificate_matches_key "$CERT_SRC" "$KEY_SRC" ||
      die "开发示例证书和私钥不匹配"
    warn "开发示例证书不会匹配真实域名"
  else
    certificate_pair_is_valid "$CERT_SRC" "$KEY_SRC" ||
      die "$PAIR_VALIDATION_ERROR"
  fi

  if ! openssl x509 -checkend 1209600 -noout -in "$CERT_SRC" >/dev/null 2>&1; then
    warn "证书将在 14 天内过期"
  fi
}

certificate_summary() {
  openssl x509 -in "$CERT_SRC" -noout \
    -subject -issuer -dates -ext subjectAltName 2>/dev/null || true
}
