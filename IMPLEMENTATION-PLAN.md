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
- [x] 补充并演练 PostgreSQL 备份和恢复操作。

### 阶段交付物

- [x] 可单独构建的 Persistence 项目。
- [x] 首版数据库 migration 与可配置 PostgreSQL 连接注册入口。
- [x] `CertificateJobCoordinator` 在真实 PostgreSQL 上创建任务并持久化状态转换；独立进程成功恢复终态前的任务状态和历史。

### 完成条件

- [x] 数据库约束可阻止同一作用域幂等键重复创建任务。
- [x] 状态与对应 transition history 通过同一 `SaveChanges` 事务写入。
- [x] 并发更新使用版本条件拒绝过期写入。
- [x] 已启动的 PostgreSQL 17 空白应用 schema 成功应用两条检查入库的 migration。
- [x] 在已有生产数据的数据库上验证后续 migration 升级策略。

阶段 1 验证记录：开发沙箱 PostgreSQL 17 已应用 `202611140001_InitialCertificateJobs` 和 `202611140002_ManagedServices`。临时 smoke run 创建任务、写入 `Queued → Connecting → GeneratingCsr`，随后由新的 dotnet 进程读回 `state=GeneratingCsr`、`version=2`、`transitions=2`；验证记录已清理。`dotnet build TrustForge.sln` 通过，EF Core 工具确认模型快照无待处理变化。

阶段 1 升级策略验证记录（2026-11-15）：新增 `dev/acme-lab/drill-migration.sh`，在独立可弃侧库 `trustforge_upgrade` 上以离线生成的 baseline schema（前 5 迁移，截至 `202611150001_DeploymentVersionsAndAlerts`）播种生产样数据（2 服务 / 5 任务 / 10 转换 / 3 部署版本 / 2 告警，含 PascalCase checkpoint，无密钥材料），经产品真实 `--migrate` 路径（一次性 `--entrypoint dotnet … TrustForge.dll --migrate` 容器）增量应用 `202611150002_RenewalAndActiveJobGuard` + `202611150003_ExpiryReminders`。断言全过：升级前 baseline 无 `renewal_enabled`/active-job 守卫（证明是增量升级而非全新安装）；升级后 history=7、五行计数全保全、既有行取新列默认值（`renewal_enabled=false` / `renewal_lead_time=0` / `certificate_not_after` NULL）、3 新索引 + partial `job_id` 索引 + `ck_certificate_alerts_identity` 约束就位、checkpoint JSON 完好；幂等重跑 no-op；新形态 NULL-job + `dedupe_key` 到期告警可写、重复 dedupe / identity 违规被拒；负例库 `trustforge_upgrade_bad` 播种同服务第 2 个活动任务 → `--migrate` 非零退出（Npgsql `23505` `ux_certificate_jobs_active_service`，实证见 `secrets/upgrade-guard.log`）且每迁移原子回滚（history 停 5、无 partial schema）。两侧库用后即 DROP（仅硬编码名）。ef tools 10.0.14 / runtime 10.0.15 错配使 `migrations script` 拒绝任何具名目标，改用全量脚本 + 按 `START TRANSACTION;` 截断至 baseline（不改全局工具）。全重置链路 reset→setup→deployment→backup→restore→notification→**migration**→renewal→verify 的 `verify.sh` **79 项全过、0 失败**（72 基础 + 7 迁移段），migrationDrill 段行使（非 SKIP）。

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
- [x] 定义 ACME、Technitium DNS-01、Linux SSH 部署接口及逐阶段恢复协议；checkpoint 通过 JSONB 与租约 fencing token 持久化，明确禁止写入私钥和凭据。
- [x] 增加仅 Development 可显式启用的模拟处理器；它逐阶段推进状态机，终态为 `Simulated`，不签证书、不部署，也不返回 `Succeeded`。
- [x] 新建/注入实际签发处理器，并按任务当前持久状态恢复各阶段；外部操作必须幂等并实现对账。（`SmallstepCertificateIssuer` + `TechnitiumDnsChallengeProvider` + `SshLinuxCertificateDeployer` 已在阶段 4/5 端到端验证；逐阶段恢复、挑战清理与账户订单对账见下方阶段 4 验证记录。）
- [x] 定义窄接口：`ICertificateIssuer`（ACME）、`IDnsChallengeProvider`（Technitium）、`ILinuxCertificateDeployer`（SSH）。
- [x] 建立租约续期和有界重试基础；每阶段超时、取消边界和失败阶段摘要由后续实际 Pipeline 处理器补齐。
- [x] 在真实外部适配器前提供仅用于开发/隔离环境的模拟实现，验证状态机编排。
- [x] 引入 outbox 或等效事务性事件模式，保证任务提交与异步工作通知不会丢失。（采用 LISTEN/NOTIFY 事务唤醒：`certificate_jobs` 持久行即队列/outbox 等价物，`TryAddAsync` 在 job 插入同事务内 `NOTIFY trustforge_job_submitted`、仅 commit 投递、回滚不发；worker 专用 `LISTEN` 连接即时唤醒，`NotificationEnabled` 默认开、轮询兜底，漏通知只损延迟不丢任务；重试靠轮询；无独立 outbox 表、无 schema 迁移。）

