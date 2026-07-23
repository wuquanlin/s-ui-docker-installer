# 安全说明

## 不应进入 Git 的内容

- 真实 TLS 私钥或证书包；
- `s-ui.db`、WAL、SHM；
- 管理员密码；
- Reality 私钥、UUID、订阅链接；
- 云厂商专属镜像地址中的凭据；
- 服务器清单、SSH 私钥和备份。

`.gitignore` 提供基础防护，CI 会额外拒绝数据库、已知生产域名、OpenSSH 私钥
和常见 GitHub Token。CI 不能替代提交前人工检查。

## 示例证书

`certs/examples/development-private.key` 是公开测试材料，对应保留域名
`s-ui-installer.invalid`。任何人都能读取它，因此不能提供身份认证或加密安全。
安装器需要两项显式确认才允许使用它。

## 镜像供应链

海外环境优先从 Docker Hub 拉取官方 `alireza7/s-ui:<version>`。中国网络优先
使用云厂商 Registry Mirror；通用回退使用 DaoCloud。安装报告记录镜像 ID 和
RepoDigest，便于审计和故障复现。

版本默认来自 S-UI 官方 GitHub Release API。网络不可达时只回退到仓库中维护的
明确版本快照，不使用无法审计的“任意 latest”。

## 权限和服务中断

安装器需要 root，因为 Docker、systemd、sysctl 和防火墙均属于系统级操作。
当 Docker 配置需要变化且已有其他容器运行时，默认不重启 Docker。只有显式
设置 `ALLOW_DOCKER_RESTART=1` 或使用 `--allow-docker-restart` 才允许重启。

## 漏洞报告

请不要在公开 Issue 中粘贴真实数据库、私钥、订阅或服务器地址。使用 GitHub
私有安全报告功能，或先构造已脱敏的最小复现。
