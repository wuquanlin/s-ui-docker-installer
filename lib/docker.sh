#!/usr/bin/env bash

docker_repo_os() {
  if [[ "$PACKAGE_FAMILY" == "apt" ]]; then
    case "$OS_ID" in
      ubuntu|linuxmint) printf 'ubuntu' ;;
      *) printf 'debian' ;;
    esac
  else
    case "$OS_ID" in
      fedora) printf 'fedora' ;;
      *) printf 'centos' ;;
    esac
  fi
}

docker_ready() {
  command_exists docker &&
    docker compose version >/dev/null 2>&1 &&
    systemctl is-active --quiet docker
}

install_docker_apt() {
  local repo_os=""
  repo_os="$(docker_repo_os)"
  export DEBIAN_FRONTEND=noninteractive

  apt-get remove -y \
    docker.io docker-doc docker-compose docker-compose-v2 \
    podman-docker containerd runc 2>/dev/null || true

  install -m 0755 -d /etc/apt/keyrings
  if [[ -s /etc/apt/keyrings/docker.asc ]] &&
     gpg --batch --quiet --show-keys /etc/apt/keyrings/docker.asc >/dev/null 2>&1; then
    info "复用现有 Docker 仓库签名密钥"
  else
    retry 3 3 curl --retry 2 --retry-all-errors --connect-timeout 10 -fsSL \
      "${DOCKER_REPO_BASE}/linux/${repo_os}/gpg" \
      -o /etc/apt/keyrings/docker.asc ||
      die "无法下载 Docker 仓库签名密钥"
  fi
  chmod a+r /etc/apt/keyrings/docker.asc

  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: ${DOCKER_REPO_BASE}/linux/${repo_os}
Suites: ${OS_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  retry 3 3 apt-get update
  apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

install_docker_rpm() {
  local pm="dnf"
  local repo_os=""
  local repo_url=""
  local repo_file="/etc/yum.repos.d/docker-ce.repo"
  command_exists dnf || pm="yum"
  repo_os="$(docker_repo_os)"
  repo_url="${DOCKER_REPO_BASE}/linux/${repo_os}/docker-ce.repo"

  "$pm" -y remove \
    docker docker-client docker-client-latest docker-common docker-latest \
    docker-latest-logrotate docker-logrotate docker-engine podman-docker \
    runc 2>/dev/null || true

  "$pm" -y install dnf-plugins-core || "$pm" -y install yum-utils
  retry 3 3 curl --retry 2 --retry-all-errors --connect-timeout 10 -fsSL \
    "$repo_url" -o "$repo_file" ||
    die "无法下载 Docker RPM 仓库配置"
  if [[ "$DOCKER_REPO_BASE" != "https://download.docker.com" ]]; then
    sed -i \
      "s#https://download\\.docker\\.com#${DOCKER_REPO_BASE}#g" \
      "$repo_file"
  fi
  "$pm" -y install \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

ensure_docker() {
  if docker_ready; then
    log "复用已安装的 Docker Engine 与 Compose"
    return 0
  fi

  log "安装 Docker Engine"
  info "软件源：$(redact_url "$DOCKER_REPO_BASE")"

  if [[ "$PACKAGE_FAMILY" == "apt" ]]; then
    install_docker_apt
  else
    install_docker_rpm
  fi

  systemctl enable --now docker
  docker info >/dev/null 2>&1 || die "Docker 服务安装后仍不可用"
  docker compose version >/dev/null 2>&1 || die "Docker Compose 插件不可用"
}

registry_endpoint_works() {
  local endpoint="$1"
  local code=""
  code="$(curl -4 -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 4 --max-time 8 "${endpoint%/}/v2/" 2>/dev/null || true)"
  [[ "$code" == "200" || "$code" == "401" ]]
}

configure_docker_registry_mirror() {
  [[ -n "$SELECTED_DOCKER_MIRROR" ]] || return 0

  if ! registry_endpoint_works "$SELECTED_DOCKER_MIRROR"; then
    warn "首选 Docker 镜像加速器不可达：${SELECTED_DOCKER_MIRROR}"
    if [[ "$SELECTED_DOCKER_MIRROR" != "https://docker.m.daocloud.io" ]] &&
       registry_endpoint_works "https://docker.m.daocloud.io"; then
      SELECTED_DOCKER_MIRROR="https://docker.m.daocloud.io"
      info "改用可达的 DaoCloud 镜像：${SELECTED_DOCKER_MIRROR}"
    else
      warn "不修改 Docker daemon；拉取阶段仍会尝试直接镜像前缀回退"
      return 0
    fi
  fi

  local daemon_json="/etc/docker/daemon.json"
  local current_json=""
  local updated_json=""
  local backup=""
  local running_count="0"

  install -m 0755 -d /etc/docker
  current_json="$(mktemp)"
  updated_json="$(mktemp)"
  if [[ -s "$daemon_json" ]]; then
    cp -a "$daemon_json" "$current_json"
  else
    printf '{}\n' >"$current_json"
  fi

  if ! jq -e --arg mirror "$SELECTED_DOCKER_MIRROR" '
      if type != "object" then
        error("daemon.json must be a JSON object")
      elif ((.["registry-mirrors"] // []) | type) != "array" then
        error("registry-mirrors must be an array")
      else
        .["registry-mirrors"] =
          (((.["registry-mirrors"] // []) + [$mirror]) | unique)
      end
    ' "$current_json" >"$updated_json"; then
    rm -f "$current_json" "$updated_json"
    die "${daemon_json} 不是兼容的 JSON，已停止以避免覆盖"
  fi

  if [[ -s "$daemon_json" ]] && cmp -s "$daemon_json" "$updated_json"; then
    rm -f "$current_json" "$updated_json"
    info "Docker 镜像加速器已配置"
    return 0
  fi

  running_count="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
  if (( running_count > 0 )) && [[ "${ALLOW_DOCKER_RESTART:-0}" != "1" ]]; then
    warn "检测到 ${running_count} 个正在运行的容器；为避免中断，暂不重启 Docker"
    warn "如确认允许短暂重启，请设置 ALLOW_DOCKER_RESTART=1 后重跑"
    rm -f "$current_json" "$updated_json"
    return 0
  fi

  if [[ -e "$daemon_json" ]]; then
    backup="${daemon_json}.s-ui-backup.$(timestamp)"
    cp -a "$daemon_json" "$backup"
    info "原 Docker 配置已备份到 ${backup}"
  fi
  install -m 0644 "$updated_json" "$daemon_json"
  rm -f "$current_json" "$updated_json"

  systemctl restart docker
  docker info >/dev/null 2>&1 || die "应用镜像加速配置后 Docker 不可用"
  info "Docker Hub 加速器：${SELECTED_DOCKER_MIRROR}"
}

resolve_sui_version() {
  if [[ "$SUI_VERSION" != "latest" ]]; then
    [[ "$SUI_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
      die "S-UI 版本格式无效：${SUI_VERSION}"
    [[ "$SUI_VERSION" == v* ]] || SUI_VERSION="v${SUI_VERSION}"
    return 0
  fi

  log "查询 S-UI 官方最新版本"
  local release_json=""
  release_json="$(curl -4 -fsSL --connect-timeout 5 --max-time 15 \
    "${GITHUB_API_BASE}/repos/alireza0/s-ui/releases/latest" 2>/dev/null || true)"
  SUI_VERSION="$(printf '%s' "$release_json" | jq -r '.tag_name // empty' 2>/dev/null || true)"

  if [[ ! "$SUI_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SUI_VERSION="$SUI_FALLBACK_VERSION"
    warn "无法实时查询官方 Release，回退到项目验证快照 ${SUI_VERSION}"
  else
    info "官方最新版本：${SUI_VERSION}"
  fi
}

pull_sui_image() {
  local origin_image="alireza7/s-ui:${SUI_VERSION}"
  local mirror_image="docker.m.daocloud.io/alireza7/s-ui:${SUI_VERSION}"

  log "拉取 S-UI ${SUI_VERSION}"
  if retry 2 3 docker pull "$origin_image"; then
    SUI_IMAGE="$origin_image"
  elif [[ "$DETECTED_REGION" == "china" ]]; then
    warn "Docker Hub 拉取失败，改用 DaoCloud 的源镜像前缀"
    retry 3 5 docker pull "$mirror_image" ||
      die "官方路径和国内镜像均无法拉取 S-UI ${SUI_VERSION}"
    SUI_IMAGE="$mirror_image"
  else
    die "无法拉取 ${origin_image}"
  fi

  SUI_IMAGE_ID="$(docker image inspect "$SUI_IMAGE" --format '{{.Id}}')"
  # Used by sui.sh when writing the installation report.
  # shellcheck disable=SC2034
  SUI_IMAGE_DIGEST="$(docker image inspect "$SUI_IMAGE" \
    --format '{{join .RepoDigests ","}}' 2>/dev/null || true)"
  info "镜像 ID：${SUI_IMAGE_ID}"
}