### 完成条件

- [x] Worker 重启/崩溃后租约过期可从 PostgreSQL 当前状态重新领取任务。
- [x] 多 Worker 通过 `SKIP LOCKED` 与每次领取的新 fencing token 防止同一任务被同时持有；外部阶段仍须幂等对账。
- 取消仅在激活前生效；激活后失败必须进入回滚流程。

## 阶段 4：Smallstep ACME 与 Technitium DNS-01

### 实施项

- [x] 配置 `step-ca` ACME directory、信任链、ACME account key 与（若启用）EAB secret 引用。
- [x] 实现 ACME new-order、授权挑战、finalize CSR、下载和验证证书链的客户端流程。
- [x] 实现 DNS-01：生成 TXT 值、通过 Technitium API 限定区域写入、等待权威校验后完成 ACME 授权，并清理挑战记录。
- [x] 对 DNS 记录变更执行最小权限授权、冲突检测、超时清理和审计。
- [x] 证书下载后校验 issuer、SAN、EKU/KeyUsage、算法和有效期是否符合服务模板。
- [x] 单独设计吊销操作的 CA 管理通道。（前提更正：step-ca v0.30.2 的 ACME provisioner **提供** RFC 8555 §7.6 的 `revokeCert`，ACME directory 已暴露该端点且默认启用；原计划「不提供吊销能力」的判断有误。实验室实测：以签发账户密钥签发 JWS 后 `POST /acme/acme/revoke-cert` 返回 200 且序列号进入 CRL，重复吊销返回 `alreadyRevoked`。授权面仅认「签发账户」（`isAccountAuthorized` 只比对 `dbCert.AccountID == account.ID`，持有全部 identifiers 授权的账户亦被拒，上游 issue #767），故 TrustForge 复用 `SmallstepAcme:AccountKeySecretRef` 指向的同一账户密钥，目标主机私钥无需参与、也永不离开目标主机。Admin API 无吊销端点；`step ca revoke` 走 JWK provisioner token 或 mTLS 且强制 `passive=true`，不适合作为服务侧通道。原因码 0–6、8、9 被接受（7 拒绝），故 `Unspecified` 亦可用。）

### 完成条件

- [x] 手动任务能经 ACME+DNS-01 得到与目标私钥对应的证书。
- [x] 挑战记录能在成功、失败和任务恢复路径中安全清理。
- [x] ACME account key、EAB 凭据和目标私钥互相隔离，均不进入普通日志/数据库字段。

## 阶段 5：SSH/SFTP Linux 部署与回滚

### 实施项

- [x] 固定 SSH 主机密钥指纹；提供连接测试和指纹变更阻断。
- [x] 实现 SSH 凭据引用解析、专用低权限账号、SFTP 暂存和连接超时。（偏差说明：暂存经 root-owned 助手的 stdin JSON 协议完成，未使用 SFTP——私钥始终在目标主机生成并保留，API 只传输 CSR 与公钥证书链。）
- [x] 编写 Linux root-owned `trustforge-certctl` 安装助手及版本化协议：生成密钥/CSR、校验 CSR、安装证书、原子切换、执行固定 reload/health check、回滚。
- [x] 助手仅接受服务 ID/任务 ID和受白名单限制的操作，不接受任意 shell 命令或任意路径。
- [x] 实现部署版本记录、文件权限核对、实际服务端证书指纹探测和失败告警。
- [x] 清理暂存与回滚槽位按保留策略执行，不得删除当前有效版本。

### 完成条件

- 私钥只在目标 Linux 主机生成并保留。
- SSH 指纹不匹配时不执行远程操作。
- 成功部署后服务实际呈现的证书指纹与证书库存匹配。
- reload/health check 失败时恢复旧版本；回滚失败时停止自动操作并告警、保留现场。

