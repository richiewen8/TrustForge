# TrustForge 裸机部署脚本指南

本目录包含 TrustForge 裸机部署的完整脚本套件，支持自动化的前置准备和后安装配置。

## 脚本分类

### 核心安装脚本

- **install.sh** - 主安装脚本，负责 TrustForge 和 PostgreSQL 的完整部署

### 前置准备脚本（Pre-deployment）

这些脚本用于在运行 install.sh 前准备所需的依赖和组件：

- **init-dns.sh** - 初始化外部 Technitium DNS 服务器，创建 ACME 挑战 Zone 并生成最小权限 Token
- **init-certctl.sh** - 在目标机器上一键部署 trustforge-certctl（证书部署助手）
- **init-nginx.sh** - 配置 Nginx HTTPS 反代用于 TrustForge API
- **init-step-ca.sh** - （可选）一键部署本地 step-ca 私有 CA
- **init-oidc.sh** - （可选）一键部署本地 Dex OIDC 提供者

### 后安装配置脚本（Post-deployment）

这些脚本由 install.sh 自动调用（通过 `run_post_install_stack()`），用于在 TrustForge 运行后配置各项服务：

- **setup-acme-dns.sh** - 配置 DNS-01 ACME 挑战（使用 Technitium DNS）
- **setup-nginx-tls.sh** - 配置 Nginx 反代并注册证书自动续签
- **setup-oidc.sh** - 配置 OIDC 集成
- **setup-step-ca.sh** - 配置 step-ca ACME 账户和集成

### 支持脚本

- **common.sh** - 通用函数库（被 setup-* 脚本使用）
- **build-and-verify-in-container.sh** - Docker 构建验证脚本
- **install-target-helper.sh** - 目标机器助手安装脚本

## 使用流程

### 场景 1：完整自动化部署（推荐）

```bash
# 1. 在源机器上（或容器内）准备好所需配置
source_host $ ./init-dns.sh \
  --dns-host technitium.example.com \
  --dns-port 53 \
  --admin-token <admin-token> \
  --env-file trustforge.env

# 2. 在目标机器上一键安装 TrustForge
target_host # sudo bash deploy/bare-metal/install.sh

# 3. 自动部署 certctl 到目标机器（可选）
source_host $ ./init-certctl.sh \
  --target-host target.example.com \
  --certctl-binary remote-helper/trustforge-certctl \
  --service-id <service-uuid>

# 4. 配置 Nginx 反代（如果需要 HTTPS API）
target_host # sudo bash deploy/bare-metal/init-nginx.sh \
  --api-domain api.trustforge.internal \
  --api-port 5000

# 5. TrustForge 的后安装配置由 install.sh 自动完成
```

### 场景 2：从 Release 包安装

```bash
# 解包
$ tar -xz -f trustforge-X.Y.Z-linux.tar.gz
$ cd trustforge-X.Y.Z-linux

# 运行安装（包含所有脚本）
$ sudo bash deploy/bare-metal/install.sh

# 可选：手动运行前置脚本
$ bash deploy/bare-metal/init-dns.sh ...
$ bash deploy/bare-metal/init-certctl.sh ...
$ bash deploy/bare-metal/init-nginx.sh ...
```

### 场景 3：可选组件（本地 step-ca + 本地 OIDC）

```bash
# 一键部署本地私有 CA
$ sudo bash deploy/bare-metal/init-step-ca.sh \
  --ca-domain ca.trustforge.internal \
  --ca-password <secure-password>

# 一键部署本地 OIDC
$ sudo bash deploy/bare-metal/init-oidc.sh \
  --oidc-domain id.trustforge.internal \
  --static-password <user-password>

# 然后正常安装 TrustForge（自动集成）
$ sudo bash deploy/bare-metal/install.sh \
  --with-local-oidc \
  --with-step-ca
```

## 参数说明

### init-dns.sh

