#!/usr/bin/env bash

check_existing_install() {
  EXISTING_INSTALL=0
  if [[ -e "${SUI_DIR}/docker-compose.yml" || -e "${SUI_DIR}/db/s-ui.db" ]]; then
    EXISTING_INSTALL=1
    [[ "$UPGRADE" == "1" ]] ||
      die "发现现有安装 ${SUI_DIR}；如需保留数据升级，请使用 --upgrade"
  fi
}

backup_existing_install() {
  [[ "$EXISTING_INSTALL" == "1" ]] || return 0
  local backup_dir=""
  backup_dir="${BACKUP_ROOT}/$(timestamp)"
  log "备份现有 S-UI"
  install -m 0700 -d "$backup_dir"

  if [[ -f "${SUI_DIR}/db/s-ui.db" ]]; then
    sqlite3 "${SUI_DIR}/db/s-ui.db" \
      ".backup '${backup_dir}/s-ui.db'" ||
      die "SQLite 在线备份失败"
    chmod 0600 "${backup_dir}/s-ui.db"
  fi
  [[ -f "${SUI_DIR}/docker-compose.yml" ]] &&
    cp -a "${SUI_DIR}/docker-compose.yml" "$backup_dir/"
  [[ -f "${SUI_DIR}/.env" ]] &&
    cp -a "${SUI_DIR}/.env" "$backup_dir/"
  [[ -d "${SUI_DIR}/cert" ]] &&
    cp -a "${SUI_DIR}/cert" "$backup_dir/"
  printf '%s\n' "$backup_dir" >"${BACKUP_ROOT}/latest"
  info "备份目录：${backup_dir}"
}

check_port_conflicts() {
  [[ "$EXISTING_INSTALL" == "1" ]] && return 0
  log "检查端口占用"
  local pattern=""
  local conflicts=""
  pattern=":(${WEB_PORT}|${SUB_PORT}|80|443|8443)\\b"
  conflicts="$(ss -H -ltnup 2>/dev/null | grep -E "$pattern" || true)"
  if [[ -n "$conflicts" ]]; then
    warn "以下端口已被占用："
    printf '%s\n' "$conflicts" >&2
    [[ "$FORCE_PORTS" == "1" ]] ||
      die "请先处理端口冲突，或确认无害后使用 --force-ports"
  fi
}

configure_sysctl() {
  log "配置 BBR 与转发"
  modprobe tcp_bbr 2>/dev/null || true
  cat >/etc/sysctl.d/99-s-ui-installer.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
EOF
  if [[ "$ENABLE_IPV6_FORWARD" == "1" ]]; then
    printf '%s\n' 'net.ipv6.conf.all.forwarding=1' \
      >>/etc/sysctl.d/99-s-ui-installer.conf
  fi
  sysctl --system >/dev/null ||
    warn "部分 sysctl 参数未能应用，请稍后运行 s-ui-manager doctor"
}

prepare_sui_files() {
  log "准备部署目录"
  install -m 0750 -d "$SUI_DIR" "${SUI_DIR}/db" "${SUI_DIR}/cert"
  install -m 0700 -d /etc/s-ui-installer "$BACKUP_ROOT"

  CERT_BASENAME="$(basename "$CERT_SRC")"
  KEY_BASENAME="$(basename "$KEY_SRC")"
  CERT_DEST="${SUI_DIR}/cert/${CERT_BASENAME}"
  KEY_DEST="${SUI_DIR}/cert/${KEY_BASENAME}"
  CERT_IN_CONTAINER="/app/cert/${CERT_BASENAME}"
  KEY_IN_CONTAINER="/app/cert/${KEY_BASENAME}"

  install -m 0644 "$CERT_SRC" "$CERT_DEST"
  install -m 0600 "$KEY_SRC" "$KEY_DEST"

  if [[ -n "$DB_SRC" ]]; then
    install -m 0600 "$DB_SRC" "${SUI_DIR}/db/s-ui.db"
    rm -f "${SUI_DIR}/db/s-ui.db-wal" "${SUI_DIR}/db/s-ui.db-shm"
  fi
}

