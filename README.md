# S-UI Docker 自动安装器

面向中国大陆与海外 VPS 的 S-UI Docker 安装、升级、证书同步、备份和诊断项目。

项目默认安装官方最新 S-UI Release 对应的 Docker 标签，并在 GitHub API
不可达时回退到经过验证的版本快照。当前快照为 `v1.5.4`，实时安装时仍会
优先查询 [S-UI 官方 Release](https://github.com/alireza0/s-ui/releases/latest)。

## 主要能力

- 自动识别 Debian、Ubuntu、Linux Mint、Raspbian、Kali。
- 自动识别 RHEL、CentOS Stream、Rocky、AlmaLinux、Fedora、Oracle Linux。
- 兼容 OpenCloudOS、Anolis OS、Alibaba Cloud Linux、openEuler 等 RHEL 系。
- 结合云厂商特征和网络探测判断中国或海外网络，也可手动覆盖。
- 中国网络自动选择腾讯云、阿里云、华为云 Docker CE 软件源。
- Docker Hub 不可达时，优先使用云厂商加速器，再回退到 DaoCloud 镜像。
- 动态查询官方最新 S-UI 版本；也支持固定版本部署。
- 自动发现 Certbot、acme.sh、`/root` 和安装包私有目录中的证书。
- 校验证书格式、域名、有效期以及证书/私钥是否匹配。
- 没有正式证书时可生成自签名证书，保证安装能够完成。
- 支持导入旧 `s-ui.db`，替换旧域名并保留入站、客户端和 Reality 配置。
- 自动发布面板、订阅、VLESS、Hysteria2 和 AnyTLS 所需端口。
- 配置 BBR、IPv4 转发和可选 IPv6 转发。
- 自动适配 UFW 和 firewalld，但不代替云平台安全组。
- 升级前执行 SQLite 在线备份，保留 Compose、环境变量和证书。
- 安装证书同步定时器和 `s-ui-manager` 管理工具。
- 对容器、TCP/UDP 端口、HTTPS、证书、系统参数进行安装后验证。
- GitHub Actions 执行 ShellCheck、烟雾测试和敏感文件拦截。

## 安全原则

仓库不包含任何真实域名、生产证书、生产私钥、数据库、管理员密码或节点密钥。

`certs/examples/` 中的证书和私钥只对应保留域名
`s-ui-installer.invalid`。其私钥是公开的，不能提供任何安全性，安装器默认拒绝
使用它。真实证书应放在 VPS 上并通过参数指定：

```bash
sudo ./install.sh \
  --domain panel.example.com \
  --cert /etc/letsencrypt/live/panel.example.com/fullchain.pem \
  --key /etc/letsencrypt/live/panel.example.com/privkey.pem
```

## 快速开始

```bash
git clone https://github.com/wuquanlin/s-ui-docker-installer.git
cd s-ui-docker-installer
chmod +x install.sh
sudo ./install.sh
```

安装器会交互询问域名、证书、数据库、管理员、端口、时区和 IPv6 转发。

### 非交互安装

```bash
sudo ./install.sh \
  --domain panel.example.com \
  --cert /etc/letsencrypt/live/panel.example.com/fullchain.pem \
  --key /etc/letsencrypt/live/panel.example.com/privkey.pem \
  --admin-user admin \
  --noninteractive \
  -y
```

未提供 `--admin-pass` 时会生成随机密码，并在终端显示一次。完整安装报告保存在
`/opt/s-ui/install-report.txt`，权限为 `0600`。

### 中国 VPS

通常不需要额外参数：

```bash
sudo ./install.sh --domain panel.example.com
```

自动判断会参考：

1. 腾讯云、阿里云、华为云的硬件和系统源特征；
2. Docker Hub、Docker CE、GitHub API 的可达性；
3. 腾讯云和阿里云镜像站的可达性。

不使用公网 IP 地理定位接口，因此不会把服务器 IP 发给额外的定位服务。

如自动判断不适合当前网络，可明确覆盖：

```bash
sudo ./install.sh --region china --domain panel.example.com
sudo ./install.sh --region global --domain panel.example.com
```

阿里云和华为云账号通常会提供专属 Docker Hub 加速地址，优先手动传入：

```bash
sudo ./install.sh \
  --region china \
  --docker-mirror https://YOUR-ID.mirror.aliyuncs.com \
  --domain panel.example.com
```

通用中国网络的公共回退来自
[DaoCloud public-image-mirror](https://github.com/DaoCloud/public-image-mirror)。
该项目声明源镜像 SHA-256 与上游保持一致，但公共服务存在白名单、限流和缓存
延迟；生产环境仍推荐云厂商专属镜像或自建 Registry 缓存。

## 升级已有安装

```bash
sudo ./install.sh \
  --upgrade \
  --domain panel.example.com \
  --cert /path/to/fullchain.pem \
  --key /path/to/private.key
```

升级会先备份到 `/var/backups/s-ui-installer/<UTC时间>/`。不会删除旧备份。

安装完成后更新到官方最新版本：

```bash
sudo s-ui-manager update
sudo s-ui-manager doctor
```

## 克隆旧服务器配置

先把旧数据库安全复制到新 VPS：

```bash
scp root@OLD_SERVER:/opt/s-ui/db/s-ui.db /root/s-ui.db
```

再安装：

```bash
sudo ./install.sh \
  --domain new.example.com \
  --db /root/s-ui.db \
  --old-domain old.example.com
```

数据库只在新服务器本地修改，旧服务器不会被触碰。

## 证书默认路径

自动发现顺序包括：

```text
/etc/letsencrypt/live/DOMAIN/fullchain.pem
/etc/letsencrypt/live/DOMAIN/privkey.pem
/root/.acme.sh/DOMAIN_ecc/fullchain.cer
/root/.acme.sh/DOMAIN_ecc/DOMAIN.key
/root/.acme.sh/DOMAIN/fullchain.cer
/root/.acme.sh/DOMAIN/DOMAIN.key
/root/DOMAIN.pem
/root/DOMAIN.key
/root/fullchain.pem
/root/privkey.pem
certs/live/fullchain.pem
certs/live/private.key
```

随后会扫描 `/root`，但只有同时通过证书格式、私钥匹配和域名匹配的组合才会采用。

如果自动生成了自签名证书，后续把正式证书放到原来源路径，再运行：

```bash
sudo s-ui-manager cert-sync
```

## 管理命令

```bash
s-ui-manager status
s-ui-manager doctor
s-ui-manager logs
s-ui-manager update
s-ui-manager backup
s-ui-manager restore /var/backups/s-ui-installer/TIMESTAMP
s-ui-manager cert-sync
s-ui-manager restart
s-ui-manager stop
s-ui-manager start
s-ui-manager uninstall
```

`uninstall` 只停止容器并禁用证书定时器，默认保留所有数据和备份。

## 默认端口

| 端口 | 用途 |
| --- | --- |
| `2095/tcp` | S-UI 面板 HTTPS |
| `2096/tcp` | 订阅 HTTPS |
| `80/tcp` | 可选 HTTP 入站 |
| `443/tcp` | VLESS / TLS |
| `443/udp` | Hysteria2 / QUIC |
| `8443/tcp` | AnyTLS |

本机防火墙会在启用时自动处理。腾讯云、阿里云、AWS 等云平台的安全组仍需手动
放行对应端口。

## 项目验证

```bash
bash tests/smoke.sh
bash tests/network-selection.sh
shellcheck install.sh lib/*.sh scripts/* tests/*.sh
```

真实部署验证应至少包含：

```bash
s-ui-manager doctor
docker port s-ui
curl -kI https://YOUR_DOMAIN:2095/app/
```

VLESS TCP 443、Hysteria2 UDP 443 和 AnyTLS TCP 8443 必须分别测试，单纯 Ping
或面板可访问不能证明所有代理协议正常。

## 支持范围

安装器面向使用 systemd 的服务器发行版。极简容器、OpenRC、无 systemd 环境和
经过大幅裁剪的 NAS 系统不在自动安装范围内。

详细设计和安全模型见：

- [架构与检测逻辑](docs/ARCHITECTURE.md)
- [安全说明](docs/SECURITY.md)
- [贡献指南](CONTRIBUTING.md)

## 许可

MIT。S-UI 本身由其上游项目按自己的许可证发布。