| 参数 | 说明 | 示例 |
|------|------|------|
| --dns-host | Technitium DNS 服务器主机名或 IP | technitium.local |
| --dns-port | Technitium DNS API 端口 | 53（默认）或 8053（HTTPS） |
| --admin-token | Technitium 管理员 Token | v1:xxx... |
| --acme-zone | ACME 挑战 Zone 名称 | _acme-challenge（默认） |
| --env-file | 要更新的 trustforge.env 文件路径 | /etc/trustforge/trustforge.env |
| --dry-run | 仅显示操作不执行 | 无值标志 |

### init-certctl.sh

| 参数 | 说明 |
|------|------|
| --target-host | 目标机器主机名或 IP |
| --target-user | SSH 用户名（默认：root） |
| --target-ssh-port | SSH 端口（默认：22） |
| --target-ssh-key | SSH 私钥路径（可选） |
| --certctl-binary | trustforge-certctl 二进制路径 |
| --service-id | 服务 UUID |

### init-nginx.sh

| 参数 | 说明 |
|------|------|
| --api-domain | API 域名 |
| --api-port | TrustForge API 本地端口（默认：5000） |
| --tls-port | HTTPS 监听端口（默认：443） |
| --nginx-user | Nginx 用户（默认：www-data） |

### init-step-ca.sh

| 参数 | 说明 |
|------|------|
| --ca-domain | CA 域名 |
| --ca-port | CA API 端口（默认：9000） |
| --ca-password | CA 根密钥密码（必需） |
| --ca-admin-email | 管理员邮箱 |

### init-oidc.sh

| 参数 | 说明 |
|------|------|
| --oidc-domain | OIDC 提供者域名 |
| --oidc-port | Dex 端口（默认：5556） |
| --static-password | 本地用户密码 |
| --oidc-client-secret | OIDC 客户端密钥（可选，自动生成） |

## 文件权限约定

- **可执行脚本（0755）**：install.sh、init-*.sh、setup-*.sh、build-and-verify-in-container.sh
- **配置文件（0644）**：trustforge.env.example、trustforge.service、common.sh、install-target-helper.sh
- **远程助手（0750）**：remote-helper/trustforge-certctl（限制为 sudo 执行）
- **环境文件（0640）**：生成的 /etc/trustforge/trustforge.env（root:trustforge，仅包含敏感数据）

## 错误排查

### 1. Technitium DNS 连接失败

```bash
# 检查 DNS 服务器可达性
$ curl -H "X-Admin-Token: <token>" http://technitium.local:8053/api/list

# 验证防火墙规则
$ sudo ufw allow in on eth0 to 127.0.0.1 port 8053
```

### 2. SSH 部署失败

```bash
# 验证 SSH 密钥权限
$ chmod 0600 ~/.ssh/trustforge_key
$ ssh -i ~/.ssh/trustforge_key -p 22 root@target.host "id"
```

### 3. Nginx 配置错误

```bash
# 检查配置语法
$ sudo nginx -t

# 查看错误日志
$ sudo tail -f /var/log/nginx/error.log
```

### 4. OIDC 不可达

```bash
# 如果 OIDC 在防火墙后或 NAT 内，使用 --allow-unreachable-oidc
$ sudo bash deploy/bare-metal/install.sh --allow-unreachable-oidc

# 或部署本地 OIDC
$ sudo bash deploy/bare-metal/init-oidc.sh --oidc-domain id.local --static-password xxx
$ sudo bash deploy/bare-metal/install.sh --with-local-oidc
```

## 安全建议

1. **环境文件权限**：/etc/trustforge/trustforge.env 必须为 0640，仅 root:trustforge 可读
2. **密钥保管**：所有生成的密钥（CA、OAuth 客户端密钥）应备份到安全位置
3. **SSH 密钥**：用于 certctl 部署的 SSH 密钥应为 0600，存储在 /etc/trustforge/secrets
4. **Sudo 规则**：sudo 配置应限制为仅允许执行必要的命令（trustforge-certctl）
5. **防火墙**：受限 DNS、OIDC 和反代端口的访问

## 文档参考

- **BAREMETAL.md** - 裸机部署的详细决策文档
- **DEPLOYMENT.md** - 生产部署最佳实践
- **OPERATIONS.md** - 运维指南和故障排查
- **remote-helper/README.md** - trustforge-certctl 安装和配置指南
