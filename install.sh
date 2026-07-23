#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/platform.sh
. "${SCRIPT_DIR}/lib/platform.sh"
# shellcheck source=lib/network.sh
. "${SCRIPT_DIR}/lib/network.sh"
# shellcheck source=lib/docker.sh
. "${SCRIPT_DIR}/lib/docker.sh"
# shellcheck source=lib/certificates.sh
. "${SCRIPT_DIR}/lib/certificates.sh"
# shellcheck source=lib/sui.sh
. "${SCRIPT_DIR}/lib/sui.sh"

if [[ -r "${SCRIPT_DIR}/config/defaults.env" ]]; then
  # shellcheck source=config/defaults.env
  . "${SCRIPT_DIR}/config/defaults.env"
fi

DOMAIN="${DOMAIN:-}"
OLD_DOMAIN="${OLD_DOMAIN:-}"
CERT_SRC="${CERT_SRC:-}"
KEY_SRC="${KEY_SRC:-}"
CERT_MODE="${CERT_MODE:-auto}"
DB_SRC="${DB_SRC:-}"
SUI_DIR="${SUI_DIR:-/opt/s-ui}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/s-ui-installer}"

SUI_VERSION="${SUI_VERSION:-latest}"
SUI_FALLBACK_VERSION="${SUI_FALLBACK_VERSION:-v1.5.4}"
SUI_IMAGE=""
SUI_IMAGE_ID=""
SUI_IMAGE_DIGEST=""

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"
TIME_LOCATION="${TIME_LOCATION:-Asia/Shanghai}"
WEB_PORT="${WEB_PORT:-2095}"
SUB_PORT="${SUB_PORT:-2096}"
WEB_PATH="${WEB_PATH:-/app/}"
SUB_PATH="${SUB_PATH:-/sub/}"

REGION_MODE="${REGION_MODE:-auto}"
DOCKER_REGISTRY_MIRROR="${DOCKER_REGISTRY_MIRROR:-}"
DOCKER_REPO_BASE_OVERRIDE="${DOCKER_REPO_BASE_OVERRIDE:-}"
ENABLE_IPV6_FORWARD="${ENABLE_IPV6_FORWARD:-0}"
OPEN_FIREWALL="${OPEN_FIREWALL:-1}"
UPGRADE="${UPGRADE:-0}"
FORCE_PORTS="${FORCE_PORTS:-0}"
SKIP_CERT_HOST_CHECK="${SKIP_CERT_HOST_CHECK:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
ASSUME_Y="${ASSUME_Y:-0}"

