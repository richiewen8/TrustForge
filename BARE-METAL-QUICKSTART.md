# 🔧 TrustForge 裸机安装体系改造 - 快速开始

## 📋 改造概览

TrustForge 的裸机部署体系已完全改造，从"东拼西凑"的手工流程升级为完整的自动化一键部署方案。

**关键改进**：
- ✅ Release 包现包含完整组件（trustforge-certctl + 所有脚本）
- ✅ 前置准备脚本自动化（DNS、Nginx、OIDC、step-ca）
- ✅ 修正系统文件引用和权限说明
- ✅ 增强 CI 验证覆盖范围
- ✅ 完善部署文档

## 🚀 快速开始

### 最简单的部署（3 步）

```bash
# 1. 解包 Release 或检出代码
$ tar -xz -f trustforge-X.Y.Z-linux.tar.gz && cd trustforge-X.Y.Z-linux
# 或
$ git clone https://github.com/richiewen8/TrustForge && cd TrustForge

# 2. 一键安装（包含所有自动化配置）
$ sudo bash deploy/bare-metal/install.sh

# 3. 完成！所有组件已启动并配置
# 访问 DNS 控制台：http://127.0.0.1:5380
# 访问 TrustForge API：http://127.0.0.1:5000
```

### 有外部依赖时（5 步）

```bash
# 1-3. 如上...

# 4a. 如果使用外部 Technitium DNS
$ bash deploy/bare-metal/init-dns.sh \
  --dns-host technitium.example.com \
  --dns-port 53 \
  --admin-token <your-token> \
  --env-file /etc/trustforge/trustforge.env

# 4b. 如果需要 HTTPS API（Nginx 反代）
$ sudo bash deploy/bare-metal/init-nginx.sh \
  --api-domain api.trustforge.internal

# 5. 运行主安装脚本
$ sudo bash deploy/bare-metal/install.sh
```

### 完整功能部署（本地 CA + OIDC）

```bash
# 可选：一键部署本地 step-ca（私有 CA）
$ sudo bash deploy/bare-metal/init-step-ca.sh \
  --ca-domain ca.trustforge.internal \
  --ca-password <secure-password>

# 可选：一键部署本地 Dex（OIDC 提供者）
$ sudo bash deploy/bare-metal/init-oidc.sh \
  --oidc-domain id.trustforge.internal \
  --static-password <user-password>

# 安装 TrustForge（自动集成所有组件）
$ sudo bash deploy/bare-metal/install.sh \
  --with-local-oidc \
  --with-step-ca-local
```

## 📂 文件组织

```
deploy/bare-metal/
├── install.sh                     # 主安装脚本
├── trustforge.service             # systemd 单元文件
├── trustforge.env.example         # 配置模板
├── DEPLOYMENT-SCRIPTS.md          # 🆕 完整脚本指南
│
├── 🆕 前置准备脚本（Pre-deployment）
├── init-dns.sh                    # 初始化 Technitium DNS
├── init-certctl.sh                # 部署 trustforge-certctl
├── init-nginx.sh                  # 配置 Nginx 反代
├── init-step-ca.sh                # 部署本地 step-ca
├── init-oidc.sh                   # 部署本地 Dex
│
├── 后安装配置脚本（Post-deployment）
├── setup-acme-dns.sh              # 配置 DNS-01 ACME
├── setup-nginx-tls.sh             # 配置 Nginx TLS
├── setup-oidc.sh                  # 配置 OIDC
├── setup-step-ca.sh               # 配置 step-ca ACME
│
└── 支持脚本
	├── common.sh
	├── install-target-helper.sh
	└── build-and-verify-in-container.sh
```

## 🔗 重要链接

| 文档 | 说明 |
|------|------|
| [DEPLOYMENT-SCRIPTS.md](deploy/bare-metal/DEPLOYMENT-SCRIPTS.md) | 脚本完整指南（参数、流程、排查） |
| [BARE-METAL-REFACTOR-SUMMARY.md](BARE-METAL-REFACTOR-SUMMARY.md) | 改造总结（背景、决策、验证） |
| [BARE-METAL-REFACTOR-CHECKLIST.md](BARE-METAL-REFACTOR-CHECKLIST.md) | 改造检查清单（进度、安全、测试） |
| [BAREMETAL.md](BAREMETAL.md) | 裸机部署决策文档（原始） |
| [DEPLOYMENT.md](DEPLOYMENT.md) | 生产部署指南 |
| [OPERATIONS.md](OPERATIONS.md) | 运维操作指南 |

## 🆕 新增脚本一览

### init-dns.sh
**用途**：初始化外部 Technitium DNS  
**主要功能**：
- 验证 DNS 服务器可达性
- 创建 ACME 挑战 Zone
- 生成最小权限 API Token
- 更新 trustforge.env

