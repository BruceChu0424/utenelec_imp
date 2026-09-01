# 内部 ERP 测试服务器运行基线

> ⚠️ **已随 ADR-060 退役（2026-09-01）**：本文属旧发布链/旧部署链文档，按 [ADR-060](../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 保留作未来引入第二维护者时的参考，不再具有操作效力。现役链见 [deploy/simple/RUNBOOK.zh-CN.md](../simple/RUNBOOK.zh-CN.md)。

> 范围：公司内网中的 PostgreSQL、Spring Boot ERP 后端、Flutter ERP Web 和 Nginx。
> 企业官网、云端 ERP、正式业务数据和公网入口均不属于本配置。
> **证据边界（2026-08-15）：** 本文定义的是当前源码候选的目标合同。它尚未形成受审提交、CI 签名
> 发布、OSS 回读或目标机安装/验收证据；最近一次服务器事实仍是 2026-08-12 的旧快照，当前禁止据此
> 照抄任何写入、enable/start 或 reboot 命令。

## 1. 结论

当前目标合同要求物理服务器使用独立 `internal-test` Spring profile，不再把 `prod` profile 改成本地磁盘模式。
这样可以同时满足两条互不冲突的规则：

- `prod/cloud` 继续由 `ProductionStorageSafetyGate` 强制使用版本化 OSS，不能被测试服务器配置放宽；
- `internal-test` 只允许 NVMe 上固定的 `/data/uten-imp/attachments`，并保留生产级回环监听、
  HTTPS/CORS、独立迁移、密钥 fail-fast 和 Swagger 关闭边界。

`internal-test` 必须是唯一 active profile。与 `dev`、`prod`、`cloud` 或其他 profile 组合时，应用拒绝启动。

## 2. 固定安全契约

| 项目 | 内部测试服务器固定值 |
|---|---|
| 后端监听 | `127.0.0.1:8080`，员工只能经过同机 Nginx |
| 员工入口 | 内部 DNS 名称 + 受终端信任的 HTTPS 证书；不使用裸 IP |
| 数据库 | 本机回环 PostgreSQL；运行账号没有 Flyway 权限 |
| Flyway | 后端固定关闭，只允许独立 migration-only 流程 |
| Swagger/OpenAPI | 应用与 Nginx 双重关闭 |
| 密钥 | 数据库、JWT、PGP、HMAC 均须由 root 管理并在缺失/过短时拒绝启动 |
| 附件后端 | 仅 `local`，固定 `/data/uten-imp/attachments` |
| 附件上传 | 默认且当前强制关闭；已有最终对象仍可读取 |
| 外联 | systemd 仅允许本机网络，短信、政策 API、OSS、旧库和官网 ingest 均关闭 |
| 企业官网 | Nginx 只拒绝官网外部 `ingest`；员工询盘管理保留；官网以后部署到独立云服务器 |

### 2.1 ERP 主机的 API 路由边界

Spring `WebsiteInquiryController` 当前有 6 条映射。内部 ERP 主机不承载官网推送，所以 Nginx 只用
前置正则 location 关闭外部 `POST ingest` 及其尾斜杠、父/子段矩阵参数和子路径变体。
员工使用的列表、未处理数量、详情、状态更新和转客户仍进入通用 `/api/` 代理，并继续由 Spring 的
`webinquiry:view`、`webinquiry:manage` 权限控制。不能关闭整个询盘命名空间，否则会误伤员工操作。

附件上传是 `presign -> raw PUT -> confirm` 三阶段协议。当前上传关闭，因此 Nginx 分别保留并拒绝
`/api/attachments/presign`、`/api/attachments/confirm` 的全部变体，同时让
`/api/attachments/raw` 只接受 GET/HEAD。以下员工业务映射仍进入通用 `/api/` 代理：

- `GET /api/attachments`（按业务单据查询附件）；
- `GET /api/attachments/{id}/download-grant`；
- `GET /api/attachments/reconciliation/findings`；
- `GET /api/attachments/raw/{key}`（读取已存在的最终对象）；
- `DELETE /api/attachments/{id}`（受 `attachment:manage` 控制）；
- `POST /api/attachments/reconciliation/findings/{id}/approve-delete`（受 `attachment:reconcile` 控制）。

当前明确关闭的写映射是：

- `POST /api/attachments/presign` 和 `POST /api/attachments/confirm`；
- `PUT /api/attachments/raw/{key}`。

这些上传专用规则排在通用 API 正则之前，并显式覆盖 Spring 会忽略的矩阵参数；后面的认证、导出
regex 和通用 `location /api/` 不能重新代理被关闭的
上传请求；员工删除和对账审批则不会被误拦。启用任何附件上传必须同时复核 Controller 路由清单、
应用门禁、恶意文件扫描、配额、Outbox、对账和恢复证据，不能只删除一条 Nginx 规则。

## 3. 源文件

- 应用 profile：`server/src/main/resources/application-internal-test.yml`
- JVM 启动门禁：`server/src/main/java/com/uten/imp/config/InternalTestRuntimeSafetyGate.java`
- 环境示例：`deploy/setup/server.env.internal-test.example`
- 环境校验器：`deploy/setup/validate-internal-test-server-env.sh`
- NVMe 目录校验器：`deploy/setup/validate-internal-test-storage.sh`
- systemd 模板：`deploy/systemd/uten-imp-internal-test.service.example`
- Nginx/TLS 模板：`deploy/nginx/uten-imp-internal-test.conf.example`

环境示例只用于生成 root-only 待审文件；其中 `REPLACE_*` 占位符按设计无法通过校验。真实密钥不得进入
Git、聊天记录、命令参数、普通日志或交接文档。

## 4. NVMe 数据目录验收

在启动应用前，`/data` 必须满足以下条件：

1. 是已挂载的 LVM、ext4、非旋转存储，而不是机械盘 RAID 或根文件系统中的普通目录；
2. 容量至少 300 GiB，挂载参数包含 `rw,nodev,nosuid,noexec`；
3. `/data/uten-imp` 为 `root:root 0755`；
4. `attachments` 为 `root:uten-imp 0750`；其 `staging`、`final` 为
   `uten-imp:uten-imp 0750`；
5. 目录不能是符号链接、不能跨文件系统；服务账号只能写 `staging/final`，不能替换上层目录。

`validate-internal-test-storage.sh` 是只读检查，不会代替建卷、格式化、挂载或目录初始化。任何一项不符，
systemd 都保持后端关闭，避免 `/data` 未挂载时把数据库或附件误写到系统盘。

## 5. 安装与启动顺序

本节只是依赖顺序，不是当前目标机命令单。先完整执行
[目标服务器带外身份与访问 authority 清单](target-host-oob-authority.zh-CN.md)，取得 H01–H12、项目专用
`known_hosts`、两把管理员公钥和可用控制台；完成只读刷新并由操作员确认精确计划/风险/回退后，才可进入
任一写入步骤。
具体 existing-host 事务以 NVMe commissioning 与 internal-test onboarding 手册的签名候选/receipt 为准。

1. 先完成 NVMe LVM、`/etc/fstab`、挂载参数及目录权限配置，并保存回退证据；
2. 建立干净测试库，由独立迁移账号执行冻结签名制品中的 migration-only JAR；
3. 从 `server.env.internal-test.example` 生成待审环境文件，分别核对内部 DNS、精确办公网 CIDR 和
   root 管理的密钥；
4. 安装两个只读校验器，将 internal-test systemd 模板作为规范的 `uten-imp.service`，安装内部测试
   Nginx 模板并替换全部占位符；
5. `nginx -t`、环境校验、存储校验和签名 release/Flyway boot verifier 全部通过后，才允许 enable/start；
6. PostgreSQL、ERP、Nginx、两个 watchdog 按依赖顺序加入开机链；migration unit、故障恢复命令和
   未验收的自动下载/staging timer 不加入普通启动链；
7. 完成一次关机再开机验收，证明 `/data -> PostgreSQL -> ERP readiness -> Nginx` 自动恢复；再模拟
   `/data` 未挂载、数据库未就绪、密钥缺失和错误 profile，确认入口保持关闭。

当前 internal-test 源码候选的 boot verifier 必须接受且只按 schema v3 `lvm-linear-nvme` authority 核验
稳定 mapper 路径、LV/VG/PV/NVMe 身份、ext4 UUID/options 和 PostgreSQL data directory。旧 schema v2
`/dev/md*` observer/`DeviceAllow` 分支仅用于历史兼容，不得成为这台目标主机的正常开机 authority；目标机
若仍装有该分支或仍从旧 md 启动 ERP，立即 NO-GO。不得删除 boot verifier 或跳过它启动服务。

## 6. 验收和升级边界

内部测试 GO 至少需要：聚焦/全量后端测试、Flutter release 构建、Nginx 配置检查、真实 HTTPS 登录、
权限负向矩阵、数据库/附件容量告警、开机恢复和多岗位测试数据 UAT。附件上传保持关闭，不影响其余 ERP
模块验收；以后启用上传必须另行完成恶意文件扫描、配额、Outbox、对账、恢复和负载验收，并同时变更应用
门禁、环境校验与 Nginx 写入规则。

<!-- INTERNAL-TEST-SINGLE-NVME-NOT-PRODUCTION -->
单块 NVMe 仍是单点故障。正式数据进入前，必须有独立故障域的加密 pgBackRest/PITR 副本及实际恢复
演练；推荐增加第二块可靠 SSD。机械盘阵列不得作为权威数据库或唯一备份。本基线只能登记“内部测试”，
不能登记“生产”。

## 7. 回退

配置或启动失败时，停止 Nginx/ERP，保留 PostgreSQL、挂载、日志、签名制品和失败标记的原始证据；不要
删除数据库、附件目录或 release marker。恢复上一份已审 Nginx/systemd/environment 配置后仍需重新通过
全部门禁。涉及 Flyway 集合变化时禁止启动旧 JAR，按前向修复或已演练 PITR 流程处理。
