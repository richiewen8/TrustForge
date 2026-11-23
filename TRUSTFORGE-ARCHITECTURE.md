# TrustForge：统一信任基础设施平台

## 愿景

TrustForge 以 Technitium DNS Server 为 DNS 基座，逐步建设面向企业内部的统一信任基础设施平台。平台把内部 PKI、证书颁发与生命周期、DNS/DNSSEC、服务身份和自动化工作流放在同一个管理与审计平面中，让服务和团队能以可追踪、可自动化的方式获得并维护信任材料。

核心结果：

- 统一管理组织、环境、域名、CA、证书、密钥策略和自动化任务。
- 通过 ACME、EST、SCEP 及平台 API 适配常见工作负载和设备（按阶段实现）。
- 将证书状态与 DNS 联系起来，支持 DNS-01 验证、TLSA/DANE 发布和到期治理。
- 所有敏感操作均有身份校验、最小权限、审计记录和可操作的生命周期状态。

## 产品原则与边界

1. **DNS 核心保持 DNS 职责，产品统一部署。** TrustForge 的 PKI 与生命周期逻辑保持独立模块；Technitium DNS 作为同一 TrustForge Linux 宿主进程中的内部能力运行，通过受控适配器集成。
2. **私钥优先留在密钥边界内。** CA 签名密钥应由 HSM/KMS 或隔离的签名服务托管；Web/API 只提交经过授权的签名请求。开发环境可提供明确标注的本地测试后端。
3. **先建立可审计的 CA 生命周期。** 创建 CA、签发、续期、吊销、CRL/OCSP 和备份恢复应有明确状态、权限和审计事件。
4. **标准协议优先，适配器解耦。** ACME 等协议端点调用内部签发策略，不直接绕过策略或密钥边界。
5. **分阶段交付。** 先做单组织、单实例可用的控制面，再扩展高可用、集群和多租户能力。

## 目标架构

```text
管理员 / 服务工作负载 / CI-CD
              │
       Web 控制台与 API
              │
 ┌────────────┼─────────────────────────┐
 │ TrustForge 控制平面                  │
 │ 身份/RBAC │ 策略 │ 工作流 │ 审计 │ 通知 │
 └──────┬──────────┬──────────┬─────────┘
        │          │          │
   PKI/签发服务  生命周期编排  协议与集成适配器
        │          │       ACME / DNS-01 / KMS-HSM
   签名边界       │
        └──────┬───┘
               │ 受控 API/插件集成
      Technitium DNS Server
      Zones / DNSSEC / TSLA-DANE / Cluster
```

建议的逻辑域：

- **TrustForge Core**：租户/组织、身份映射、RBAC、策略、审计、任务状态和 API。
- **PKI**：根/中间 CA 生命周期、证书模板、签发、续期、吊销、CRL/OCSP 元数据。
- **Key Provider**：抽象 HSM/KMS/隔离签名服务；应用数据库不得保存 CA 私钥明文。
- **Certificate Lifecycle**：资产发现与登记、到期提醒、续期编排、部署结果回报。
- **DNS Integration**：Technitium API 适配、DNS-01 挑战记录、TLSA 发布与回滚、DNSSEC 状态检查。
- **Protocol Gateways**：分阶段提供 ACME、EST、SCEP 及 Kubernetes/云/代理等集成。
- **Web Console**：统一呈现 CA、证书、DNS 验证、任务、策略和审计。

## 与 Technitium 的集成策略

- TrustForge 是唯一产品、解决方案入口和应用部署镜像；PostgreSQL 以 Compose 依赖服务运行。开发打开根目录 `TrustForge.sln`，部署使用根目录 `docker-compose.yml`。
- API 和 DNS 引擎当前在同一进程中，但 API（OIDC/RBAC）与 DNS 管理控制台仍是两个 HTTP 入口；DNS 控制台保留 Technitium 自身认证，统一登录和导航尚未实现。

