#!/usr/bin/env bash
# Cross-library state is consumed by docker.sh after all libraries are sourced.
# shellcheck disable=SC2034

PYTHON_BIN="${PYTHON_BIN:-python3}"
DOMAIN="${DOMAIN:-}"

read_machine_identity() {
  local identity=""
  local file=""
  for file in \
    /sys/class/dmi/id/sys_vendor \
    /sys/class/dmi/id/product_name \
    /sys/class/dmi/id/board_vendor; do
    [[ -r "$file" ]] && identity+=" $(tr '\n' ' ' <"$file")"
  done
  printf '%s' "$identity"
}

detect_cloud_vendor() {
  local machine_evidence=""
  local source_evidence=""
  local evidence=""
  machine_evidence="$(read_machine_identity)"
  if [[ -r /etc/apt/sources.list ]]; then
    source_evidence+=" $(< /etc/apt/sources.list)"
  fi
  if [[ -d /etc/apt/sources.list.d ]]; then
    source_evidence+=" $(grep -RhsE '^[[:space:]]*(deb|URIs:)' /etc/apt/sources.list.d 2>/dev/null || true)"
  fi
  evidence="${machine_evidence} ${source_evidence}"
  evidence="${evidence,,}"
  source_evidence="${source_evidence,,}"
  CHINA_SOURCE_HINT=0
  case "$source_evidence" in
    *tencentyun.com*|*mirrors.tencent.com*|*mirrors.aliyun.com*|*huaweicloud.com*)
      CHINA_SOURCE_HINT=1
      ;;
  esac

  case "$evidence" in
    *tencent*|*qcloud*) CLOUD_VENDOR="tencent" ;;
    *alibaba*|*aliyun*) CLOUD_VENDOR="alibaba" ;;
    *huawei*) CLOUD_VENDOR="huawei" ;;
    *) CLOUD_VENDOR="unknown" ;;
  esac
}

probe_url() {
  local url="$1"
  curl -4 -fsSIL \
    --connect-timeout "${PROBE_CONNECT_TIMEOUT:-3}" \
    --max-time "${PROBE_MAX_TIME:-6}" \
    "$url" >/dev/null 2>&1
}

normalize_ip() {
  local value="$1"
  "$PYTHON_BIN" - "$value" <<'PY'
import ipaddress
import sys

try:
    print(ipaddress.ip_address(sys.argv[1].strip()))
except ValueError:
    raise SystemExit(1)
PY
}

ip_is_public() {
  local value="$1"
  "$PYTHON_BIN" - "$value" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1].strip())
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address.is_global else 1)
PY
}

resolve_domain_ips() {
  local domain="$1"
  {
    getent ahostsv4 "$domain" 2>/dev/null || true
    getent ahostsv6 "$domain" 2>/dev/null || true
  } | awk '{print $1}' | sort -u
}

discover_public_ips() {
  local candidate=""
  local normalized=""
  local family=""
  local url=""
  local found_v4=0
  local found_v6=0

  if [[ -n "${EXPECTED_PUBLIC_IP:-}" ]]; then
    normalize_ip "$EXPECTED_PUBLIC_IP"
    return
  fi

  while IFS='|' read -r family url; do
    if [[ "$family" == "-4" && "$found_v4" == "1" ]] ||
       [[ "$family" == "-6" && "$found_v6" == "1" ]]; then
      continue
    fi
    candidate="$(curl "$family" -fsS --noproxy '*' \
      --connect-timeout 3 --max-time 5 "$url" 2>/dev/null |
      tr -d '[:space:]' || true)"
    normalized="$(normalize_ip "$candidate" 2>/dev/null || true)"
    [[ -n "$normalized" ]] || continue
    printf '%s\n' "$normalized"
    if [[ "$family" == "-4" ]]; then
      found_v4=1
    else
      found_v6=1
    fi
  done <<'EOF'
-4|https://api.ipify.org
-4|https://4.ipw.cn
-6|https://api6.ipify.org
-6|https://6.ipw.cn
EOF

  if [[ "$found_v4" == "0" && "$found_v6" == "0" ]]; then
    while IFS= read -r candidate; do
      candidate="${candidate%/*}"
      normalized="$(normalize_ip "$candidate" 2>/dev/null || true)"
      [[ -n "$normalized" ]] || continue
      ip_is_public "$normalized" || continue
      printf '%s\n' "$normalized"
    done < <(ip -o addr show scope global 2>/dev/null | awk '{print $4}')
  fi
}

ip_lists_intersect() {
  local first="$1"
  local second="$2"
  FIRST_IP_LIST="$first" SECOND_IP_LIST="$second" "$PYTHON_BIN" <<'PY'
import ipaddress
import os

def addresses(name):
    result = set()
    for value in os.environ.get(name, "").split():
        try:
            result.add(ipaddress.ip_address(value))
        except ValueError:
            pass
    return result

raise SystemExit(0 if addresses("FIRST_IP_LIST") & addresses("SECOND_IP_LIST") else 1)
PY
}