write_compose() {
  log "写入 Docker Compose 配置"
  cat >"${SUI_DIR}/.env" <<EOF
SUI_IMAGE=${SUI_IMAGE}
TZ=${TIME_LOCATION}
WEB_PORT=${WEB_PORT}
SUB_PORT=${SUB_PORT}
EOF
  chmod 0600 "${SUI_DIR}/.env"

  cat >"${SUI_DIR}/docker-compose.yml" <<'EOF'
services:
  s-ui:
    image: ${SUI_IMAGE}
    container_name: s-ui
    hostname: s-ui
    restart: unless-stopped
    init: true
    environment:
      TZ: ${TZ}
    volumes:
      - ./db:/app/db
      - ./cert:/app/cert:ro
    ports:
      - "${WEB_PORT}:${WEB_PORT}/tcp"
      - "${SUB_PORT}:${SUB_PORT}/tcp"
      - "80:80/tcp"
      - "443:443/tcp"
      - "443:443/udp"
      - "8443:8443/tcp"
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    stop_grace_period: 20s
EOF
}

open_firewall_ports() {
  [[ "$OPEN_FIREWALL" == "1" ]] || return 0
  if command_exists ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log "放行 UFW 端口"
    ufw allow "${WEB_PORT}/tcp"
    ufw allow "${SUB_PORT}/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    ufw allow 8443/tcp
  elif command_exists firewall-cmd &&
       firewall-cmd --state >/dev/null 2>&1; then
    log "放行 firewalld 端口"
    firewall-cmd --permanent --add-port="${WEB_PORT}/tcp"
    firewall-cmd --permanent --add-port="${SUB_PORT}/tcp"
    firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --permanent --add-port=443/udp
    firewall-cmd --permanent --add-port=8443/tcp
    firewall-cmd --reload
  fi
}

start_sui() {
  log "启动 S-UI"
  (
    cd "$SUI_DIR" || exit
    docker compose up -d --remove-orphans
  )
  local _attempt=0
  for _attempt in $(seq 1 60); do
    if [[ -f "${SUI_DIR}/db/s-ui.db" ]] &&
       docker inspect s-ui --format '{{.State.Running}}' 2>/dev/null |
         grep -q true; then
      return 0
    fi
    sleep 1
  done
  docker logs --tail=100 s-ui 2>/dev/null || true
  die "S-UI 未能在 60 秒内完成启动"
}