## 阶段 6：自动续期与生产运行准备

### 实施项

- [x] 为服务配置续期提前量和自动续期开关；调度扫描仅对进入窗口的服务创建任务。
- [x] 对同一服务施加数据库级并发保护，防止重复续期/部署。
- [x] 配置到期提醒、任务失败告警、审计导出、备份恢复演练和 CA 运维手册。
- [x] 准备 PostgreSQL 备份、升级迁移、密钥轮换、灾难恢复及监控指标文档。
- [x] 评估生产 HSM/KMS、step-ca 高可用和 TrustForge 多实例部署。

### 完成条件

- 自动续期按策略运行，不会在每次扫描时重复签发。
- 失败重试可恢复，服务继续使用旧证书直至新证书成功部署。
- 运维人员可依据文档恢复 PostgreSQL、CA 配置/密钥备份和服务证书部署状态。

## 当前下一步

阶段 4 已完成并在开发 ACME 实验室（`dev/acme-lab/`）通过端到端验证：真实 step-ca ACME + Technitium DNS-01 签发、成功/失败/恢复路径的挑战记录清理、密钥隔离、`AwaitingChallenge` 崩溃后的租约过期重领恢复演练，以及账户订单对账（日志确认复用）。协议与校验语义见 `CERTIFICATE-PIPELINE.md`，实验室用法见 `dev/acme-lab/README.md`。吊销 CA 管理通道仍未实现。

阶段 5 已完成并在开发 ACME 实验室通过端到端验证（`setup.sh` → `drill-deployment.sh` → `verify.sh`，38 项检查全过，2026-11-15）：部署版本记录（Staged/Active/Superseded/RolledBack/RollbackFailed + 健康状态与 verifiedAt）、终态失败同事务写入告警并经 webhook 投递（JobFailed/DeploymentRolledBack 为 Warning、RollbackFailed 为 Critical，均 Delivered 且有接收端回执）、verify 阶段文件权限核对（root:root 0600/0644）与服务端证书指纹探测、保留策略清理（保护 current 与回滚槽，保留最新 2 个 release，最旧 release 与任务密钥目录被清除）。回滚与回滚失败演练由健康失败标记触发。暂存经助手 stdin JSON 协议而非 SFTP（私钥不出目标主机）。实验室 step-ca 为补丁构建（修复上游 orderIDs 索引损坏，见 `dev/acme-lab/step-ca/Dockerfile`）。吊销 CA 管理通道仍未实现；阶段 3 的 outbox 项仍开放。

阶段 6 前两项（服务级续期开关/提前量 + 调度扫描、数据库级同服务并发保护）已完成并在开发 ACME 实验室通过端到端验证（`setup.sh` → `drill-deployment.sh` → `drill-renewal.sh` → `verify.sh`，49 项检查全过，2026-11-15）：`managed_services` 增加 `renewal_enabled`/`renewal_lead_time`，`deployment_versions` 记录 `certificate_not_after`；`RenewalSchedulerWorker` 周期扫描进入续期窗口（`certificate_not_after <= now + renewal_lead_time`）且无活动任务、且最近一个最小续期间隔内无续期任务的服务，按指纹幂等键 `renewal-{fingerprint}` 经协调器创建任务（演练用 25h 提前量 > 24h 证书寿命，使服务始终在窗口内，验证最小续期间隔 + 指纹幂等键防止每次扫描重复签发，实测仅生成 1 个续期任务并成功、supersede 引导版本）；`certificate_jobs` 部分唯一索引 `ux_certificate_jobs_active_service`（仅覆盖 9 个活动状态）施加同服务单活动任务保护，并发创建第二个任务实测返回 409 `service_job_active` 且未落库。迁移 `202611150002_RenewalAndActiveJobGuard`。注意 .NET `TimeSpan.TryParse("25:00:00")` 解析为 25 天而非 25 小时，提前量须用无歧义格式如 `1.01:00:00`。阶段 6 其余项（到期提醒/告警/审计/备份演练/CA 手册、PG 备份/迁移/轮换/DR/监控文档、HSM/KMS/HA 评估）留待后续；吊销 CA 管理通道与阶段 3 outbox 仍开放。