- 保留其权威/递归 DNS、区域、DNSSEC、集群和现有管理能力，TrustForge 通过受版本管理的 API/适配器调用。
- DNS-01 使用具备作用域限制的凭据，仅允许管理专用验证区域/记录；验证结束后清理挑战记录，并记录结果。
- TLSA 发布采取“生成候选记录—验证证书/参数—应用—检查传播—可回滚”的流程。
- 避免把 CA 私钥或 PKI 数据模型加入 DNS 服务器存储；把 DNS 服务器作为平台管理的一个信任基础设施组件。
- 若未来需要同一控制台体验，可采用插件/导航集成；插件仅是 UX/API 桥接层，核心策略仍归 TrustForge 服务。

## 初始版本范围（MVP）

### 平台范围

- TrustForge 签发/调度服务和首批受管服务均运行在 Linux；首版不支持 Windows 服务端、Windows 证书存储或 IIS 部署。
- 首版部署目标限定为 Linux 主机上的 PEM 证书/私钥/证书链文件，以及受控的服务重载或重启命令。
- 每个受管服务登记 Linux 主机连接配置引用、证书文件路径、私钥文件路径、权限/属主策略、服务重载动作和健康检查；凭据存入秘密管理后端，不在普通配置或审计日志中明文保存。
- 优先让私钥在目标 Linux 主机本地生成，TrustForge 通过 CSR 完成签发并将证书链部署回目标。首版远程连接统一使用 SSH；不引入 Linux Agent。
- SSH 连接必须校验并固定目标主机密钥，使用专用低权限账号及密钥认证；私钥凭据只保存为秘密管理后端中的引用。远程命令和可写路径采用受限白名单，禁止把用户输入拼接为任意 Shell 命令，并记录连接目标、任务、命令类别和执行结果。

### 必须具备

- 单组织、单 TrustForge 控制平面；管理员登录、RBAC 和结构化审计。
- CA 采用显式初始化与手动签发：管理员首次初始化根 CA（自签根证书），再由上级 CA 签发中间/签发 CA 证书；CA 证书更新或轮换必须是单独、可审计的管理操作，不由普通服务器证书定时任务处理。
- 支持可配置密钥提供方，默认开发密钥后端不得用于生产。
- 证书模板/配置文件，具备 SAN、用途、有效期和算法约束。
- Linux 服务证书支持手动签发，以及按登记的服务配置运行定时续期/签发；服务可登记受控 PEM 文件路径和服务重载/健康检查动作。
- 人工审批式签发、续期、吊销；证书清单、搜索、到期视图和导出。
- Technitium DNS 连接配置、连通性检查、限定区域的 DNS-01 自动化。
- 基础通知、任务记录、配置备份与恢复演练文档。

### 暂不纳入首版

- 公有云多账户编排、自动资产发现、多租户 SaaS、跨区域高可用。
- 默认自动签发所有工作负载；先有策略与审计，再开放自动批准。
- 自研 HSM、复杂的通用工作流编辑器，以及替代 Technitium 的 DNS 实现。

## 分阶段路线

### 阶段 0：基线与边界

- 固定 Technitium 上游版本、许可证与升级/补丁策略。
- 确定 TrustForge 与 DNS Server 的部署拓扑、身份来源、数据存储和密钥后端接口。
- 建立威胁模型：CA 私钥泄露、越权签发、DNS 挑战滥用、审计篡改、备份泄露。

### 阶段 1：可审计的内部 CA

- TrustForge Core、RBAC、审计、CA 初始化、首次手动签发/导入上级签发的 CA 证书、模板、人工审批签发/吊销。
- 只接入开发/隔离签名后端，定义生产 HSM/KMS 接口和运维流程。

### 阶段 2：DNS 与自动化

- Technitium DNS 适配器、DNS-01、证书到期状态、按服务配置运行的定时续期任务与通知。
- 可选 TLSA 发布、DNSSEC 检查及变更回滚。

### 阶段 3：工作负载接入

