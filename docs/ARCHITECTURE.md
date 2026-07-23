# 架构与检测逻辑

## 安装阶段

1. 从 `/etc/os-release` 判断包管理器族和 Docker 仓库兼容路径。
2. 安装最少依赖，不替换系统已有 Debian/RHEL 软件源。
3. 识别云厂商，再对境内外关键资源执行短超时探测。
4. 根据网络画像选择 Docker CE 仓库和 Docker Hub 加速器。
5. 从 S-UI 官方 GitHub Release API 获取最新版本。
6. 查找并验证证书，必要时生成自签名证书。
7. 检查现有安装和端口；升级时先在线备份 SQLite。
8. 安装或复用 Docker，安全合并 `/etc/docker/daemon.json`。
9. 拉取指定版本的官方镜像，境内失败时使用 DaoCloud 前缀回退。
10. 写入 Compose、复制证书、启动容器并配置 SQLite。
11. 验证容器、HTTPS、端口和证书，最后安装管理工具和证书同步定时器。

## 中国/海外判断

`--region` 的显式值优先级最高。

自动模式先检查 DMI 厂商信息和系统软件源：

- Tencent、QCloud、tencentyun；
- Alibaba、Aliyun；
- Huawei、Huawei Cloud。

识别到云厂商不会单独决定区域，因为这些厂商也有海外节点。系统软件源明确使用
中国云镜像时直接采用中国网络画像；否则对三类境外资源和两类国内镜像执行短
超时探测：

- `registry-1.docker.io`
- `download.docker.com`
- `api.github.com`
- `mirrors.aliyun.com`
- `mirrors.tencent.com`

境外关键资源最多只有一个可达且至少一个国内镜像可达时，判定为中国网络；
其他情况按海外处理。任何误判都可以通过 `--region` 覆盖。

## 软件源策略

只替换安装器自己添加的 Docker CE 仓库，不改写用户现有系统源。

| 环境 | Docker CE 仓库 | Docker Hub |
| --- | --- | --- |
| 海外 | download.docker.com | 官方直连 |
| 腾讯云 | mirrors.tencent.com/docker-ce | mirror.ccs.tencentyun.com |
| 阿里云 | mirrors.aliyun.com/docker-ce | 用户专属或 DaoCloud |
| 华为云 | repo.huaweicloud.com/docker-ce | 用户专属或 DaoCloud |
| 其他中国网络 | mirrors.aliyun.com/docker-ce | DaoCloud |

镜像加速器写入前会探测 `/v2/`，HTTP 200 或 401 均表示 Registry 可达。已有
`daemon.json` 使用 `jq` 合并，原文件会先备份。检测到其他运行中容器时默认不
重启 Docker，避免无授权中断；镜像拉取阶段仍可使用显式镜像前缀回退。

## 数据布局

```text
/opt/s-ui/
  .env
  docker-compose.yml
  cert/
  db/
  install-report.txt

/etc/s-ui-installer/config.env
/usr/local/sbin/s-ui-manager
/var/backups/s-ui-installer/
/var/lib/s-ui-installer/generated-certs/
```

报告和状态文件使用 `0600`。证书为 `0644`，私钥为 `0600`。

## 回滚

升级前通过 SQLite `.backup` API 创建一致性数据库副本，再复制 Compose、环境
变量和证书。`s-ui-manager restore` 会先对当前状态再做一份安全备份，然后才
停止容器并恢复目标数据库。
