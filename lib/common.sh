#!/usr/bin/env bash

log() {
  printf '\n\033[1;32m[+]\033[0m %s\n' "$*"
}

info() {
  printf '    %s\n' "$*"
}

warn() {
  printf '\n\033[1;33m[!]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\n\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行：sudo $0 $*"
}

is_interactive() {
  [[ "${NONINTERACTIVE:-0}" != "1" && -t 0 && -t 1 ]]
}

prompt_value() {
  local label="$1"
  local default_value="${2:-}"
  local required="${3:-1}"
  local answer=""

  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "${label} [${default_value}]: " answer
      answer="${answer:-$default_value}"
    else
      read -r -p "${label}: " answer
    fi
    if [[ -n "$answer" || "$required" == "0" ]]; then
      printf '%s' "$answer"
      return 0
    fi
    printf '  此项必填。\n' >&2
  done
}

prompt_secret() {
  local label="$1"
  local answer=""
  read -r -s -p "${label}: " answer
  printf '\n' >&2
  printf '%s' "$answer"
}

prompt_yes_no() {
  local label="$1"
  local default_value="${2:-n}"
  local answer=""
  local suffix="[y/N]"
  [[ "$default_value" == "y" ]] && suffix="[Y/n]"
  read -r -p "${label} ${suffix}: " answer
  answer="${answer:-$default_value}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

retry() {
  local attempts="$1"
  local delay="$2"
  shift 2
  local count=1

  until "$@"; do
    if (( count >= attempts )); then
      return 1
    fi
    warn "命令失败，${delay} 秒后重试（${count}/${attempts}）"
    sleep "$delay"
    count=$((count + 1))
  done
}

validate_port() {
  local value="$1"
  local name="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "${name} 不是有效端口：${value}"
  (( value >= 1 && value <= 65535 )) || die "${name} 超出范围：${value}"
}

domain_is_valid() {
  local value="$1"
  local label=""
  local -a labels=()

  [[ ${#value} -le 253 && "$value" == *.* && "$value" != *..* ]] ||
    return 1
  IFS='.' read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
      return 1
  done
}

validate_domain() {
  local value="$1"
  domain_is_valid "$value" ||
    die "域名格式无效：${value}（必须是完整域名，且每个标签只能包含字母、数字和连字符）"
}

validate_http_url() {
  local value="$1"
  local name="$2"
  [[ "$value" =~ ^https?://[A-Za-z0-9._:/-]+$ ]] ||
    die "${name} 不是安全的 HTTP(S) URL：${value}"
}

timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

redact_url() {
  printf '%s' "$1" | sed -E 's#(https?://)[^/@]+@#\1***@#'
}