- ACME 优先，其后按目标环境加入 EST/SCEP、Kubernetes 与代理/负载均衡器集成。
- 策略化自动续期、部署确认和失败重试。

### 阶段 4：生产韧性

- HSM/KMS 生产后端、高可用/灾备、恢复演练、审计导出与安全运营集成。
- 在权限隔离、容量、恢复和升级验证通过后，评估组织/租户隔离扩展。

## 首批领域对象

`Organization`、`Principal`、`RoleBinding`、`CertificateAuthority`、`KeyReference`、`CertificateProfile`、`CertificateRequest`、`Certificate`、`ManagedService`、`CertificateDeploymentTarget`、`RenewalPolicy`、`Revocation`、`DnsProviderConnection`、`AutomationJob`、`AuditEvent`。

证书记录应保留签发者、序列号、指纹、SAN、有效期、状态、用途、关联请求、密钥引用（如有）和部署/发布结果；不得把工作负载私钥作为默认可下载资产。

## 服务证书签发与续期流程

### 首次建立信任链

1. 管理员初始化根 CA，并确认 CA 名称、算法、有效期、密钥提供方和备份/恢复信息。
2. 如采用离线根 CA，由根 CA 离线签发中间 CA CSR；管理员将中间 CA 证书导入 TrustForge 并完成链校验。首版允许受控的手动操作。
3. 只有已启用且通过策略检查的签发 CA 才能为服务器服务签发证书。

### 登记服务器服务

每个 `ManagedService` 至少配置服务名称、环境/责任人、Linux 目标主机、经校验的 SSH 主机密钥指纹、专用 SSH 账号及秘密凭据引用、证书模板、DNS 名称/SAN、签发 CA、续期提前量、PEM 证书/链/私钥目标路径、文件属主与权限、服务重载动作和健康检查方式。部署目标是受控配置，不是任意远程路径写入：连接器应限制允许的主机、命令和路径，秘密凭据不得进入普通配置或日志，并记录证书交付与服务操作审计。

### 手动签发

管理员在服务详情选择“签发/续期”，TrustForge 校验身份权限、模板、SAN、目标和 CA 状态；首选在目标 Linux 主机生成私钥和 CSR，TrustForge 将 CSR 提交 CA 签发，再将证书链部署到登记的 PEM 路径。部署采用临时文件、权限设置和原子切换，并执行登记的服务重载与健康检查。操作结果（成功或失败）、证书序列号/指纹、部署版本和操作者写入审计及任务记录。手动操作可选择常规签发或经权限控制的强制轮换。

### 定时续期

后台调度器按服务的续期策略周期扫描证书。仅当证书进入续期窗口、服务启用自动续期且策略检查通过时才创建续期任务；调度扫描本身不得重复签发。任务使用幂等键和锁防止并发重复，在目标 Linux 主机生成新 CSR、签发新证书、暂存 PEM 文件、设置权限并验证，再原子切换证书、运行服务重载和健康检查；成功后标记新证书生效并保留旧文件/部署版本以支持回滚。失败时保留当前服务证书，记录失败阶段并按退避策略重试、通知责任人。

手动签发和定时续期共享同一策略校验、签发、部署和审计流程。到期提醒与续期失败告警独立于签发任务，CA 证书生命周期使用单独的提醒和人工维护流程。

## 技术决策建议