阶段 6 剩余三项已完成并在开发 ACME 实验室通过**全重置**端到端验证（reset → `setup.sh` → `drill-deployment.sh` → `drill-backup.sh` → `drill-restore.sh` → `drill-renewal.sh` → `verify.sh`，69 项检查全过、0 失败，2026-11-15）。备份/恢复排在续期之前，使续期服务在恢复后新注册，避开恢复后调度器竞争；verify 紧接续期在 2min 最小续期间隔内运行。交付物：

- **到期提醒**：新增 `ExpiryReminderWorker`（`CertificateJobs:Expiry`，`ScanInterval` 默认 1h、`ReminderWindow` 默认 7d），扫描活动证书进入提醒窗口者经 `ICertificateAlertStore.TryAddAsync` 写入 `CertificateExpiring`/Warning 告警，`JobId` 可空、按 `dedupeKey=expiring:{serviceId}:{fingerprint}` 部分唯一索引去重（每证书至多一条），独立于续期策略（`renewalEnabled=false` 也提醒）。`certificate_alerts.job_id` 改可空 + 新增 `dedupe_key`，迁移 `202611150003_ExpiryReminders`。lab 用 5s 扫描/7d 窗口使 24h 证书恒在窗口，实测 svc1 提醒 Delivered、跨多次扫描去重为 1 行、续期后 svc4 新指纹自有提醒、任务失败告警仍带 `jobId` 无 `dedupeKey`。
- **审计导出**：`GET /api/v1/audit/export`（CertificateReader 角色）返回 `{generatedAt,filters,jobs,deploymentVersions,alerts}`，字符串枚举，支持 `serviceId/from/to/limit` 过滤。实测含当前任务（transition 字符串态）、Active 版本、失败+到期两类告警、`serviceId` 过滤逐段生效、future `from` 为空、匿名 401。
- **备份恢复演练**：`drill-backup.sh`（`pg_dump -Fc` + CA/artifacts/dns-config 卷 tar + target 可写层 tar + secrets 副本 + manifest 行数/哈希）与 `drill-restore.sh`（`down -v` 后**先恢复卷再启动服务**——step-ca 空卷会重新初始化新 CA、target 用现有镜像绝不 `--build`、`pg_restore --no-owner --no-privileges --exit-on-error`），断言行数==manifest 并新发 svc1 任务证明 CA 密钥恢复。实测恢复后 managed_services/certificate_jobs/deployment_versions = 3/6/5 行匹配、新任务 Succeeded、备份任务存活。
- **文档**：`OPERATIONS.md`（状态布局、CA 运维含 orderIDs 补丁与先恢复再启动、root/中间证书轮换 vs ACME account-key 轮换、PG 备份/PITR/恢复 runbook/升级迁移/编写约定、密钥轮换表、DR 故障域表与手动 runbook、监控含 health/告警表/dashboard SQL/审计导出）、`HSM-KMS-HA-EVALUATION.md`（step-ca PKCS#11/`kms:` 与 root 离线、`ISecretResolver` 接缝接 Vault/KMS、step-ca badger 单写者→active/passive 或 SQL 后端且 orderIDs 补丁 nosql 专属须重验、多实例安全部分 SKIP LOCKED/fencing/唯一索引/幂等 vs 阻塞项内嵌 DNS/本地 artifacts/并发 `--migrate`、采用矩阵）；同步更新 `TrustForge.Api/README.md`、`dev/acme-lab/README.md`、`CERTIFICATE-PIPELINE.md`、`DEPLOYMENT.md`。

阶段 6 三项完成条件均成立：自动续期按策略运行不重复签发；失败重试可恢复、服务沿用旧证书直至新证书成功部署；运维人员可依文档恢复 PostgreSQL、CA 配置/密钥备份和服务证书部署状态。Phase 1「补充并演练 PostgreSQL 备份和恢复操作」已勾选。仍开放：吊销 CA 管理通道、Phase 1「在已有生产数据的数据库上验证后续 migration 升级策略」（本轮恢复的是已含全部迁移的 dump，`--migrate` 为 no-op，未跑真正旧→新升级变体）、DNS 统一登录/入口。

