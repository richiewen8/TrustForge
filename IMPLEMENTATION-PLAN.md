# TrustForge 实施计划

本文是 TrustForge 的执行清单。每个阶段完成后更新状态、交付物和未决项；实现细节改变时同步更新本文件与 `TRUSTFORGE-ARCHITECTURE.md`。

## 产品合并：统一 TrustForge 构建与部署

- [x] 将 TrustForge API 与 Technitium DNS 核心集成到同一宿主进程。
- [x] 将 Linux 可用 DNS 核心和 DNS 应用纳入唯一的 `TrustForge.sln`；排除 Windows 服务与托盘启动器。
- [x] 根 Docker Compose 改为构建并运行单个 TrustForge 应用镜像，PostgreSQL 作为同一部署栈中的持久化依赖；不再拉取独立 Technitium 镜像。
- [x] Docker 启动前应用 PostgreSQL EF migrations；DNS 配置、DNS 日志和数据库分别持久化。
- [x] 根 README 和部署手册改为 TrustForge 产品入口。
- [x] 在 Docker Desktop Linux 容器环境构建并启动根 Compose；临时映射 API、DNS UDP/TCP 和管理 UI 端口，验证 PostgreSQL readiness、API health、DNS UDP/TCP 查询和 DNS UI。
- [ ] DNS 管理 UI 仍使用其自己的 Technitium 登录；统一登录、入口/反向代理和统一导航属于后续产品工作。

目录约定：开发只打开根目录的 `TrustForge.sln`；部署只使用根目录 `docker-compose.yml` 中的 TrustForge 应用镜像，不再单独部署 Technitium DNS Server。

## 已确定的产品与技术决策

- [x] 以 Technitium DNS Server 为 DNS 基座；TrustForge 核心保持独立模块，通过适配器连接 DNS。
- [x] 首版 TrustForge 控制服务与受管服务均为 Linux；不支持 Windows 服务部署。
- [x] 远程 Linux 主机连接方式为 SSH/SFTP，采用主机密钥校验、专用低权限账号和秘密凭据引用。
- [x] 服务私钥在目标 Linux 主机生成并保留；TrustForge 收集 CSR，不回传私钥。
- [x] CA 采用 Smallstep `step-ca`，通过标准 ACME 接入；内网域名优先 DNS-01，挑战记录由 Technitium 适配器管理。
- [x] TrustForge 主数据库采用 PostgreSQL；建议 Npgsql + EF Core migrations。
- [x] 证书部署目标为 Linux PEM 文件，包含原子切换、服务重载、健康检查和失败回滚。
- [x] 证书任务状态机和独立 `TrustForge.Core` 项目骨架已建立。

## 阶段 1：PostgreSQL 持久化基础（已完成）

### 实施项

- [x] 新建 `TrustForge.Persistence` 项目，引用 `TrustForge.Core`；引入 PostgreSQL provider 和 EF Core migrations。
- [x] 定义 `TrustForgeDbContext` 和传入连接字符串的服务注册入口；宿主启动迁移与健康检查待 API/Worker 宿主阶段接入。
- [x] 持久化 `CertificateJob` 和 `CertificateJobTransition`；状态变更与历史事件在同一次 `SaveChanges` 事务提交。
- [x] 添加约束：主键、幂等唯一索引、任务版本并发更新条件和 transition 外键。
- [x] 实现 `ICertificateJobStore`：按 ID 查询、按幂等作用域查询、原子创建和乐观并发更新。
- [x] 定义初始数据库迁移、模型快照和初始化说明；连接字符串由宿主从安全配置/秘密管理来源传入，不写入仓库。
- [x] 就绪端点在数据库不可用或存在待应用迁移时返回 503；显式迁移命令失败时以非零状态退出。
- [ ] 补充并演练 PostgreSQL 备份和恢复操作。

### 阶段交付物

- [x] 可单独构建的 Persistence 项目。
- [x] 首版数据库 migration 与可配置 PostgreSQL 连接注册入口。
- [x] `CertificateJobCoordinator` 在真实 PostgreSQL 上创建任务并持久化状态转换；独立进程成功恢复终态前的任务状态和历史。

### 完成条件

