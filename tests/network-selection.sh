#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "${ROOT}/lib/common.sh"
# shellcheck source=lib/network.sh
. "${ROOT}/lib/network.sh"
# shellcheck source=lib/docker.sh
. "${ROOT}/lib/docker.sh"

REGION_MODE=auto
detect_cloud_vendor() {
  CLOUD_VENDOR="tencent"
  CHINA_SOURCE_HINT=1
}
detect_network_profile
[[ "$DETECTED_REGION" == "china" && "$CLOUD_VENDOR" == "tencent" ]]
select_download_sources
[[ "$DOCKER_REPO_BASE" == "https://mirrors.tencent.com/docker-ce" ]]
[[ "$SELECTED_DOCKER_MIRROR" == "https://mirror.ccs.tencentyun.com" ]]

detect_cloud_vendor() {
  CLOUD_VENDOR="unknown"
  CHINA_SOURCE_HINT=0
}
probe_url() {
  case "$1" in
    *mirrors.aliyun.com*|*mirrors.tencent.com*) return 0 ;;
    *) return 1 ;;
  esac
}
DOCKER_REPO_BASE=""
SELECTED_DOCKER_MIRROR=""
DOCKER_REGISTRY_MIRROR=""
DOCKER_REPO_BASE_OVERRIDE=""
detect_network_profile
[[ "$DETECTED_REGION" == "china" && "$CLOUD_VENDOR" == "unknown" ]]
select_download_sources
[[ "$DOCKER_REPO_BASE" == "https://mirrors.aliyun.com/docker-ce" ]]
[[ "$SELECTED_DOCKER_MIRROR" == "https://docker.m.daocloud.io" ]]

probe_url() { return 0; }
detect_network_profile
[[ "$DETECTED_REGION" == "global" ]]

PACKAGE_FAMILY=apt
OS_ID=ubuntu
[[ "$(docker_repo_os)" == "ubuntu" ]]
OS_ID=debian
[[ "$(docker_repo_os)" == "debian" ]]
PACKAGE_FAMILY=rpm
OS_ID=rocky
[[ "$(docker_repo_os)" == "centos" ]]
OS_ID=fedora
[[ "$(docker_repo_os)" == "fedora" ]]

printf 'network selection tests: PASS\n'