update_sui_database() {
  log "配置 S-UI 数据库"
  (
    cd "$SUI_DIR" || exit
    docker compose stop s-ui
  )
  export SUI_DIR DOMAIN OLD_DOMAIN CERT_IN_CONTAINER KEY_IN_CONTAINER
  export TIME_LOCATION WEB_PORT SUB_PORT WEB_PATH SUB_PATH
  if ! python3 <<'PY'
import json
import os
import sqlite3

db_path = os.path.join(os.environ["SUI_DIR"], "db", "s-ui.db")
domain = os.environ["DOMAIN"]
explicit_old = os.environ.get("OLD_DOMAIN", "").strip()
cert = os.environ["CERT_IN_CONTAINER"]
key = os.environ["KEY_IN_CONTAINER"]

settings = {
    "webDomain": domain,
    "subDomain": domain,
    "webCertFile": cert,
    "webKeyFile": key,
    "subCertFile": cert,
    "subKeyFile": key,
    "webPort": os.environ["WEB_PORT"],
    "subPort": os.environ["SUB_PORT"],
    "webPath": os.environ["WEB_PATH"],
    "subPath": os.environ["SUB_PATH"],
    "timeLocation": os.environ["TIME_LOCATION"],
}

con = sqlite3.connect(db_path)
cur = con.cursor()
if not cur.execute(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings'"
).fetchone():
    raise SystemExit("S-UI database has no settings table")

old_domains = set()
if explicit_old:
    old_domains.add(explicit_old)
for key_name in ("webDomain", "subDomain"):
    row = cur.execute(
        "SELECT value FROM settings WHERE key=? LIMIT 1", (key_name,)
    ).fetchone()
    if row and row[0] and row[0] != domain:
        old_domains.add(str(row[0]))

for name, value in settings.items():
    cur.execute("UPDATE settings SET value=? WHERE key=?", (value, name))
    if cur.rowcount == 0:
        cur.execute("INSERT INTO settings(key,value) VALUES(?,?)", (name, value))

def replace_domains(value):
    original = value
    if isinstance(value, str):
        for old in old_domains:
            value = value.replace(old, domain)
    elif isinstance(value, bytes):
        for old in old_domains:
            value = value.replace(old.encode(), domain.encode())
    return value, value != original

tables = cur.execute(
    "SELECT name FROM sqlite_master "
    "WHERE type='table' AND name NOT LIKE 'sqlite_%'"
).fetchall()
for (table,) in tables:
    columns = [row[1] for row in cur.execute(f'PRAGMA table_info("{table}")')]
    if not columns:
        continue
    for row in cur.execute(f'SELECT rowid,* FROM "{table}"').fetchall():
        rowid = row[0]
        updates = {}
        for column, value in zip(columns, row[1:]):
            new_value, changed = replace_domains(value)
            if changed:
                updates[column] = new_value
        if updates:
            assignments = ", ".join(f'"{column}"=?' for column in updates)
            cur.execute(
                f'UPDATE "{table}" SET {assignments} WHERE rowid=?',
                [*updates.values(), rowid],
            )

if cur.execute(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='tls'"
).fetchone():
    for rowid, server in cur.execute("SELECT rowid, server FROM tls").fetchall():
        if not server:
            continue
        text = server.decode("utf-8", "replace") if isinstance(server, bytes) else str(server)
        try:
            data = json.loads(text)
        except Exception:
            continue
        if (
            "certificate_path" in data
            or "key_path" in data
            or data.get("server_name") in old_domains
            or data.get("server_name") == domain
        ):
            data["enabled"] = True
            data["server_name"] = domain
            data["certificate_path"] = cert
            data["key_path"] = key
            cur.execute(
                "UPDATE tls SET server=? WHERE rowid=?",
                (json.dumps(data, ensure_ascii=False, indent=2), rowid),
            )

con.commit()
con.close()
PY
  then
    (
      cd "$SUI_DIR" || exit
      docker compose up -d
    ) || true
    die "S-UI 数据库更新失败；容器已尝试恢复启动"
  fi
  (
    cd "$SUI_DIR" || exit
    docker compose up -d
  )
  local _attempt=0
  for _attempt in $(seq 1 30); do
    docker inspect s-ui --format '{{.State.Running}}' 2>/dev/null |
      grep -q true && return 0
    sleep 1
  done
  die "数据库更新后 S-UI 未能重新启动"
}

set_admin_credentials() {
  log "设置面板管理员"
  retry 5 2 docker exec s-ui /app/sui admin \
    -username "$ADMIN_USER" \
    -password "$ADMIN_PASS" >/dev/null ||
    die "无法设置 S-UI 管理员账号"
}

restart_and_verify_sui() {
  log "重启并验证 S-UI"
  (
    cd "$SUI_DIR" || exit
    docker compose restart s-ui
  )
  sleep 5

  docker inspect s-ui --format '{{.State.Running}}' | grep -q true ||
    die "S-UI 容器未运行"

  local http_code=""
  http_code="$(curl -ksS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 12 \
    --resolve "${DOMAIN}:${WEB_PORT}:127.0.0.1" \
    "https://${DOMAIN}:${WEB_PORT}${WEB_PATH}" 2>/dev/null || true)"
  case "$http_code" in
    200|301|302|303|307|308) info "面板本机 HTTPS 检查通过（HTTP ${http_code}）" ;;
    *)
      docker logs --tail=80 s-ui 2>/dev/null || true
      die "面板本机 HTTPS 检查失败（HTTP ${http_code:-000}）"
      ;;
  esac

  docker port s-ui | grep -q "${WEB_PORT}/tcp" ||
    die "面板端口未发布"
  docker port s-ui | grep -q '443/udp' ||
    die "Hysteria2 UDP 443 未发布"
  docker port s-ui | grep -q '8443/tcp' ||
    die "AnyTLS TCP 8443 未发布"
}