- [x] 数据库约束可阻止同一作用域幂等键重复创建任务。
- [x] 状态与对应 transition history 通过同一 `SaveChanges` 事务写入。
- [x] 并发更新使用版本条件拒绝过期写入。
- [x] 已启动的 PostgreSQL 17 空白应用 schema 成功应用两条检查入库的 migration。
- [ ] 在已有生产数据的数据库上验证后续 migration 升级策略。

阶段 1 验证记录：开发沙箱 PostgreSQL 17 已应用 `202611140001_InitialCertificateJobs` 和 `202611140002_ManagedServices`。临时 smoke run 创建任务、写入 `Queued → Connecting → GeneratingCsr`，随后由新的 dotnet 进程读回 `state=GeneratingCsr`、`version=2`、`transitions=2`；验证记录已清理。`dotnet build TrustForge.sln` 通过，EF Core 工具确认模型快照无待处理变化。

## 阶段 2：TrustForge API 与服务登记

### 实施项

- [x] 新建独立 `TrustForge.Api` 宿主项目，不将 PKI 数据模型塞入 Technitium DNS 核心。
- [x] 实现请求验证、结构化默认日志、存活/就绪端点；统一错误响应格式待后续完善。
- [x] 定义并持久化 `ManagedService`、证书模板引用、主机 SSH 配置引用、证书/链/私钥路径、reload 与 health-check 配置。
- [x] 实现服务创建与详情接口；更新/启停接口待后续完善；秘密值只保存外部秘密引用。
- [x] 实现手动创建证书任务与任务查询接口；任务以 `Queued` 持久化，Worker 执行仍未接入。
- [x] 配置 JWT bearer 验证及 PlatformAdmin、CertificateOperator、Auditor 授权策略；需部署方提供 HTTPS OIDC issuer 和 audience。

### 首批 API

- `POST /api/v1/services`
- `GET /api/v1/services/{id}`
- `PUT /api/v1/services/{id}`
- `POST /api/v1/services/{id}/certificate-jobs`
- `GET /api/v1/certificate-jobs/{id}`
- `POST /api/v1/certificate-jobs/{id}/cancel`（仅激活前可取消）

### 完成条件

- [x] API 代码可创建并检索服务；手动请求返回稳定任务 ID。
- [x] 相同作用域幂等键返回同一任务；实现从 PostgreSQL 读取任务状态/历史。
- [x] 写接口实施 JWT 角色授权；独立持久化的审计事件表尚未进入本阶段。
- [x] 本机 API 使用 PostgreSQL 启动，`/health/live` 与 `/health/ready` 返回 200；匿名 `POST /api/v1/services` 返回 401。
- [x] 在实际 PostgreSQL 17 和 Keycloak 26.8.2 开发 issuer 环境中验证 API：匿名写入 401；PlatformAdmin 服务登记 201、手动任务 202、查询 200；幂等重放返回同一任务；无 TrustForge 角色的已认证用户读取被拒绝为 403；任务 `requestedBy` 与 OIDC `sub` 相同。

阶段 2 当前实现状态：API 宿主、Linux 服务登记模型、手动任务创建/查询 API、JWT/RBAC 和本地 Keycloak/PostgreSQL 开发 Compose 配置已实现。Keycloak 返回的 access token 已验证包含 issuer、`sub`、`trustforge-api` audience 和 realm roles；API 通过真实签名校验，并完成服务登记、任务创建、幂等重放、任务读取以及无角色拒绝验证。手动任务处于 `Queued/version 0` 时尚无状态迁移行，首次 Worker 转换后才产生历史记录。

## 阶段 3：可靠任务 Worker 与端口适配器

### 实施项

- [x] 在统一 API 宿主中加入可关闭的 Background Worker；PostgreSQL 使用 `FOR UPDATE SKIP LOCKED` 原子领取，并新增迁移 `202611140003_CertificateJobLeases`。
- [x] 添加租约 owner、随机 fencing token、数据库时钟过期时间、attempt count、next-attempt 调度字段；续租、释放和带 token 的状态写入均在数据库校验。
- [x] 崩溃恢复通过租约超时重领；异常重试采用有上限的指数退避；过期 Worker 不能使用旧 token 更新任务。
- [x] Worker 默认关闭，且仅在配置启用并注册真实处理器后运行，防止空处理器吞掉待签任务。
- [ ] 新建/注入实际签发处理器，并按任务当前持久状态恢复各阶段；外部操作必须幂等并实现对账。
- [ ] 定义窄接口：`ICertificateIssuer`（ACME）、`IDnsChallengeProvider`（Technitium）、`ILinuxCertificateDeployer`（SSH）。
- [x] 建立租约续期和有界重试基础；每阶段超时、取消边界和失败阶段摘要由后续实际 Pipeline 处理器补齐。
- [ ] 在真实外部适配器前提供仅用于开发/隔离环境的模拟实现，验证状态机编排。
- [ ] 引入 outbox 或等效事务性事件模式，保证任务提交与异步工作通知不会丢失。

