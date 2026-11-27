# TrustForge 裸机部署改造 - Docker 验证指南

本指南说明如何使用 Docker 验证 TrustForge 裸机部署体系的改造。

## 📋 目录

- [快速开始](#快速开始)
- [验证方式](#验证方式)
- [测试内容](#测试内容)
- [故障排查](#故障排查)
- [完整示例](#完整示例)

## 🚀 快速开始

### 前置要求

- Docker 20.10+ 或 Docker Desktop
- 2GB+ 可用磁盘空间
- 10+ 分钟执行时间

### 快速验证（3 步）

```bash
# 1. 进入项目根目录
cd TrustForge

# 2. 运行验证脚本
bash scripts/docker-verify.sh full

# 3. 查看结果
# 如果所有测试通过，您会看到绿色的 ✓ 符号
```

## 验证方式

### 方式 1：Docker 脚本（推荐）

最简单的方式，自动处理构建和测试：

```bash
# 完整验证（构建 + 运行）
bash scripts/docker-verify.sh full

# 仅构建 Docker 镜像
bash scripts/docker-verify.sh build

# 仅运行测试
bash scripts/docker-verify.sh run

# 交互式 shell（调试）
bash scripts/docker-verify.sh shell

# 清理 Docker 资源
bash scripts/docker-verify.sh clean

# 详细输出
bash scripts/docker-verify.sh run --verbose
```

### 方式 2：Docker Compose（用于复杂场景）

适合需要多个服务（PostgreSQL、DNS 等）的集成测试：

```bash
# 启动验证服务
docker-compose -f docker-compose.test.yml up

# 后台运行
docker-compose -f docker-compose.test.yml up -d

# 查看日志
docker-compose -f docker-compose.test.yml logs -f trustforge-verify

# 停止服务
docker-compose -f docker-compose.test.yml down
```

### 方式 3：本地脚本（无 Docker）

如果您没有 Docker 或希望在本机验证：

```bash
# 在 Linux 或 WSL 上运行
bash scripts/verify-deployment.sh

# 或在 macOS 上运行
bash scripts/verify-deployment.sh
```

## 测试内容

### 1️⃣ 文件结构验证
检查所有必需的脚本、二进制和配置文件是否存在：
- ✓ deploy/bare-metal/*.sh 脚本
- ✓ remote-helper/trustforge-certctl 二进制
- ✓ remote-helper/README.md
- ✓ 配置文件和文档

### 2️⃣ 文件权限验证
确保文件权限正确设置：
- ✓ 脚本：0755（可执行）
- ✓ 配置文件：0644（可读）
- ✓ 二进制：0750（sudo 可执行）

### 3️⃣ Bash 语法验证
检查所有脚本的 Bash 语法有效性：
- ✓ 使用 `bash -n` 检查每个脚本
- ✓ 确保没有语法错误

### 4️⃣ Shellcheck 检查
使用 shellcheck 进行代码质量检查：
- ✓ 代码风格检查
- ✓ 潜在错误检测
- ✓ 最佳实践建议

### 5️⃣ 配置文件验证
验证关键配置文件的正确性：
- ✓ trustforge.env.example 包含 ACME_DNS_* 参数
- ✓ trustforge.service 使用正确的文档链接
- ✓ 移除了无效的文件引用

### 6️⃣ 脚本功能验证
检查脚本的核心功能：
- ✓ --help 支持
- ✓ --dry-run 支持
- ✓ 参数处理

### 7️⃣ CI 配置验证
验证 GitHub Actions 工作流包含正确的检查：
- ✓ 新脚本包含在检查列表中
- ✓ remote-helper 文件验证
- ✓ shellcheck 检查

## 测试输出示例

### 成功的验证输出

```
==========================================
   TrustForge Deployment Verification
==========================================
Total Tests: 42
Passed: 42
Pass Rate: 100%
==========================================

✓ All verification tests passed!
```

### 失败时的输出

```
==========================================
   TrustForge Deployment Verification
==========================================
Total Tests: 42
Passed: 40
Failed: 2
Pass Rate: 95%
==========================================

Failed Tests:
  - Configuration File Validation
  - Script Help Output

Please review the failures above.
```

## 故障排查

### Docker 无法启动

**症状**：`Docker daemon is not running`

**解决方案**：
```bash
# macOS / Linux
sudo service docker start

# Windows（Docker Desktop）
# 点击 Docker Desktop 图标启动
```

### 内存不足

**症状**：`docker run` 命令挂起或崩溃

**解决方案**：
```bash
# 检查 Docker 资源限制
docker stats

# 增加 Docker Desktop 内存（macOS/Windows）
# 1. 打开 Docker Desktop 设置
# 2. 增加 Memory 值（建议 4GB+）
# 3. 重启 Docker
```

### 权限问题

**症状**：`permission denied while trying to connect to Docker daemon`

**解决方案**：
```bash
# Linux：将用户加入 docker 组
sudo usermod -aG docker $USER
newgrp docker

# 或使用 sudo
sudo bash scripts/docker-verify.sh full
```

### 镜像构建失败

**症状**：`Build failed` 或 `manifest not found`

**解决方案**：
```bash
# 清理并重新构建
bash scripts/docker-verify.sh clean
bash scripts/docker-verify.sh build --no-cache

# 检查网络连接
docker pull ubuntu:24.04
```

### 脚本权限问题

**症状**：`Permission denied` 执行脚本

**解决方案**：
```bash
# 添加执行权限
chmod +x scripts/docker-verify.sh
chmod +x scripts/verify-deployment.sh
chmod +x scripts/docker-test-entrypoint.sh
```

## 完整示例

### 示例 1：基本验证

```bash
# 进入项目目录
$ cd TrustForge

# 运行验证
$ bash scripts/docker-verify.sh full

# 输出
[docker-verify] TrustForge Deployment Verification (Docker)
[docker-verify] Command: full
[INFO] Docker is available

[docker-verify] Building Docker test image...
[INFO] Docker image built successfully

[docker-verify] Running verification tests in Docker...
[TEST] Starting TrustForge deployment verification
[PASS] File Structure: All required files present
[PASS] File Permissions: All permissions correct (8 checks)
[PASS] Bash Syntax Validation: All scripts have valid syntax
...
[PASS] Application Assembly: TrustForge.dll present

==========================================
   TrustForge Deployment Verification
==========================================
Total Tests: 42
Passed: 42
Pass Rate: 100%
==========================================

✓ All verification tests passed!
```

### 示例 2：交互式调试

```bash
# 进入容器 shell
$ bash scripts/docker-verify.sh shell

# 现在您可以在容器内部运行命令
root@container:/opt/trustforge# ls -la deploy/bare-metal/
root@container:/opt/trustforge# bash deploy/bare-metal/init-dns.sh --help
root@container:/opt/trustforge# shellcheck deploy/bare-metal/init-dns.sh

# 退出
root@container:/opt/trustforge# exit
```

### 示例 3：详细验证

```bash
# 运行带详细输出的验证
$ bash scripts/docker-verify.sh run --verbose

# 会显示所有检查的详细过程
[TEST] Starting: File Structure
[TEST] Checking: deploy/bare-metal/install.sh
[PASS] deploy/bare-metal/install.sh exists
[TEST] Checking: deploy/bare-metal/init-dns.sh
[PASS] deploy/bare-metal/init-dns.sh exists
...
```

### 示例 4：本地无 Docker 验证

```bash
# 在 WSL / Linux / macOS 上直接运行
$ bash scripts/verify-deployment.sh

# 输出
[VERIFY] TrustForge Bare-Metal Deployment Verification
[VERIFY] Project Root: /home/user/TrustForge
[VERIFY] Test Results: .test-results

=== File Structure ===
[PASS] make-package.sh exists
[PASS] install.sh exists
...

==========================================
				 Summary
==========================================
Passed: 40
Failed: 0
Pass Rate: 100%
==========================================

✓ All verification tests passed!
```

## 自定义验证

### 添加自定义测试

编辑 `scripts/docker-test-entrypoint.sh`，在 `main()` 函数中添加新的测试函数：

```bash
# 1. 创建新的测试函数
test_my_feature() {
	test_start "My Feature"

	# 执行检查
	if [[ -f /some/path ]]; then
		test_pass "My Feature" "Check passed"
	else
		test_fail "My Feature" "Check failed"
	fi
}

# 2. 在 main() 中调用
case "$test_type" in
	full-test)
		test_file_structure
		test_file_permissions
		# ... 其他现有测试 ...
		test_my_feature  # 添加新测试
		;;
	...
esac
```

### 修改测试参数

编辑 `docker-compose.test.yml` 修改环境变量或挂载点：

```yaml
services:
  trustforge-verify:
	# ... 其他配置 ...
	environment:
	  - DEBIAN_FRONTEND=noninteractive
	  - MY_CUSTOM_VAR=value  # 添加自定义变量
	volumes:
	  - .:/workspace:ro
	  - ./my-tests:/my-tests  # 添加自定义挂载
```

## 性能优化

### 加速构建

```bash
# 使用本地 Docker 缓存
bash scripts/docker-verify.sh build

# 后续构建会更快
bash scripts/docker-verify.sh run

# 如果需要重新构建，使用 --no-cache
bash scripts/docker-verify.sh build --no-cache
```

### 并行运行

```bash
# 在不同终端运行多个验证
terminal1 $ bash scripts/docker-verify.sh run
terminal2 $ bash scripts/docker-verify.sh shell
```

## 高级用法

### 保存测试结果

```bash
# 重定向输出到文件
bash scripts/docker-verify.sh run > test-results.log 2>&1

# 保存为 JSON（需修改脚本）
bash scripts/docker-verify.sh run --json > test-results.json
```

### 生成测试报告

```bash
# 生成 HTML 报告（需要额外工具）
bash scripts/docker-verify.sh run | \
	tee test-results.txt

# 转换为 HTML
pandoc test-results.txt -o test-results.html
```

## 相关文档

- [BARE-METAL-QUICKSTART.md](../BARE-METAL-QUICKSTART.md) - 快速开始指南
- [DEPLOYMENT-SCRIPTS.md](../deploy/bare-metal/DEPLOYMENT-SCRIPTS.md) - 脚本完整指南
- [BARE-METAL-REFACTOR-SUMMARY.md](../BARE-METAL-REFACTOR-SUMMARY.md) - 改造总结

## 获取帮助

如果验证失败或遇到问题：

1. **检查日志**：运行 `bash scripts/docker-verify.sh run --verbose` 获取详细信息
2. **查看错误**：检查特定失败的测试信息
3. **调试容器**：运行 `bash scripts/docker-verify.sh shell` 进行交互式调试
4. **查看源代码**：检查 `scripts/docker-test-entrypoint.sh` 中的测试逻辑

---

**最后更新**：2026-11-24  
**支持版本**：TrustForge 0.1.0+  
**测试平台**：Ubuntu 24.04 LTS in Docker