阶段 3 outbox 项已完成并在开发 ACME 实验室通过端到端验证（2026-11-15）。勘察确认原系统**无丢失通知缺口**：worker 纯轮询持久化 `certificate_jobs` 行（`FOR UPDATE SKIP LOCKED` + 租约过期重领），job 行即持久队列、处理已是 at-least-once，告警已是「同事务写入 + 轮询投递」的 outbox 雏形。按用户选定采用 **LISTEN/NOTIFY 事务唤醒**（非独立 outbox 表）：`PostgresCertificateJobStore.TryAddAsync` 在 job 插入的同一事务内 `NOTIFY trustforge_job_submitted`（仅 commit 投递、冲突回滚不发），worker 经 `IJobSubmissionChannel`/`PostgresJobSubmissionChannel` 专用 `LISTEN` 连接（`Pooling=false`、`ApplicationName=trustforge-job-listener`、断线 ~2s 冷却重连）即时唤醒；`CertificateJobs:Worker:NotificationEnabled` 默认 true（Compose `TRUSTFORGE_WORKER_NOTIFICATION_ENABLED`），关闭则纯轮询；首轮先 claim 覆盖启动窗口，错误分支保留退避，租约/心跳/重试不动。NOTIFY 是延迟提示、durable 行是唯一真相源，漏通知（重启/重连/启动窗口/DB 宕机）只损延迟不丢任务；重试（`next_attempt_at`）靠轮询；多实例 NOTIFY 广播 + SKIP LOCKED + 每次新 fencing token 保证不重复处理；Npgsql 忙碌时缓冲通知→claim 间不漏唤醒。无模型变化、无新迁移，构建 0 警告。新增 `dev/acme-lab/drill-notification.sh` **相位锚定 A/B** 实证（锚任务终态→worker 进入完整 30s 等待→sleep 2→建 B 测延迟，避开轮询相位运气）：控制相（NotificationEnabled=false）B=30s（轮询界 ≥20）vs 通知相（true）B=4s（NOTIFY 唤醒 <12）+ `pg_stat_activity` listener present，结论性证明事务唤醒生效且轮询兜底。全重置链路（reset→setup→deployment→backup→restore→**notification**→renewal→verify）`verify.sh` **72 项全过、0 失败**（69 基础 + 3 通知段；notification 置于 renewal→verify 之前，既守住 ≤2min 续期窗口又使 verify 行使通知段）。文档同步：`CERTIFICATE-PIPELINE.md` 新增「Job submission and transactional wake」、`TrustForge.Api/README.md` worker 段、`OPERATIONS.md` 6.3 listener SQL / 6.5 事务唤醒 / §7 链路、`dev/acme-lab/README.md` 通知演练节、`DEPLOYMENT.md` worker 唤醒说明。仍开放：吊销 CA 管理通道、Phase 1 旧→新 migration 升级变体、DNS 统一登录/入口。

阶段 1 末项「在已有生产数据的数据库上验证后续 migration 升级策略」已完成并在开发 ACME 实验室通过端到端验证（2026-11-15，详见阶段 1 升级策略验证记录）：新增 `drill-migration.sh` 真实 old→new 增量升级演练（baseline 播种生产样数据 → 产品 `--migrate` 增量升级 → 数据保全 / 新列默认值 / 新索引约束 / 幂等重跑 / 新形态写入 / 脏数据 `23505` 拒绝 + 每迁移回滚），用独立可弃侧库 + 一次性容器，置于 notification 之后、renewal→verify 之前（不 recreate app、不碰主库 / Keycloak netns / 续期窗口）。全重置链路 `verify.sh` **79 项全过、0 失败**（72 基础 + 7 迁移段），migrationDrill 段行使。文档同步：`dev/acme-lab/README.md`（usage + Migration upgrade drill 节 + host dotnet/ef 要求 + 顺序）、`OPERATIONS.md`（§3.3 指向演练 + §7 链路）。仍开放：吊销 CA 管理通道、DNS 统一登录/入口。

