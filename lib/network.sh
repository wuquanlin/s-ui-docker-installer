#!/usr/bin/env bash
# Cross-library state is consumed by docker.sh after all libraries are sourced.
# shellcheck disable=SC2034

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