usage() {
  cat <<'EOF'
S-UI Docker 自动安装器

交互安装：
  sudo ./install.sh

非交互安装：
  sudo ./install.sh --domain panel.example.com --noninteractive -y

主要选项：
  --domain DOMAIN              面板/订阅域名
  --cert PATH                  正式证书或 fullchain PEM
  --key PATH                   对应私钥 PEM
  --cert-mode MODE             auto（默认）、self-signed、example
  --db PATH                    可选：导入已有 s-ui.db
  --old-domain DOMAIN          导入数据库时替换旧域名
  --dir PATH                   安装目录，默认 /opt/s-ui
  --sui-version VERSION        latest（默认）或固定版本，如 v1.5.4
  --region MODE                auto（默认）、china、global
  --docker-mirror URL          手动指定 Docker Hub 加速器
  --docker-repo URL            手动指定 Docker CE 软件源根地址
  --admin-user USER            面板管理员，默认 admin
  --admin-pass PASS            留空则生成高强度随机密码
  --time-location TZ           默认 Asia/Shanghai
  --web-port PORT              面板端口，默认 2095
  --sub-port PORT              订阅端口，默认 2096
  --ipv6-forward               启用 IPv6 转发
  --upgrade                    备份并升级已有安装
  --force-ports                明确允许已占用的端口
  --allow-docker-restart       有其他容器时也允许重启 Docker
  --no-firewall                不修改 UFW/firewalld
  --skip-cert-host-check       允许正式证书与域名不匹配
  --noninteractive             禁用交互
  -y, --yes                    自动确认安装摘要
  -h, --help                   显示帮助

安全说明：
  example 模式只用于开发测试，还必须设置 ALLOW_BUNDLED_EXAMPLE_CERT=1。
  安装器不会把真实证书、私钥、数据库或管理员密码写回 Git 仓库。
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --old-domain) OLD_DOMAIN="${2:-}"; shift 2 ;;
      --cert) CERT_SRC="${2:-}"; shift 2 ;;
      --key) KEY_SRC="${2:-}"; shift 2 ;;
      --cert-mode) CERT_MODE="${2:-}"; shift 2 ;;
      --db) DB_SRC="${2:-}"; shift 2 ;;
      --dir) SUI_DIR="${2:-}"; shift 2 ;;
      --sui-version) SUI_VERSION="${2:-}"; shift 2 ;;
      --region) REGION_MODE="${2:-}"; shift 2 ;;
      --docker-mirror) DOCKER_REGISTRY_MIRROR="${2:-}"; shift 2 ;;
      --docker-repo) DOCKER_REPO_BASE_OVERRIDE="${2:-}"; shift 2 ;;
      --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
      --admin-pass) ADMIN_PASS="${2:-}"; shift 2 ;;
      --time-location) TIME_LOCATION="${2:-}"; shift 2 ;;
      --web-port) WEB_PORT="${2:-}"; shift 2 ;;
      --sub-port) SUB_PORT="${2:-}"; shift 2 ;;
      --ipv6-forward) ENABLE_IPV6_FORWARD=1; shift ;;
      --upgrade) UPGRADE=1; shift ;;
      --force-ports) FORCE_PORTS=1; shift ;;
      --allow-docker-restart) ALLOW_DOCKER_RESTART=1; shift ;;
      --no-firewall) OPEN_FIREWALL=0; shift ;;
      --skip-cert-host-check) SKIP_CERT_HOST_CHECK=1; shift ;;
      --noninteractive) NONINTERACTIVE=1; shift ;;
      -y|--yes) ASSUME_Y=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