阶段「吊销 CA 管理通道」已完成并在开发 ACME 实验室通过端到端验证（2026-11-23）。通道实现为 `ICertificateRevocationChannel` → `SmallstepCertificateRevoker`：以 `SmallstepAcme:AccountKeySecretRef` 指向的**签发账户密钥**对 RFC 8555 §7.6 `revokeCert` 签名（step-ca 仅认签发账户，目标主机私钥不参与也永不离开目标主机），`revokeCert` URL 从 ACME directory 读取而非拼路径，`alreadyRevoked` 视为成功使重放收敛，单次 `badNonce` 重试，Content-Type 必须为裸 `application/jose+json`（带 charset 参数被 step-ca 拒）。端点 `POST /api/v1/services/{id}/revocations` 受 `CertificateRevoker` 策略（仅 `PlatformAdmin`，刻意窄于签发所需的 `CertificateOperator`）保护并强制 `Idempotency-Key`；读取与审计导出仍为 `CertificateReader`。持久化为迁移 `20261123125511_CertificateRevocations`：`certificate_revocations` 表 + `ux_certificate_revocations_live_serial`（部分唯一 `state <> 'Failed'`，同序列仅一条活记录）+ `ux_certificate_revocations_idempotency` + `ix_certificate_revocations_due` + 两条 FK；CA 成功与 `CertificateRevoked` 审计告警同事务提交，失败退避 `min(300, 2^attempt)` 交 `RevocationRetryWorker`（`FOR UPDATE SKIP LOCKED` + 可见性超时 + `attempt_count` 乐观并发），超 `MaxAttempts=5` 转 `Failed` 并提 Critical `RevocationFailed`。实验室按要求启用 step-ca CRL 分发（`ca.json` `crl` 块，setup.sh 幂等启用并重启 CA）。新增 `drill-revocation.sh` 八段演练实测：CRL 前置（含 issuing distribution point）、RBAC（匿名 401 / CertificateOperator 403 但读取 200 且仍可签发 202）、请求校验与冲突（缺幂等键与非法原因 400、无活动证书 409 `no_active_certificate`）、真实 ACME 吊销（200 `revoked`、记录 CA 侧序列号即剥离 DER `00` 符号填充）、CRL 实测列出该序列且原因 `Key Compromise`、审计告警 Critical/Warning 并经 webhook 投递回执、幂等重放（同键与不同键均返回同一条记录、CA 每序列仅请求一次）、CA 宕机时 durable（202 `pending` + `Pending` 行 → 恢复后 worker 完成为 `Revoked`、单行、`lastError` 清空、无放弃告警）、无附带损害（其他服务序列不在 CRL、审计导出 `revocations` 段按 serviceId 收敛）。本轮发现并修复两个真实缺陷：① `Program.cs` 的回读守卫把 409 冲突结果（`no_active_certificate` / `service_job_active` / `certificate_material_missing` / `fingerprint_mismatch`）也当作必须带记录，导致本应 409 的路径返回 500；② `SmallstepCertificateRevoker` 预序列化 payload 使 Certes 二次编码，step-ca 返回 500 `cannot unmarshal string into Go value of type api.revokePayload`，改为传对象由 Certes 自行序列化。更正两处错误前提：`TRUSTFORGE-ARCHITECTURE.md` 原「step-ca 的 ACME Provisioner 不提供吊销能力」不成立；原「最小续期间隔防止续期循环」不成立——提前量 ≥ 证书寿命时服务永久处于续期窗口，调度器会持续签发、每 `MinimumRenewalInterval` 一次，最小间隔只限流不防止（正确做法是提前量严格小于证书寿命），并新记录 API 内联尝试与 `RevocationRetryWorker` 对新 `Pending` 行（`next_attempt_at IS NULL` 即刻可领）竞争的良性语义。实验室脚本另修三处：Git Bash 在 `MSYS_NO_PATHCONV=1` 下把 `-o /dev/null` 原样交给原生 curl 导致退出 23，改用 `http_code()` 管道丢弃响应体；`drill-migration.sh` 硬编码「7 条迁移历史」在新增吊销迁移后自毁，改为从生成的脚本推导期望总数并补吊销 schema 升级断言；`verify.sh` 原假定最后一条演练任务仍持有共享 `/etc/trustforge-demo/current`，而续期服务 2 分钟后即接管该路径（实测误报 3 项），改为从 `releases/<service>/<job>` 解析归属任务并按其断言。全重置链路（down -v → setup → deployment → backup → restore → notification → migration → renewal → **revocation** → verify）各步 `STEP_OK`，`verify.sh` **111 项全过、0 失败、0 跳过**（吊销段 29 项），退出码 0；`dotnet build TrustForge.Api` 0 警告 0 错误。文档同步：`CERTIFICATE-PIPELINE.md` 新增「Revocation and CRL distribution」与续期/内联- worker 竞争更正、`OPERATIONS.md` §2.6 + 6.2 告警表 + 6.3 吊销看板 SQL + 6.4 审计包含 `revocations` + §7 链路、`dev/acme-lab/README.md` 吊销演练节与顺序/Notes、`TrustForge.Api/README.md` 端点与 worker 段、`TRUSTFORGE-ARCHITECTURE.md` 前提更正、阶段清单末项补齐。仍开放：DNS 统一登录/入口。