- 先沿用仓库现有 .NET 技术栈，TrustForge 后端与 DNS Server 通过清晰项目边界隔离；控制台可先采用现有 Web 技术栈。
- **持久化数据库采用 PostgreSQL。** TrustForge 的服务、CA/证书元数据、任务状态/历史、审计与配置引用使用 PostgreSQL 持久化；通过迁移管理 schema，不以 SQLite 作为首版或临时生产存储。
- 建议采用 Npgsql + EF Core migrations；状态迁移、幂等键唯一约束和乐观并发更新必须由数据库事务/约束保证。Worker 领取任务使用数据库可恢复的租约/锁，避免进程重启后丢失任务或多 Worker 重复执行。
- **CA 签发采用 Smallstep `step-ca` + 标准 ACME。** TrustForge 实现 ACME 客户端/编排适配器，不依赖 `step-ca` 私有签发接口；证书签发、续期等尽量沿用协议标准和互操作生态。
- 内网 DNS 名称首选 ACME DNS-01：TrustForge 通过最小权限 Technitium DNS 适配器创建、验证并清理 `_acme-challenge` TXT 记录；HTTP-01 等挑战类型可作为后续按网络条件增加的适配器。
- CA ACME 端点、ACME 账户凭据/密钥、EAB 凭据（若部署策略要求）均通过秘密管理后端引用；ACME 账户密钥与目标服务私钥分离。（前提更正：原文「step-ca 的 ACME Provisioner 不提供吊销能力」不成立。step-ca v0.30.2 的 ACME directory 已暴露并默认启用 RFC 8555 §7.6 `revokeCert`，实验室以签发账户密钥实测吊销成功且序列号进入 CRL。授权面仅认「签发账户」，故吊销通道复用 `SmallstepAcme:AccountKeySecretRef` 指向的同一账户密钥，目标主机私钥无需参与、也永不离开目标主机；Admin API 无吊销端点，`step ca revoke` 需 JWK provisioner token 或 mTLS，不适合作为服务侧通道。因此「单独的受控 CA 管理通道」即为 ACME 账户密钥通道，详见 `CERTIFICATE-PIPELINE.md`「Revocation and CRL distribution」。）
- 为 DNS 操作实现独立适配器接口，避免业务代码依赖 Technitium 内部实现细节。
- CA 签名抽象提供 `Sign`、`GetPublicCertificate`、`GetCapabilities` 等窄接口，密钥引用与密码学操作分离。
- 所有签发与 DNS 变更采用可追踪任务 ID、幂等键、结构化结果和审计事件。
- 通过版本化 API、数据库迁移和配置格式保证升级可控；先评估上游同步机制再大规模修改 DNS 核心。

## 首轮实施待办

1. 记录上游 Technitium 版本、分支/补丁策略和部署形态。
2. 明确目标环境（纯内网/混合云）、身份源、首个签发对象和 DNS 管理范围。
3. 建立 TrustForge 服务/模块骨架及 API 版本约定。
4. 设计 CA/证书状态机、RBAC 矩阵、审计事件和密钥提供方契约。
5. 定义 Technitium API 适配契约与最小权限 DNS-01 流程。
6. 以威胁模型和运维恢复方案评审 MVP，再进入签发功能实现。

## MVP 实现规格：单台 Linux 服务证书手动签发与部署

### 目标与范围

交付一条可端到端运行的流程：管理员在 TrustForge 登记一台 Linux 测试主机和一个服务，手动触发证书签发；服务端本机生成并保管私钥，TrustForge 作为 ACME 客户端向 Smallstep `step-ca` 创建订单，通过 Technitium DNS 完成 DNS-01 验证并获取证书，再通过 SSH/SFTP 部署证书链，执行受控的服务重载与健康检查；部署失败时恢复之前的证书版本。首版只支持一个已配置的 CA/ACME 账户、证书模板及 PEM 文件目标，不实现定时调度、公有云、Windows、通用远程 Shell 或多主机编排。

### 参与组件

- **TrustForge API/Worker**：身份授权、参数校验、任务状态机、CSR 签发、审计与通知。
- **CA 签名提供方**：接收 CSR 与证书配置并返回签发证书；CA 私钥不离开签名边界。
- **SSH Connector**：校验主机密钥，使用秘密管理后端提供的 SSH 凭据，通过 SSH/SFTP 执行限定操作和传输文件。
- **Linux 目标主机**：运行 OpenSSH、OpenSSL，以及 root 所有、不可由服务账号修改的 TrustForge 安装助手；服务私钥在此生成。
- **目标服务**：使用配置的证书路径，并提供受控的重载和健康检查方式。