validate_options() {
  [[ "$REGION_MODE" =~ ^(auto|china|global)$ ]] ||
    die "--region 只支持 auto、china、global"
  [[ "$CERT_MODE" =~ ^(auto|self-signed|example)$ ]] ||
    die "--cert-mode 只支持 auto、self-signed、example"
  [[ -n "$DOMAIN" ]] || die "必须提供 --domain"
  validate_domain "$DOMAIN"
  validate_port "$WEB_PORT" "--web-port"
  validate_port "$SUB_PORT" "--sub-port"
  [[ "$WEB_PORT" != "$SUB_PORT" ]] || die "面板端口和订阅端口不能相同"
  [[ "$SUI_DIR" == /* && "$SUI_DIR" != "/" && "$SUI_DIR" != "/root" ]] ||
    die "--dir 必须是安全的绝对路径，且不能为 / 或 /root"
  [[ "$BACKUP_ROOT" == /* && "$BACKUP_ROOT" != "/" ]] ||
    die "BACKUP_ROOT 必须是安全的绝对路径"
  [[ -z "$DB_SRC" || -f "$DB_SRC" ]] || die "数据库不存在：${DB_SRC}"
  [[ -z "$DOCKER_REGISTRY_MIRROR" ]] ||
    validate_http_url "$DOCKER_REGISTRY_MIRROR" "--docker-mirror"
  [[ -z "$DOCKER_REPO_BASE_OVERRIDE" ]] ||
    validate_http_url "$DOCKER_REPO_BASE_OVERRIDE" "--docker-repo"
  case "$ADMIN_USER$ADMIN_PASS" in
    *$'\n'*|*$'\r'*) die "管理员账号或密码不能包含换行" ;;
  esac
}

prompt_inputs() {
  if ! is_interactive; then
    return 0
  fi
  printf '\nS-UI Docker 自动安装器\n'
  printf '按 Enter 接受方括号中的默认值。\n\n'
  DOMAIN="$(prompt_value "面板/订阅域名" "$DOMAIN" 1)"
  CERT_SRC="$(prompt_value "证书路径（留空自动查找）" "$CERT_SRC" 0)"
  if [[ -n "$CERT_SRC" ]]; then
    KEY_SRC="$(prompt_value "私钥路径" "$KEY_SRC" 1)"
  fi
  DB_SRC="$(prompt_value "已有 s-ui.db（留空新装）" "$DB_SRC" 0)"
  if [[ -n "$DB_SRC" ]]; then
    OLD_DOMAIN="$(prompt_value "旧域名（留空自动发现）" "$OLD_DOMAIN" 0)"
  fi
  ADMIN_USER="$(prompt_value "管理员用户名" "$ADMIN_USER" 1)"
  if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS="$(prompt_secret "管理员密码（留空自动生成）")"
  fi
  TIME_LOCATION="$(prompt_value "时区" "$TIME_LOCATION" 1)"
  WEB_PORT="$(prompt_value "面板 HTTPS 端口" "$WEB_PORT" 1)"
  SUB_PORT="$(prompt_value "订阅 HTTPS 端口" "$SUB_PORT" 1)"
}

print_summary_and_confirm() {
  printf '\n安装摘要\n'
  printf '  系统：          %s\n' "$(platform_summary)"
  printf '  网络：          %s\n' "$(network_summary)"
  printf '  Docker 软件源：%s\n' "$(redact_url "$DOCKER_REPO_BASE")"
  printf '  Docker 加速器：%s\n' "${SELECTED_DOCKER_MIRROR:-不配置}"
  printf '  S-UI 版本：     %s\n' "$SUI_VERSION"
  printf '  域名：          %s\n' "$DOMAIN"
  printf '  安装目录：      %s\n' "$SUI_DIR"
  printf '  证书：          %s\n' "$CERT_SRC"
  printf '  私钥：          %s\n' "$KEY_SRC"
  printf '  证书来源：      %s\n' "$CERT_DISCOVERY_REASON"
  printf '  数据库：        %s\n' "${DB_SRC:-新建}"
  printf '  面板：          https://%s:%s%s\n' "$DOMAIN" "$WEB_PORT" "$WEB_PATH"
  printf '  订阅：          https://%s:%s%s\n' "$DOMAIN" "$SUB_PORT" "$SUB_PATH"
  printf '  升级模式：      %s\n' "$([[ "$UPGRADE" == "1" ]] && printf 是 || printf 否)"
  if [[ "$ASSUME_Y" != "1" && -t 0 ]]; then
    prompt_yes_no "确认继续" "y" || die "已取消"
  fi
}

print_completion() {
  cat <<EOF

安装完成

面板：
  https://${DOMAIN}:${WEB_PORT}${WEB_PATH}

管理员：
  用户名：${ADMIN_USER}
  密码：  ${ADMIN_PASS}

管理命令：
  s-ui-manager status
  s-ui-manager doctor
  s-ui-manager logs
  s-ui-manager update
  s-ui-manager backup

云防火墙/安全组仍需放行：
  ${WEB_PORT}/tcp, ${SUB_PORT}/tcp, 80/tcp, 443/tcp, 443/udp, 8443/tcp
EOF
  if [[ "$SELF_SIGNED_CERT" == "1" ]]; then
    warn "当前使用自签名证书。正式使用前请换成可信证书，然后运行 s-ui-manager cert-sync。"
  fi
}

main() {
  parse_args "$@"
  require_root "$@"
  detect_platform
  install_base_packages
  prompt_inputs
  validate_options
  detect_network_profile
  select_download_sources
  resolve_sui_version
  resolve_certificates
  check_existing_install
  print_summary_and_confirm

  ensure_docker
  configure_docker_registry_mirror
  pull_sui_image
  check_port_conflicts
  backup_existing_install
  configure_sysctl
  prepare_sui_files
  write_compose
  open_firewall_ports
  start_sui
  update_sui_database

  if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS="$(openssl rand -base64 24 | tr -d '\n')"
  fi
  set_admin_credentials
  restart_and_verify_sui
  write_installer_state
  install_manager
  write_install_report
  print_completion
}

main "$@"
