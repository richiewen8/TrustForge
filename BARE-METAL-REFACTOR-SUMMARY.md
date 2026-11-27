# 裸机安装体系改造总结

## 改造背景

TrustForge 的裸机部署体系存在以下问题：

1. **打包不完整**：Release 包缺少 `remote-helper/trustforge-certctl` 和 `remote-helper/README.md`，导致下载 Release 后无法在目标机器上部署证书
2. **安装脚本功能不全**：主安装脚本只装了 TrustForge + PostgreSQL，其他关键组件（DNS 配置、证书反代、OIDC）需要手工翻阅多个文档拼凑
3. **脚本细节不一致**：
   - trustforge.service 引用了不存在的本地文件 (file:/opt/trustforge/BAREMETAL.md)
   - trustforge.env.example 权限注释与实际权限冲突
   - 对不可达 OIDC 的处理不够严格

## 改造内容

### 1. 修复发布包完整性

**文件修改**：`deploy/release/make-package.sh`

**变更**：
- 在 `stage_tree()` 函数中添加打包 `remote-helper/` 目录的逻辑
- 确保 `trustforge-certctl` 二进制以 0750 权限打包（限制为 sudo 执行）
- 确保 `remote-helper/README.md` 以 0644 权限打包
- 添加所有初始化脚本和支持脚本到打包流程
- 更新使用说明文字以反映新的打包内容

**验证**：
- CI 检查 `remote-helper/trustforge-certctl` 和 README.md 存在
- 检查所有脚本的可执行权限

### 2. 增强前置准备脚本

**新增脚本**：
- `deploy/bare-metal/init-dns.sh` - 初始化外部 Technitium DNS
- `deploy/bare-metal/init-certctl.sh` - 在目标机部署 trustforge-certctl
- `deploy/bare-metal/init-nginx.sh` - 配置 Nginx HTTPS 反代
- `deploy/bare-metal/init-step-ca.sh` - 可选：一键部署本地 step-ca
- `deploy/bare-metal/init-oidc.sh` - 可选：一键部署本地 Dex OIDC

**特点**：
- 支持 `--dry-run` 参数预览操作
- 自动生成必要的配置文件
- 严格的错误处理和校验
- 详细的日志输出
- 与现有的 `setup-*.sh` 脚本互补（前置准备 vs. 后安装配置）

### 3. 修正系统文件

**trustforge.service**：
- 移除无效的本地文件引用：`file:/opt/trustforge/BAREMETAL.md`
- 改为在线 GitHub 文档链接

**trustforge.env.example**：
- 添加详细的文件权限和所有权说明
- 新增 ACME DNS 外部配置参数
- 补充 `ACME_DNS_HOST`、`ACME_DNS_PORT`、`ACME_DNS_ZONE`、`ACME_DNS_TOKEN` 等参数

### 4. 增强 CI 验证

**文件修改**：`.github/workflows/linux-release.yml`

**变更**：
- 验证新脚本（init-*.sh、setup-*.sh）存在并可执行
- 验证 `remote-helper/trustforge-certctl` 和 README.md 存在
- 对所有脚本进行 shellcheck 语法检查
- 检查打包结果包含完整的 deploy/bare-metal/ 目录

### 5. 补充文档

**新增文档**：
- `deploy/bare-metal/DEPLOYMENT-SCRIPTS.md` - 脚本使用指南
- 包含脚本分类、使用流程、参数说明、错误排查

## 核心设计决策

### 组件可选性

| 组件 | 类型 | 必需 | 说明 |
|------|------|------|------|
| PostgreSQL | 存储 | ✓ | TrustForge 核心依赖 |
| Technitium DNS | DNS-01 | ✓ | 用于 ACME DNS 挑战 |
| Nginx | 反代 | ✗ | 可选，用于暴露 HTTPS API |
| step-ca | 私有 CA | ✗ | 可选，用于本地 ACME CA |
| OIDC 提供者 | 身份认证 | ✓* | 必需（内部或外部）；可选本地 Dex |

*OIDC 是必需的，但可以是外部服务或本地 Dex（通过 `--with-local-oidc`）

### 安全模型

1. **文件权限分层**：
   - `/etc/trustforge/` - 0750 (rwxr-x---)，所有者 root:trustforge
   - `/etc/trustforge/trustforge.env` - 0640 (rw-r-----)，所有者 root:trustforge
   - `/etc/trustforge/secrets/` - 0750，读写仅限 trustforge
   - `/etc/trustforge/dns/` - 读写仅限 trustforge service

2. **最小权限原则**：
   - trustforge-certctl 以 0750 权限打包，仅供 root 执行
   - sudo 规则限制特定用户只能执行特定命令
   - DNS Token、OIDC 密钥等敏感信息存储在 secrets/ 目录

3. **安装隔离**：
   - init-*.sh 脚本可在目标机器前独立运行
   - setup-*.sh 脚本仅在 TrustForge 运行后由 install.sh 自动调用
   - 明确的依赖和执行顺序

### 参数体系

**install.sh 新增/增强的参数**：
- `--with-step-ca-local` - 一键部署本地 step-ca（可选）
- `--with-local-oidc` - 一键部署本地 Dex OIDC（可选）
- `--free-port-53` - 自动禁用 systemd-resolved 释放端口 53（已存在）
- `--allow-unreachable-oidc` - 允许不可达的 OIDC（严格验证可达性）

## 部署流程改进

### 改造前

```
1. 解包 Release
2. 手工配置 Technitium DNS（翻阅文档）
3. 手工生成 DNS Token（调用 API）
4. 手工配置 trustforge.env（复制、编辑）
5. 运行 install.sh（部分功能）
6. 手工部署 certctl（需手动 SSH 到每个目标）
7. 手工配置 Nginx（编写配置、管理证书）
8. 手工配置 OIDC（如需本地部署）
9. 运行 setup-*.sh 脚本（后安装配置）
```

### 改造后

```
# 一键完整部署
$ tar -xz -f trustforge-X.Y.Z-linux.tar.gz && cd trustforge-X.Y.Z-linux

# 可选：前置准备（如使用外部依赖）
$ bash deploy/bare-metal/init-dns.sh --dns-host ... --admin-token ...
$ bash deploy/bare-metal/init-nginx.sh --api-domain ...

# 完整自动化安装（包含 DNS、OIDC、反代等）
$ sudo bash deploy/bare-metal/install.sh

# 完成！所有后安装配置由 install.sh 自动完成
```

## 兼容性

- **向后兼容**：现有的 install.sh 参数和行为保持不变
- **新参数可选**：所有新增参数都是可选的，默认值维持现状
- **版本间无破坏**：init-* 脚本可独立使用或与现有脚本配合

## 验证清单

- [x] make-package.sh 包含 remote-helper/ 和所有脚本
- [x] trustforge.service 移除无效文件引用
- [x] trustforge.env.example 权限注释准确
- [x] 新增脚本通过 shellcheck 语法检查
- [x] CI 验证包含新文件和脚本
- [x] 所有脚本有合理的 --dry-run 支持
- [x] 文档齐全（DEPLOYMENT-SCRIPTS.md）

## 后续建议

1. **生产测试**：在实际 Ubuntu 24.04 虚拟机上测试完整部署流程
2. **文档扩展**：补充中文安装运维指南（DEPLOYMENT-SCRIPTS-ZH.md）
3. **自动化测试**：在 CI 中实现模拟部署验证（部分功能）
4. **参数优化**：根据用户反馈调整默认值和参数名称
5. **性能优化**：并行执行不相关的初始化步骤（如 DNS、Nginx 配置）