### Linux 主机前置配置

- 创建专用 `trustforge` 系统账号，通过 SSH 公钥认证登录，禁止密码登录、交互式 Shell、端口转发、Agent 转发和伪终端；固定并预先登记 SSH 主机公钥指纹。
- 安装 TrustForge root 所有、不可由 `trustforge` 用户修改的安装助手，例如 `/usr/local/sbin/trustforge-certctl`。SSH Connector 只允许调用该助手的固定子命令，不允许接受任意命令、Shell 片段或 sudo 参数。
- 安装助手需校验服务 ID 与预先配置的证书路径白名单；创建私钥/CSR、设置文件属主和权限、执行原子切换/回滚，并只执行预先登记的服务 reload 与 health-check 配置。
- 私钥建议权限 `0600`，证书/链权限按目标服务读取需求设置；私钥不通过 SFTP 传回 TrustForge，不进入日志、数据库或审计事件。
- 上线前以目标服务账号验证证书文件可读、私钥与证书匹配，并确保 SSH 账号不能借助手配置执行白名单外操作。

### 手动签发与部署时序

1. 管理员创建 `ManagedService`，填写主机地址/端口、SSH 主机密钥指纹、凭据引用、服务名称、证书模板、SAN、证书/链/私钥路径、属主/权限、安装助手标识、reload 与健康检查配置；敏感凭据只存秘密管理系统。
2. 管理员点击“签发并部署”。API 校验 RBAC、服务启用状态、CA/ACME 账户/模板状态、SAN 约束、续期/有效期策略、目标路径和 SSH 配置，然后创建唯一 `CertificateJob` 与审计事件并返回任务 ID。
3. Worker 取得该服务的互斥锁，任务进入 `Connecting`。连接前核对已登记的主机密钥指纹；任何变化均中止并要求管理员更新信任配置。
4. Worker 请求安装助手为本次任务生成密钥和 CSR。私钥在目标机受限临时目录生成，权限立即设为 `0600`；CSR 经 SFTP 取回并在服务端校验公钥算法、SAN 与服务申请完全一致。私钥不得离开目标机。
5. Worker 使用 TrustForge 管理的 ACME 账户向 `step-ca` 创建订单，校验订单标识符与已批准 SAN 完全相符；按 DNS-01 授权流程通过 Technitium 创建 `_acme-challenge` TXT 记录，等待 ACME authorization 有效。Worker 使用 CSR 完成 ACME order finalize，下载证书并校验链、SAN、EKU/KeyUsage、有效期和模板约束；生成仅含证书及中间链的部署包。挑战记录在成功或失败清理流程中移除，并记录 DNS 变更审计。
6. Worker 通过 SFTP 将证书链写入安装助手管理的任务暂存区。助手验证任务 ID、文件摘要、证书与目标私钥匹配、证书链及目标路径白名单；保留当前部署版本，准备新的证书文件并设置属主/权限。
7. 安装助手将新证书文件原子切换到生效路径，执行固定的服务重载动作。Worker/助手运行健康检查（命令退出状态及可配置 TLS 探测），确认实际服务端证书指纹与本次签发证书一致。
8. 检查通过后任务进入 `Succeeded`，新证书关联服务并设为当前部署；旧证书仍保留在库存和受限回滚槽位，审计记录保存其版本引用。按保留策略清理过期暂存数据，但不得清理当前版本和回滚版本。
9. 任一步失败时记录失败阶段和安全的错误摘要。若已经切换文件，安装助手恢复上一版本并重新加载服务，再验证旧证书健康；任务进入 `FailedRolledBack`。如果回滚或验证也失败，进入 `RollbackFailed` 并立即告警，保留现场文件和日志供管理员处理，不继续自动破坏性重试。
10. Worker 在任务结束时释放互斥锁；崩溃恢复时根据持久化阶段和远端任务标记进行对账，禁止盲目重复签发或切换。任务重试必须由管理员显式发起新任务，或经幂等检查确认原阶段可安全重入。

