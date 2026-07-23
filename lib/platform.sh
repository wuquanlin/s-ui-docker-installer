#!/usr/bin/env bash

detect_platform() {
  local os_release_file="${1:-/etc/os-release}"
  [[ -r "$os_release_file" ]] || die "无法读取 ${os_release_file}"

  OS_ID=""
  OS_ID_LIKE=""
  OS_VERSION_ID=""
  OS_CODENAME=""
  OS_PRETTY=""

  # shellcheck disable=SC1090
  . "$os_release_file"
  OS_ID="${ID:-}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  OS_PRETTY="${PRETTY_NAME:-${OS_ID} ${OS_VERSION_ID}}"

  case "$OS_ID" in
    debian|ubuntu|linuxmint|raspbian|kali)
      PACKAGE_FAMILY="apt"
      ;;
    rhel|centos|rocky|almalinux|fedora|ol|opencloudos|anolis|alinux|openeuler)
      PACKAGE_FAMILY="rpm"
      ;;
    *)
      case " ${OS_ID_LIKE} " in
        *" debian "*|*" ubuntu "*) PACKAGE_FAMILY="apt" ;;
        *" rhel "*|*" fedora "*|*" centos "*) PACKAGE_FAMILY="rpm" ;;
        *) die "暂不支持此系统：${OS_PRETTY}" ;;
      esac
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) SYSTEM_ARCH="amd64" ;;
    aarch64|arm64) SYSTEM_ARCH="arm64" ;;
    armv7l) SYSTEM_ARCH="armv7" ;;
    armv6l) SYSTEM_ARCH="armv6" ;;
    i386|i686) SYSTEM_ARCH="386" ;;
    s390x) SYSTEM_ARCH="s390x" ;;
    *) die "暂不支持此 CPU 架构：$(uname -m)" ;;
  esac

  if [[ "$PACKAGE_FAMILY" == "apt" && -z "$OS_CODENAME" ]]; then
    if command_exists lsb_release; then
      OS_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
    fi
    [[ -n "$OS_CODENAME" ]] || die "无法识别系统代号（codename）"
  fi
}

install_base_packages() {
  log "安装基础依赖"
  if [[ "$PACKAGE_FAMILY" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    retry 3 3 apt-get update
    apt-get install -y \
      ca-certificates curl gnupg jq openssl python3 sqlite3 tar iproute2 procps
  else
    local pm="dnf"
    command_exists dnf || pm="yum"
    "$pm" -y install \
      ca-certificates curl gnupg2 jq openssl python3 sqlite tar iproute procps-ng
  fi
}

platform_summary() {
  printf '%s | %s | %s' "$OS_PRETTY" "$PACKAGE_FAMILY" "$SYSTEM_ARCH"
}