### 完成条件

- [x] Worker 重启/崩溃后租约过期可从 PostgreSQL 当前状态重新领取任务。
- [x] 多 Worker 通过 `SKIP LOCKED` 与每次领取的新 fencing token 防止同一任务被同时持有；外部阶段仍须幂等对账。
- 取消仅在激活前生效；激活后失败必须进入回滚流程。

## 阶段 4：Smallstep ACME 与 Technitium DNS-01

### 实施项

- [ ] 配置 `step-ca` ACME directory、信任链、ACME account key 与（若启用）EAB secret 引用。
- [ ] 实现 ACME new-order、授权挑战、finalize CSR、下载和验证证书链的客户端流程。
- [ ] 实现 DNS-01：生成 TXT 值、通过 Technitium API 限定区域写入、等待权威校验后完成 ACME 授权，并清理挑战记录。
- [ ] 对 DNS 记录变更执行最小权限授权、冲突检测、超时清理和审计。
- [ ] 证书下载后校验 issuer、SAN、EKU/KeyUsage、算法和有效期是否符合服务模板。
- [ ] 单独设计吊销操作的 CA 管理通道；step-ca ACME Provisioner 不提供吊销能力。

### 完成条件

- 手动任务能经 ACME+DNS-01 得到与目标私钥对应的证书。
- 挑战记录能在成功、失败和任务恢复路径中安全清理。
- ACME account key、EAB 凭据和目标私钥互相隔离，均不进入普通日志/数据库字段。

## 阶段 5：SSH/SFTP Linux 部署与回滚

### 实施项

- [ ] 固定 SSH 主机密钥指纹；提供连接测试和指纹变更阻断。
- [ ] 实现 SSH 凭据引用解析、专用低权限账号、SFTP 暂存和连接超时。
- [ ] 编写 Linux root-owned `trustforge-certctl` 安装助手及版本化协议：生成密钥/CSR、校验 CSR、安装证书、原子切换、执行固定 reload/health check、回滚。
- [ ] 助手仅接受服务 ID/任务 ID和受白名单限制的操作，不接受任意 shell 命令或任意路径。
- [ ] 实现部署版本记录、文件权限核对、实际服务端证书指纹探测和失败告警。
- [ ] 清理暂存与回滚槽位按保留策略执行，不得删除当前有效版本。

### 完成条件

- 私钥只在目标 Linux 主机生成并保留。
- SSH 指纹不匹配时不执行远程操作。
- 成功部署后服务实际呈现的证书指纹与证书库存匹配。
- reload/health check 失败时恢复旧版本；回滚失败时停止自动操作并告警、保留现场。

## 阶段 6：自动续期与生产运行准备

### 实施项

- [ ] 为服务配置续期提前量和自动续期开关；调度扫描仅对进入窗口的服务创建任务。
- [ ] 对同一服务施加数据库级并发保护，防止重复续期/部署。
- [ ] 配置到期提醒、任务失败告警、审计导出、备份恢复演练和 CA 运维手册。
- [ ] 准备 PostgreSQL 备份、升级迁移、密钥轮换、灾难恢复及监控指标文档。
- [ ] 评估生产 HSM/KMS、step-ca 高可用和 TrustForge 多实例部署。

### 完成条件

- 自动续期按策略运行，不会在每次扫描时重复签发。
- 失败重试可恢复，服务继续使用旧证书直至新证书成功部署。
- 运维人员可依据文档恢复 PostgreSQL、CA 配置/密钥备份和服务证书部署状态。

## 当前下一步

阶段 3 Worker 基础已实现并通过 Release 构建：PostgreSQL 租约/安全领取、版本与 token 双重校验、崩溃恢复、心跳续租和退避重试。Worker 默认关闭；当前没有虚假的签发模拟器或生产处理器。下一步实现开发模拟处理器和 Pipeline 协议，然后依次接 Smallstep ACME、Technitium DNS-01、SSH 部署与回滚。