### 任务状态

`Queued` → `Connecting` → `GeneratingCsr` → `CreatingOrder` → `AwaitingChallenge` → `Signing`（ACME order finalize/下载）→ `Staging` → `Activating` → `Verifying` → `Succeeded`。

失败终态：`Failed`（尚未改变线上部署）、`FailedRolledBack`（已切换后成功回滚）、`RollbackFailed`（回滚/回滚后验证失败）、`Cancelled`（仅允许在激活前取消）。每次状态变更记录任务 ID、服务 ID、操作者/触发来源、时间、证书序列号/指纹（签发后）、阶段和脱敏错误摘要。禁止记录私钥、SSH 私钥、秘密值或完整环境变量。

### 数据/API 草案

- `ManagedService`：`id`、`name`、`enabled`、`host`、`port`、`hostKeyFingerprint`、`sshCredentialRef`、`profileId`、`sans`、`keyAlgorithm`、`certificatePath`、`chainPath`、`privateKeyPath`、`owner/group/mode`、`remoteHelperId`、`reloadActionId`、`healthCheckId`、`currentCertificateId`。
- `CertificateJob`：`id`、`serviceId`、`requestedBy`、`trigger`（`Manual`）、`state`、`idempotencyKey`、`certificateId`、`startedAt`、`finishedAt`、`failureStage`、`failureSummary`、`rollbackState`。
- `DeploymentVersion`：`id`、`serviceId`、`certificateId`、`fingerprint`、远端版本槽位、部署时间、健康状态；不得包含私钥内容。
- API 建议：`POST /api/v1/services`、`GET /api/v1/services/{id}`、`POST /api/v1/services/{id}/certificate-jobs`、`GET /api/v1/certificate-jobs/{id}`、`POST /api/v1/certificate-jobs/{id}/cancel`（仅激活前）。所有写请求鉴权并写审计；签发部署采用异步任务响应。

### 首版权限

- `PlatformAdmin`：管理 SSH 连接器、秘密引用、CA 与模板。
- `CertificateOperator`：登记/修改服务并发起手动签发部署。
- `Auditor`：只读查看服务、证书、任务和审计。
- Worker 使用独立服务身份，只能读取目标服务引用的凭据、按服务策略申请签发，并在登记主机上调用受限助手。

### 验收条件

1. 未登记或指纹不匹配的 SSH 主机无法执行任何远程操作。
2. 证书 SAN、算法、有效期不符合模板时，在部署前拒绝签发或拒绝继续部署，并留下可审计原因。
3. 服务私钥只在目标 Linux 主机生成，权限符合配置；TrustForge 数据库、日志和审计中均不出现私钥或 SSH 凭据。
4. 手动任务可从 UI/API 跟踪到终态，且重复提交/Worker 重启不会造成并发重复部署。
5. 成功时服务实际呈现的新证书指纹与任务证书一致，原子切换期间不会出现半写入文件。
6. 在重载失败、健康检查失败、SSH 中断等场景中，系统按切换阶段正确保留旧证书或执行回滚；回滚失败会告警并保留现场。
7. SSH 账号不能执行白名单之外的命令或写入登记路径之外的位置；所有签发、部署、回滚操作有操作者、目标和结果审计。

### 建议实现顺序

1. 实现实体、状态机、RBAC、审计和异步任务持久化（先用模拟 SSH/CA 适配器贯通流程）。
2. 实现 CA CSR 签发适配器及证书链校验。
3. 实现 SSH 主机密钥校验、秘密凭据引用、SFTP 和受限安装助手协议。
4. 实现 Linux 安装助手：生成密钥/CSR、暂存、权限设置、原子激活、健康检查和回滚。
5. 增加单台隔离 Linux 测试机的端到端验收，再开放管理员手动操作。

