# TrustForge 实施计划

本文是 TrustForge 的执行清单。每个阶段完成后更新状态、交付物和未决项；实现细节改变时同步更新本文件与 `TRUSTFORGE-ARCHITECTURE.md`。

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
- [ ] 在实际 PostgreSQL 和 OIDC issuer 环境中运行 API 并验证服务登记、任务创建、权限拒绝和状态查询。

阶段 2 当前实现状态：API 宿主、Linux 服务登记模型、手动任务创建/查询 API、JWT/RBAC 和开发 PostgreSQL Compose 配置已实现；整个解决方案编译通过。API 的本机运行验证尚待提供 HTTPS OIDC issuer/audience 配置；持久层已通过实际 PostgreSQL smoke run 验证。

## 阶段 3：可靠任务 Worker 与端口适配器

### 实施项

- [ ] 新建 Worker 宿主和持久任务领取机制，使用 PostgreSQL 事务锁/租约防止多 Worker 重复领取。
- [ ] 定义窄接口：`ICertificateIssuer`（ACME）、`IDnsChallengeProvider`（Technitium）、`ILinuxCertificateDeployer`（SSH）。
- [ ] 加入每阶段超时、幂等重试策略、取消边界、崩溃恢复对账和任务阶段错误摘要。
- [ ] 在真实外部适配器前提供仅用于开发/隔离环境的模拟实现，验证状态机编排。
- [ ] 引入 outbox 或等效事务性事件模式，保证任务提交与异步工作通知不会丢失。

### 完成条件

- Worker 重启后能从 PostgreSQL 当前状态恢复任务。
- 多 Worker 不会同时执行同一服务的证书部署任务。
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

当前下一步：配置一个开发用 HTTPS OIDC issuer/audience，在 PostgreSQL 沙箱上运行 `TrustForge.Api`，验证服务登记、权限控制、手动任务创建和任务历史查询；随后实现持久化 Worker 与 PostgreSQL 任务领取/恢复，再接 Smallstep ACME、Technitium DNS-01 和 SSH。
