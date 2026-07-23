# Contributing

1. 不要提交生产证书、私钥、数据库、凭据或服务器地址。
2. Shell 脚本保持 Bash 兼容，并通过 `set -Eeuo pipefail`。
3. 修改安装流程后同时更新 README、架构文档和烟雾测试。
4. 本地运行：

```bash
shellcheck install.sh lib/*.sh scripts/* tests/*.sh
bash tests/smoke.sh
```

5. 涉及真实 VPS 的变更应说明系统版本、云厂商、网络区域、是否存在其他容器，
   并记录容器、端口、HTTPS 和证书验证结果。