**示例**：
```bash
bash init-dns.sh \
  --dns-host 192.168.1.10 \
  --admin-token v1:xxx... \
  --env-file trustforge.env
```

### init-certctl.sh
**用途**：在目标机一键部署 trustforge-certctl  
**主要功能**：
- SSH 连接验证
- 二进制部署
- 目录和权限设置
- sudo 规则配置

**示例**：
```bash
bash init-certctl.sh \
  --target-host target.example.com \
  --certctl-binary remote-helper/trustforge-certctl \
  --service-id <uuid>
```

### init-nginx.sh
**用途**：配置 Nginx HTTPS 反代  
**主要功能**：
- 自签名证书生成
- Nginx 反代配置
- DH 参数生成
- 配置启用和重载

**示例**：
```bash
sudo bash init-nginx.sh \
  --api-domain api.trustforge.internal \
  --tls-port 443
```

### init-step-ca.sh
**用途**：可选 - 部署本地 step-ca 私有 CA  
**主要功能**：
- step-ca 下载安装
- PKI 初始化
- systemd 服务配置

**示例**：
```bash
sudo bash init-step-ca.sh \
  --ca-domain ca.trustforge.internal \
  --ca-password xxxxx
```

### init-oidc.sh
**用途**：可选 - 部署本地 Dex OIDC 提供者  
**主要功能**：
- Dex 下载安装
- 配置文件生成
- systemd 服务配置

**示例**：
```bash
sudo bash init-oidc.sh \
  --oidc-domain id.trustforge.internal \
  --static-password xxxxx
```

## 🔄 改造前后对比

### 改造前的部署流程（手工）
```
1. 解包
2. 翻阅 BAREMETAL.md、DEPLOYMENT.md 获取部署步骤
3. 手工配置 Technitium DNS（调用 API）
4. 手工编辑 trustforge.env（复制、填写敏感值）
5. 运行 install.sh 安装 TrustForge + PostgreSQL（部分功能）
6. 手工部署 certctl 到每个目标机（SSH、权限）
7. 手工配置 Nginx（编写配置、管理证书）
8. 手工配置 OIDC（如需本地部署）
9. 手工运行 setup-*.sh 脚本进行后安装配置
← 容易出错，耗时，依赖人工知识
```

### 改造后的部署流程（自动化）
```
1. 解包
2. 可选：运行前置准备脚本（init-*.sh）
   - 自动初始化 DNS
   - 自动部署 certctl
   - 自动配置反代
   - 自动部署 CA/OIDC（如需）
3. 运行 install.sh 一键部署
   ↓ 自动完成所有配置
   - 安装运行时、PostgreSQL、TrustForge
   - 配置 DNS-01 ACME
   - 配置 Nginx TLS 和证书自动续签
   - 配置 OIDC 集成
   - 启动所有服务
4. 完成！所有组件已启动
← 完全自动化，快速，配置统一
```

## 🔐 安全特性

- **文件权限分层**：
  - trustforge.service (0644)
  - trustforge.env.example (0644)
  - 生成的 trustforge.env (0640, root:trustforge)
  - trustforge-certctl (0750)

- **最小权限原则**：
  - DNS Token 仅限指定 Zone
  - sudo 规则限制特定用户和命令
  - 敏感文件存储在 /etc/trustforge/secrets

- **验证机制**：
  - HTTPS 要求（OIDC 必须 HTTPS）
  - 连通性检查（DNS、OIDC）
  - 配置验证（Nginx -t、systemd verify）

## ✅ 验证清单

在生产部署前，请确认：
- [ ] 已阅读 DEPLOYMENT-SCRIPTS.md 了解所有脚本
- [ ] 已验证外部依赖可访问（DNS、OIDC）
- [ ] 已准备好必要的凭证（DNS Token、OIDC 密钥）
- [ ] 已在测试环境验证完整部署流程
- [ ] 已备份生成的 trustforge.env 和密钥文件
- [ ] 已配置防火墙规则（53/UDP、5000/TCP、443/TCP 等）

## 📞 获取帮助

**常见问题**：参见 DEPLOYMENT-SCRIPTS.md 的"错误排查"章节

**GitHub Issues**：https://github.com/richiewen8/TrustForge/issues

**文档**：
- 完整安装指南：https://github.com/richiewen8/TrustForge/blob/master/BAREMETAL.md
- 运维指南：https://github.com/richiewen8/TrustForge/blob/master/OPERATIONS.md

---

**改造完成日期**：2026-11-24  
**支持版本**：TrustForge 0.1.0+  
**目标平台**：Ubuntu 24.04 LTS / systemd / .NET 10