write_installer_state() {
  cat >/etc/s-ui-installer/config.env <<EOF
SUI_DIR=$(printf '%q' "$SUI_DIR")
DOMAIN=$(printf '%q' "$DOMAIN")
WEB_PORT=$(printf '%q' "$WEB_PORT")
SUB_PORT=$(printf '%q' "$SUB_PORT")
WEB_PATH=$(printf '%q' "$WEB_PATH")
SUB_PATH=$(printf '%q' "$SUB_PATH")
CERT_SOURCE=$(printf '%q' "$CERT_SRC")
KEY_SOURCE=$(printf '%q' "$KEY_SRC")
CERT_DEST=$(printf '%q' "$CERT_DEST")
KEY_DEST=$(printf '%q' "$KEY_DEST")
CERT_IN_CONTAINER=$(printf '%q' "$CERT_IN_CONTAINER")
KEY_IN_CONTAINER=$(printf '%q' "$KEY_IN_CONTAINER")
SUI_VERSION=$(printf '%q' "$SUI_VERSION")
DETECTED_REGION=$(printf '%q' "$DETECTED_REGION")
BACKUP_ROOT=$(printf '%q' "$BACKUP_ROOT")
EOF
  chmod 0600 /etc/s-ui-installer/config.env
}

install_manager() {
  install -m 0755 "${SCRIPT_DIR}/scripts/s-ui-manager" \
    /usr/local/sbin/s-ui-manager

  cat >/etc/systemd/system/s-ui-cert-sync.service <<'EOF'
[Unit]
Description=Synchronize S-UI TLS certificate
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/s-ui-manager cert-sync
EOF

  cat >/etc/systemd/system/s-ui-cert-sync.timer <<'EOF'
[Unit]
Description=Daily S-UI TLS certificate synchronization

[Timer]
OnBootSec=10min
OnUnitActiveSec=12h
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now s-ui-cert-sync.timer
}

write_install_report() {
  local report="${SUI_DIR}/install-report.txt"
  {
    printf 'S-UI installation report\n'
    printf 'Generated: %s\n\n' "$(date -Is)"
    printf 'System: %s\n' "$(platform_summary)"
    printf 'Network: %s\n' "$(network_summary)"
    printf 'S-UI version: %s\n' "$SUI_VERSION"
    printf 'Image: %s\n' "$SUI_IMAGE"
    printf 'Image ID: %s\n' "$SUI_IMAGE_ID"
    printf 'Image digest: %s\n\n' "${SUI_IMAGE_DIGEST:-unavailable}"
    printf 'Panel URL: https://%s:%s%s\n' "$DOMAIN" "$WEB_PORT" "$WEB_PATH"
    printf 'Subscription URL: https://%s:%s%s\n' "$DOMAIN" "$SUB_PORT" "$SUB_PATH"
    printf 'Admin username: %s\n' "$ADMIN_USER"
    printf 'Admin password: %s\n\n' "$ADMIN_PASS"
    printf 'Certificate source: %s\n' "$CERT_SRC"
    printf 'Certificate mode: %s\n\n' "$CERT_DISCOVERY_REASON"
    printf 'Published ports: %s/tcp %s/tcp 80/tcp 443/tcp 443/udp 8443/tcp\n\n' \
      "$WEB_PORT" "$SUB_PORT"
    printf 'Useful commands:\n'
    printf '  s-ui-manager status\n'
    printf '  s-ui-manager doctor\n'
    printf '  s-ui-manager logs\n'
    printf '  s-ui-manager update\n'
    printf '  s-ui-manager backup\n'
  } >"$report"
  chmod 0600 "$report"
  info "安装报告：${report}（权限 0600）"
}