check_domain_points_to_server() {
  DOMAIN_DNS_IPS="$(resolve_domain_ips "$DOMAIN")"
  SERVER_PUBLIC_IPS="$(discover_public_ips)"
  DOMAIN_IP_VALIDATION_ERROR=""

  if [[ -z "$DOMAIN_DNS_IPS" ]]; then
    DOMAIN_IP_VALIDATION_ERROR="域名 ${DOMAIN} 没有可用的 A/AAAA 解析记录"
    return 1
  fi
  if [[ -z "$SERVER_PUBLIC_IPS" ]]; then
    DOMAIN_IP_VALIDATION_ERROR="无法检测本机公网 IP；可用 --expected-ip IP 明确指定"
    return 1
  fi
  if ! ip_lists_intersect "$DOMAIN_DNS_IPS" "$SERVER_PUBLIC_IPS"; then
    DOMAIN_IP_VALIDATION_ERROR="域名 ${DOMAIN} 解析为 [$(tr '\n' ' ' <<<"$DOMAIN_DNS_IPS" | xargs)]，本机公网 IP 为 [$(tr '\n' ' ' <<<"$SERVER_PUBLIC_IPS" | xargs)]，两者不匹配"
    return 1
  fi
}

validate_domain_points_to_server() {
  if [[ "${DOMAIN_IP_VALIDATED:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${SKIP_DOMAIN_IP_CHECK:-0}" == "1" ]]; then
    warn "已跳过域名到本机公网 IP 的校验"
    DOMAIN_IP_VALIDATED=1
    return 0
  fi
  check_domain_points_to_server ||
    die "${DOMAIN_IP_VALIDATION_ERROR}；如使用 CDN/反向代理，可明确传入 --skip-domain-ip-check"
  info "域名解析校验通过：$(tr '\n' ' ' <<<"$DOMAIN_DNS_IPS" | xargs)"
  DOMAIN_IP_VALIDATED=1
}

detect_network_profile() {
  detect_cloud_vendor

  if [[ "$REGION_MODE" == "china" || "$REGION_MODE" == "global" ]]; then
    DETECTED_REGION="$REGION_MODE"
    REGION_REASON="用户指定"
    return 0
  fi

  if [[ "$CHINA_SOURCE_HINT" == "1" ]]; then
    DETECTED_REGION="china"
    REGION_REASON="系统正在使用中国云镜像源"
    return 0
  fi

  local global_ok=0
  local china_ok=0
  local url=""

  for url in \
    https://registry-1.docker.io/v2/ \
    https://download.docker.com/linux/ \
    https://api.github.com/; do
    probe_url "$url" && global_ok=$((global_ok + 1))
  done

  for url in \
    https://mirrors.aliyun.com/ \
    https://mirrors.tencent.com/; do
    probe_url "$url" && china_ok=$((china_ok + 1))
  done

  if (( global_ok <= 1 && china_ok >= 1 )); then
    DETECTED_REGION="china"
    REGION_REASON="境外关键资源多数不可达，国内镜像可达"
  else
    DETECTED_REGION="global"
    REGION_REASON="境外关键资源可达"
  fi
}

select_download_sources() {
  DOCKER_REPO_BASE="${DOCKER_REPO_BASE:-https://download.docker.com}"
  # Used by docker.sh after this library has been sourced.
  # shellcheck disable=SC2034
  SELECTED_DOCKER_MIRROR="${DOCKER_REGISTRY_MIRROR:-}"
  GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"

  [[ "$DETECTED_REGION" == "china" ]] || return 0

  case "$CLOUD_VENDOR" in
    tencent)
      DOCKER_REPO_BASE="${DOCKER_REPO_BASE_OVERRIDE:-https://mirrors.tencent.com/docker-ce}"
      SELECTED_DOCKER_MIRROR="${DOCKER_REGISTRY_MIRROR:-https://mirror.ccs.tencentyun.com}"
      ;;
    alibaba)
      DOCKER_REPO_BASE="${DOCKER_REPO_BASE_OVERRIDE:-https://mirrors.aliyun.com/docker-ce}"
      SELECTED_DOCKER_MIRROR="${DOCKER_REGISTRY_MIRROR:-https://docker.m.daocloud.io}"
      ;;
    huawei)
      DOCKER_REPO_BASE="${DOCKER_REPO_BASE_OVERRIDE:-https://repo.huaweicloud.com/docker-ce}"
      SELECTED_DOCKER_MIRROR="${DOCKER_REGISTRY_MIRROR:-https://docker.m.daocloud.io}"
      ;;
    *)
      DOCKER_REPO_BASE="${DOCKER_REPO_BASE_OVERRIDE:-https://mirrors.aliyun.com/docker-ce}"
      SELECTED_DOCKER_MIRROR="${DOCKER_REGISTRY_MIRROR:-https://docker.m.daocloud.io}"
      ;;
  esac
}

network_summary() {
  printf '%s | vendor=%s | %s' "$DETECTED_REGION" "$CLOUD_VENDOR" "$REGION_REASON"
}
