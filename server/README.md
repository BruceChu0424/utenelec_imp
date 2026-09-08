# Uten IMP 后端

本目录是独立 Maven 工程，使用 Java 21、Spring Boot、PostgreSQL 16 和 Flyway。依赖版本以 [pom.xml](pom.xml) 为准。

| 需要了解的内容 | 权威入口 |
|---|---|
| 最新业务规则、页面、服务函数和测试 | [文档索引](../docs/README.md)、[业务续作指引](../docs/07-业务链路/03-续作指引.md) |
| 当前源码迁移目录和历史兼容 | [迁移总索引](../docs/数据迁移/README.md)；已应用迁移保持原字节，修正向前追加 |
| 本轮通过项与尚未完成项 | [统一验收记录](../docs/99-项目治理/2026-09-07-全平台本地审计与整改验收.md) |
| 公司内网部署和恢复 | [现役发布运行手册](../deploy/simple/RUNBOOK.zh-CN.md)、[内部测试运行配置](../deploy/internal-test-runtime.zh-CN.md) |

本页只维护开发启动、代码入口与验证方法，不再堆叠旧迁移目录、历史测试数量和过时服务器状态。源码可运行、局部测试通过、公司服务器已安装是分别验证的结果。

## 前置
- JDK 21（`java -version`）
- Maven 3.9+
- PostgreSQL 16+（可用下方 Docker 一键起）

## 快速开始
```bash
cd server
cp .env.example .env            # 模板已连接 Docker 宿主端口 localhost:5433
docker compose up -d postgres   # 起开发用 Postgres（含 pgcrypto）
mvn spring-boot:run             # 读取 .env，Flyway 自动建表 + 种子
```

`docker-compose.yml` 将容器内 PostgreSQL `5432` 映射为宿主机 `5433`，因此直接运行 Maven/IDE
时必须连接 `jdbc:postgresql://localhost:5433/uten_imp`；`.env.example` 已与该映射保持一致。若改用
本机原生 PostgreSQL，需在私有 `.env` 中显式改成实际端口，不要修改共享模板来适配个人环境。

> **V400 非空库启动门禁**：Flyway 会先对 `legacy_id` 非空且 `currency_id` 为空的旧账户按已审规则桥接：
> `OFFSHORE` → 唯一使用中、未删除的 `currencies.legacy_id=3` 美金 UUID，其它 legacy 账户 →
> 唯一使用中、未删除的 `currencies.legacy_id=1` 人民币 UUID。已有显式 UUID 和 `legacy_id` 为空的
> 在线/手工账户不会被推断。目标币种缺失/多匹配，或桥接后活动账户仍为空币种、悬空、禁用或删除时，
> 启动/独立 migrator 会以 SQLSTATE `23514` 失败并回滚。当前本地候选数据实测 27 行（26 人民币 +
> 1 境外美金），不能作为目标库事实；目标库必须先做备份、可恢复非空副本演练及映射前后对账。
> 当前美金币种参考汇率为 0 不影响账户原币余额、流水或余额核对：美元账户记美元，人民币账户记人民币，
> 不同币种不直接相加。外币非零余额调整的本位币 `localDelta` 由财务在该调整中显式提供，不读取主档率。
> 修复前置数据后原样重跑迁移，
> 禁止修改 V400–V405、篡改 checksum 或使用 `flyway repair`。

以上命令**只用于本地开发**。生产不得复制开发 `.env` 或直接运行 `spring-boot:run`；应使用不可变 JAR、
受控密钥注入、Nginx/systemd 和维护窗口迁移，见上方现役发布运行手册。

本地开发必须在 `.env` 中显式保留 `UTEN_PROFILE=dev`。当前内部 ERP 测试服务器必须只使用
`UTEN_PROFILE=internal-test`，完整契约见
[`deploy/internal-test-runtime.zh-CN.md`](../deploy/internal-test-runtime.zh-CN.md)。未设置 profile 时服务端按 `prod`
启动并要求生产数据库、JWT issuer、CORS 等变量齐全，配置缺失直接失败，避免把开发默认值误带到
生产。

### 运维脚本（server/ops/）

| 脚本 | 作用 |
|---|---|
| `ops/reset_business_data.sql` | 停写后的业务重置。目标数据库与系统标识必须精确匹配；CLEAR/PRESERVE目录必须完整分类，未知表或未完成Outbox拒绝。清空业务单据、库存与资金事实，保留主档身份、人事、账号权限、审计和迁移证据；账户/遗留期初与预算字段按明确清单归零。当前支持版本、表分类和真实psql验收见迁移索引。 |
| `ops/audit_retention.sql` | 审计日志 180 天热保留 + 归档冷存，幂等，可手动或定时执行 |

### 本地/云端生产 profile

| 站点 | 必须 profile | 数据库行为 | 员工访问边界 |
|---|---|---|---|
| 当前内部 ERP 测试服务器 | 仅 `internal-test` | 写本机干净测试库；运行后端禁用 Flyway，迁移只走独立 migration-only 流程 | 内部 DNS + HTTPS；Nginx 精确办公网 CIDR；后端只监听回环 |
| 公司本地 | `prod` | 写公司本地主库；由本地实例执行 Flyway | `/api/**` 只接受 `UTEN_LOCAL_ALLOWED_CIDRS` 内来源 |
| 阿里云 ECS | `cloud,prod` | 正常时仍写公司主库；云端 PostgreSQL 只作异步热备；云端不执行 Flyway | 只有 `remote_access=TRUE` 员工可登录/refresh/访问业务 API |

正常链路下两个 App 提交到同一个主库，不做数据库双写。公司到云端断链时，本地继续写，云端员工业务
请求返回 `503 PRIMARY_UNAVAILABLE`，不得缓存或恢复后静默重放。若要求断链期间两端都写，必须另做逐业务域
冲突/补偿设计，不能把云端副本开放写入。

员工远程权限由超管 `PUT /api/admin/users/{id}/remote-access` 管理，默认关闭；变化会撤销 refresh token
并使旧 access 的授权版本失效。访客 OTP 是独立公网主体，不取得员工 ERP 权限，也不由 `users.remote_access`
字段表示。Release 客户端端点必须构建期固定；禁止让员工手填任意 host。

`prod/cloud` 还会强制 `UTEN_STORAGE_PROVIDER=oss`、HTTPS endpoint、
`UTEN_OSS_REQUIRE_VERSIONING=true`。附件使用两个不同 Bucket：upload-only staging 必须 Versioning=Off，
server-only final 必须 Versioning=Enabled；启动时读取并核对两者，配置或权限不足即拒绝启动。
这些 fail-fast 只证明配置没有降级，不证明真实 CORS、RAM、版本重放、恶意扫描或恢复演练已经通过。
数据库侧同样 fail-closed：`prod/cloud` 的非回环 `spring.datasource.url` 必须包含
`sslmode=verify-full` 与绝对 `sslrootcert` 路径；cloud 主/副库即使是回环也执行该要求，并拒绝自定义
SSL factory/hostname verifier。明确的本机回环继续允许开发、内部测试和固定 migration-only 流程。
门禁通过不等于目标 CA、证书 SAN、证书续期或实际 app-role 链路已经验收。
`internal-test` 不属于该例外的生产 profile：它由独立门禁只允许
`/data/uten-imp/attachments` 本地目录，并默认关闭上传；任何与 `prod/cloud/dev` 的 profile 组合都会拒绝启动。

启动后：
- API 基址 `http://localhost:8080/api`
- Swagger UI `http://localhost:8080/swagger-ui.html`（仅显式 `dev` profile 默认开放；base/prod 默认关闭）
- 健康检查 `http://localhost:8080/actuator/health`（仅暴露 health，启用存活/就绪探针）
- 空库首次引导超管账号必须由受控环境配置 `uten.bootstrap.admin-login` 提供，源码和公开文档不保存真实账号；一次性密码由 `.env` 的 `BOOTSTRAP_ADMIN_PASSWORD` 提供（首登强制改）。
  账号一旦存在，启动器严格跳过，不会把人工撤销的超级管理员权限重新授回。

## 本地启动与并行测试的编译目录

`spring-boot:run` 默认从 `target/classes` 加载应用类。运行或启动服务时，另一个终端若在同目录执行
`mvn clean test`，会删除 JVM 正在使用的 class 文件，可能报 `NoClassDefFoundError` 或外层的
`Lookup method resolution failed`。这类缺类错误先检查编译目录，不修改业务源码或已应用迁移。

并行测试必须选择独立输出目录，默认开发启动仍使用 `target`：

```powershell
# 测试终端；clean、主代码、测试代码、报告全部位于 target-tests
mvn "-Duten.build.directory=target-tests" clean test

# 开发启动终端
mvn spring-boot:run
```

多个测试任务也应使用各自独立的 `target-任务名`，不要让它们同时清理同一输出目录。
`server/target-*/` 已在 Git 忽略规则内。已经启动的旧构建不会受新参数影响，须等待其结束后再恢复服务。
遇到缺类且没有其它构建占用默认目录时，可先执行 `mvn -DskipTests clean compile`，成功后再启动。

## 数据库与启动排错

表结构只由 [正式迁移目录](src/main/resources/db/migration) 管理，Hibernate使用 `ddl-auto=validate`。本地启动会校验并执行新迁移；公司服务器使用发布包的独立迁移流程。目标库的实际版本必须查询该库 `flyway_schema_history`，不能从README或构建目录推断。

启动失败先检查当前日志中最深一层原因：

1. 连接失败：核对私有环境文件、`UTEN_PROFILE`、数据库名和5433宿主端口。
2. 缺列/缺表：确认本轮源码需要的迁移已进入正式资源且Flyway成功完成；不关闭结构校验。
3. `NoClassDefFoundError` 或依赖不匹配：停止旧进程，使用当前pom完整编译后启动。临时目录或旧依赖生成的classpath/argfile不能长期用作启动入口。
4. 历史数据或迁移校验失败：保留错误及目标库备份，按对应迁移文档修正前提，再原样重跑；不修改已应用文件或执行repair掩盖差异。

V400历史账户币种桥接只适用于有明确legacy来源的行，在线账户不猜币种；旧附件的 `LEGACY_UNVERIFIED` 状态也不能冒充已核验文件。具体兼容规则保留在迁移专册中。

## 包结构（模块化单体，见 [ADR-008](../docs/99-决策记录-ADR/ADR-008-后端代码结构重构.md) 与 [ADR-017](../docs/99-决策记录-ADR/ADR-017-模块化单体与异步旁路.md)）

```
com.uten.imp
├─ config/                 Security 配置 + 配置属性（SecurityProperties 等）
├─ common/                 跨域公共件
│  ├─ domain/                 通用领域基座
│  ├─ util/                   HashUtil(sha256) · Strings(isBlank/maskPhone/last4) · IdCardUtil
│  └─ web/                    ApiException · ErrorCode · PageResponse · Pageables · 全局异常处理
├─ security/               安全基础设施：JwtService · JwtAuthFilter · AuthUser · TxSessionVars
│                             （事务会话变量+pgcrypto 加解密）· AdminGrantGuard · DataAccessPolicy
├─ audit/                  请求/显式事件/表变化审计 + 列表统计详情 + 风险解释 + 设备证据 + 加密导出 + 留存调度
└─ features/               业务域
   ├─ auth/                   员工认证：AuthController · LoginService · PasswordService ·
   │  │                        TokenIssuer · PermissionResolver（全员基础 ∪ 部门配置含上级 ± 个人覆盖）· RefreshTokenService
   │  └─ model/                 UserAccount · RefreshToken · PasswordHistory（实体+仓库）
   ├─ rbac/                   纯 RBAC 模型：Role · Permission · UserRole · RolePermission ·
   │                             DepartmentRole · DepartmentPermission · UserPermissionOverride
   │                             （实体+仓库，无 API；角色相关表自 V29 起仅作兼容保留）
   ├─ admin/                  后台管理 API（/api/admin）：AdminUserController ·
   │  │                        UserAccountAdminService（账号状态/重置密码）·
   │  │                        RoleAdminService（权限点查询）· PermissionOverrideAdminService（个人覆盖）·
   │  │                        DepartmentPermissionAdminService（权限目录/部门配置/有效权限分解；V135
   │  │                        递增用户 auth_version 或全局 epoch，旧 access token 下一请求即失效）
   │  └─ dto/                  UserSummary · PermissionDto · 权限目录/部门配置/有效权限 各 DTO
   ├─ org/                   组织域
   │  ├─ department/           部门树 CRUD
   │  ├─ position/             岗位（实体+仓库，无独立 API）
   │  └─ employee/             员工：EmployeeQueryService（列表/详情脱敏）·
   │                             EmployeeOnboardingService（入职）· EmployeeCommandService（编辑/生命周期）
   ├─ profilechange/          个人信息修改：Submit/Query/Review 三 Service +
   │                             ProfileFieldApplier（字段读写映射表）· ProfileChangeMapper
   ├─ visitor/                访客系统：VisitorAuthService · VisitorApplicationService ·
   │                             VisitorHrApprovalService · VisitorHostConfirmService ·
   │                             VisitorGateService（保安核验/QR）· VisitorApplicationMapper
   ├─ master/                 基础资料（货品/客户/供应商/账户/币种/单位/颜色/仓库等）
   ├─ sales/                  销售（报价/订货/出货/其它出货/退货 + 归属隔离 + 业务链 V90 段）
   ├─ purchase/               采购（申请/订货/收货/退货 + 报表）
   ├─ subcontract/            委外（申请/订货/发料/退料/进仓/退货/废料）
   ├─ stock/                  仓库（单据 8 类型/即时库存/预留台账/盘点）
   ├─ production/             生产（计划/调度/日报/成本 + MRP-lite + 建议完工日）
   ├─ payroll/                工资：批次/工资条/工资项/期间变量输入 +
   │                             生成/提交/审核/驳回/发布/个人查看/PDF 下载
   ├─ expenseclaim/           员工报销：草稿/提交/撤回/审批/驳回/事务化付款
   │                             （与 finance 一般费用单分域，通过 Port 做幂等会计交接）
   ├─ finance/                钱流（收/付/费用/其它收入/银行转账/应收应付/对账流水）+
   │  ├─ report/                 钱流报表 22 张 + 加密导出分发
   │  ├─ statement/              对账单 5 张（附件 1/2/4/5，docs 42）
   │  ├─ cost/                   成本核算 8 报表（附件 15/7/8，docs 43）
   │  ├─ gl/                     总账：GlPostingService（7 类源单幂等过账）+ GlReportService（8 报表，docs 44）
   │  └─ asset/                  资产/待摊专业子账：类别、主档/账簿/计划、审批事件、月度批次、期间与查询（docs 51 / ADR-018；docs 45 仅历史原型）
   ├─ notice/                 通知（广播+每用户已读/删除 + 业务链 8 类自动通知）
   ├─ suggestion/             建议箱（广场/回复/点赞，匿名服务端脱敏）
   ├─ reporting/              6 个物化视图默认每 5 分钟逐个 `CONCURRENTLY` 刷新 + 多实例 advisory lock + 刷新状态记录（V131）
   └─ preference/             用户偏好（报表筛选持久化等）
```

约定：
- **Controller 不直接注入 Repository**，一律走 Service；跨域共享的小逻辑用包私有 Support 组件（如 AdminUserSupport / ProfileChangeAccess / VisitorGuard），不复制。
- 跨 feature 调用只通过公开 Facade/Port；模块边界由 `ArchitectureBoundaryTest` 的依赖图基线持续约束。
- 实体/RBAC 模型包不放 API；`admin` 包只放超管/HR 管理端接口。
- 死代码零容忍：无调用的方法/字段/构造器即删（2026-07-23 大清理基线）。

## 账号状态语义

| 状态 | 含义 | 登录行为 |
|---|---|---|
| `active` | 正常 | 放行（登录成功不再回写 status，避免冲掉人工状态） |
| `locked` + `lockedUntil` 未到期 | 暴力破解临时锁（5 次失败 / 15 分钟） | 拒绝「请稍后再试」，到期后登录成功自动恢复 |
| `locked` + `lockedUntil=null` | 管理员手动锁（权限管理页「锁定」） | 拒绝「账号已被管理员锁定」，仅管理端 unlock 可解 |
| `disabled` | 停用 | 拒绝 |

锁定检查同时覆盖登录（LoginService）与令牌刷新（TokenIssuer.refresh），防止被锁用户持 refresh token 续期。

### 本人资料与账号开通对象边界

- `GET /api/profile/me` 要求 `profile:edit:self`，不接受 employeeId；服务端只从当前
  `AuthUser.employeeId` 解析本人。访客拒绝，账号未绑定档案返回 `404 NOT_FOUND`。
- 本人可见自己的证件、主/备用手机号、人口属性、住址和紧急联系人明文；这不产生
  `employee:pii:view`，不能查看同事。银行与薪酬仍分别要求
  `employee:pii:view` / `employee:compensation:view`。
- 补开账号仍只由 `POST /api/org/employees/{id}/account` 执行，并要求 `account:support`；
  组织负责人或 `authorization:manage` 不自动获得该能力。业务页可按负责人范围列出未开户员工，
  但开户端点自身当前是全局账号支持权限，不能把页面裁剪误写成服务端负责人子树限制。
- 开户成功响应中的初始凭据只展示一次；前端确认保存并关闭凭据弹窗后才刷新账号状态和加载权限。

## 安全要点
Argon2id 密码 · access JWT（源码默认 15 分钟，运行值可由系统设置覆盖；V133 只把未改过的旧默认 480 收敛到 15）+ 不透明轮换 refresh(7d, 哈希入库, 重用检测) · JWT 签发和解析都绑定非空 issuer（生产必须显式 `UTEN_JWT_ISSUER`，即使误用同一密钥也拒绝跨环境 token）· 登录采用账号/规范手机号低阈值 + IP 高阈值双桶并按员工/访客用途隔离 · 锁定 5/15min · 首登强制改密 · 密码历史最近 5 · DTO 按权限点脱敏（`employee:pii:view` / `employee:compensation:view`，V30 起不再按角色） · HTTPS 强制(prod) · 严格 CORS · 无堆栈泄露 · **每请求一次账号/授权版本投影复查**（锁定、停用或 V135 `auth_version`/授权 `epoch` 不匹配立即 401；拒绝响应序列化失败也不得继续过滤链）· **base/prod 关闭 swagger，dev 显式开放**（prod 为 404 + 白名单回落认证，ADR-009 §3）。未设置 `UTEN_PROFILE` 时按 prod fail-closed；默认配置不处理 `Forwarded/X-Forwarded-*`，prod 才使用 `native`，Tomcat 只信任 `UTEN_TRUSTED_PROXY_REGEX`，且部署必须保证后端 8080 仅受信反向代理可达。鉴权/导出桶仍是单实例内存态，多实例部署需改共享状态或由网关兜底；导出另有进程内全局并发闸门（源码默认 2）。开发库已应用 V135；仍须完成个人、角色、部门树、共享权限和超管变化的真实 HTTP 负向矩阵与性能测试，才能认定权限回收即时失效。

staff access JWT 当前只含 `sub/typ/av/ae` 与标准时效/签发字段；账号、员工、角色、权限和
`mustChangePassword` 均由服务端在版本校验后解析。登录/刷新响应仍返回完整
`user.roles/user.permissions` 供客户端兼容。权限快照缓存固定为 30 秒、最多 2048 项且以
user/employee/superAdmin/authVersion/epoch 为键；账号状态和版本不缓存。主动改密与管理员重置密码
都会递增 `auth_version`，让此前 access 立即失效。

服务端权限解析发生数据库/缓存依赖故障时，`JwtAuthFilter` 返回结构化 `503 SERVICE_UNAVAILABLE`，
不得伪装为 401/403；客户端必须保留当前会话。login/refresh/logout 是公开鉴权交换，残留 Bearer 不参与这些请求。

Tomcat 请求行与全部请求头的组合预算默认 16 KiB，可用
`UTEN_MAX_HTTP_REQUEST_HEADER_SIZE` 有限调整；Nginx 示例声明 2×8 KiB large-header buffers
（单字段最多 8 KiB）。该上限不是 JWT 膨胀的替代方案：应先维持 staff token 小于 512 字符、设备证据字段有界并执行真实
Tomcat 回归，再按目标代理链测量调整。

审计证据采用独立权限：超级管理员因固有全权限可查；普通用户、访客和未被点名授权的管理员均不可查。
非超管只能由超级管理员以个人覆盖授予 `audit_log:view`，导出还须个人 `audit_log:export`；部门权限
服务和 V173 数据库触发器都禁止这两个权限进入部门配置或随部门树继承。
新增 Flyway 表必须通过 `AuditTriggerCoverageMigrationContractTest`：最新 audit sweep 之后的表只能是有
书面理由的技术白名单项，否则必须新增后续 sweep。该静态护栏不执行 PostgreSQL DDL，发布仍须查询
`pg_trigger` 验证所有非白名单公开业务表；详见 V218 迁移文件头与 git 历史归档报告。

JSON Controller 请求体由 `JsonRequestBodyLimitAdvice` 统一限制，默认
`UTEN_MAX_JSON_BODY_BYTES=1048576`（1 MiB），同时覆盖无 `Content-Length` 的 chunked 请求；
超限固定返回 413 `PAYLOAD_TOO_LARGE`，畸形 JSON/类型固定返回 400 `MALFORMED_REQUEST`。
multipart/二进制不走该缓冲器，未来上传端点必须单独采用流式大小策略。导出密码请求统一使用
`@Valid @Size(max=128)`；`WorkbookDownloadService` 在密码为空时返回普通 `.xlsx`，提供任意
1–128 位密码时使用 OOXML Agile AES-256 加密。密码只走 body，不进入 URL、查询参数或日志。
登出 refresh token 最大 512 字符，同时继续接受空 body 的公开幂等登出；
已撤销/未知/空 token 都是不泄露差异的 no-op。匹配 token 的审计只记录 owner 用户 ID 与 token UUID，不记录
token 原文或 hash；after-commit 审计失败不回滚已经完成的撤销。客户端在本地 logout 返回前先把旧 refresh
写入有界加密待撤销队列，网络发送异步并可在启动/恢复后排空。普通 logout 只撤销 refresh，不保证已签发
access 立即服务端失效；access 最多存活到短 TTL，紧急全局清退需递增授权版本/epoch或轮换 issuer/签名密钥。
首登账号由 `PasswordChangeRequiredFilter` 收口：除改密、登出和 `/auth/me` 外，全部 `/api` 请求统一返回
`403 PASSWORD_CHANGE_REQUIRED`；`/auth/me` 的用户资料包含 `mustChangePassword`，保证客户端冷启动后
仍回到改密流程，而不是先进入业务页再被动报错。
老库 Java 迁移模块失败只向客户端返回稳定错误码和 UUID `referenceId`，异常类型、数据库地址和
底层 message 只进受控服务端日志。

## 密钥与敏感配置

开发环境敏感数据可集中在不入库的 `server/.env`；生产不得复制该文件或把秘密写进 Git/聊天/日志：

- `server/.env.example` 是模板（占位值），`server/.env` 是真实值并已 `.gitignore`。
- 后端通过 `spring-dotenv` 自动加载 `server/.env`（开发）；`application.yml` 用 `${UTEN_DB_URL}` 等占位读取，**密钥类无弱默认值，缺失即 fail-fast**。
- 涉及的关键配置：`UTEN_DB_*`（数据库连接）、`UTEN_JWT_SECRET`（≥32 字节）、
  `UTEN_JWT_ISSUER`（环境唯一且生产必填）、`UTEN_MAX_HTTP_REQUEST_HEADER_SIZE`
  （有限请求头预算，默认 16KB）、`UTEN_PGP_MASTER_KEY`（PII 加密主密钥）、
  `BOOTSTRAP_ADMIN_LOGIN`（受控环境中的批准账号，不写入源码）、`BOOTSTRAP_ADMIN_PASSWORD`（仅空库首次引导所需的一次性密码）、`UTEN_CORS_ORIGINS`；
  `UTEN_FINANCE_ASSET_POSTED_WORKFLOWS_ENABLED` 不是密钥，但属于资产核心落账高危门禁，缺省和
  `.env.example` 均必须为 `false`。在资产验收报告从 NO-GO 改判前不得启用。
- **生产目标**：不打包 `.env`，改由服务器环境变量或经确认的 Vault/KMS 注入；pgcrypto 主密钥版本化（`app.pgp_key_v1`）并规划再加密迁移路径；数据卷和备份分别加密。当前没有选定/接通 KMS/HSM/Vault，也没有在目标主机实施 LUKS/云盘加密或完成加密备份恢复验收，不能把目标配置写成已部署事实。
- 前端不含任何密钥：API 基址属于可公开的部署配置，员工端与访客端共同通过
  `lib/core/network/api_base_url.dart` 校验。开发未配置时使用 `http://localhost:8080/api`；Web
  Release 固定同源 `/api`，不读取绝对端点。移动/桌面 Release 必须同时指定
  `--dart-define=API_BASE_URL=https://<lan-host>/api` 与
  `--dart-define=CLOUD_API_BASE_URL=https://<cloud-host>/api`；两者均须为批准的 HTTPS host。公司
  `API_BASE_URL` 缺失或非法会 fail-fast；当前 `CLOUD_API_BASE_URL` 缺失或非法会安全退回本地而不是
  连接缓存 host，因此发布流水线必须把“云端地址缺失/非法”单独作为产物验收失败。Release 不读取
  用户手填或历史缓存 host。
  `dart-define` 会编译进产物，**不得用于密钥**。
  令牌存 `flutter_secure_storage`（iOS Keychain / Android Keystore），**绝不**进
  `shared_preferences`。

## 访客系统（V12，前后端打通）

- 访客独立于员工 `users` 表（`users.employee_id NOT NULL`），走 `visitor_accounts` + **双主体 JWT**
  （`typ=visitor`，`JwtAuthFilter` 按 typ 分支复查状态）。访客 access JWT 的 `acc/vno` 都使用
  非敏感 `visitorNo`，头像 seed 单列 `avs`；手机号不进入新签发的 access token。JWT 只签名、
  不加密，禁止把原始 PII 放进 claim。服务端/Flutter 对旧 token 保留短期兼容，部署验收必须确认
  旧 access 已过期或被清退。
- 接口：`/api/visitor/auth/*`（手机验证码注册登录，permitAll）、`/api/visitor/applications/*`（访客自助）、`/api/visitor/directory/*`（被访人目录，**排除离职**）、`/api/visitor-approval/*`（HR 审批 / 被访人确认）、`/api/security/verify|check-in`（保安扫码核验）。
- 列表：本人申请、HR 审批、被访人队列统一返回 1-based `PageResponse`，单页 1..100、按创建时间/id 倒序；V139 建 4 个未删除部分复合索引，人员/部门按页批量加载。员工目录仍返回 `List`，但查询已稳定排序、数据库 `LIMIT 50` 且批量加载部门；大组织仍建议改带 total/truncated 的服务端分页。
- 短信验证码：开发期 `uten.sms.provider=log` 只在日志记录手机号尾四位，**不记录验证码**；只有 dev profile 且显式开启开发响应字段时，send-code 才返回 `devCode`。默认与生产缺省为 `disabled`。生产显式设 `UTEN_SMS_PROVIDER=aliyun` 后使用阿里云国内短信 V2 SDK `dysmsapi20170525:4.6.0`；客户端单例复用，AccessKey/签名/模板/endpoint 缺失时启动失败，模板参数走 JSON，SDK 自动重试关闭，日志只记手机号后四位和供应商 requestId/bizId。同手机号发送会先对 HMAC 派生键取得 PostgreSQL transaction advisory lock，在独立本地事务内复查间隔/日限并提交 OTP 哈希，提交后才调用供应商；明确拒绝删除签发记录，网络结果不确定则保留且不自动重发，避免“短信已到但本地回滚导致验证码必然无效”。上线前仍须用真实账号完成签名、模板、并发限流、余额、结果不确定、故障与告警验收。
- 二维码凭证：HR 批准后签发 `base64({aid,exp}).HMAC`，保安端验签 + 查状态判绿（放行）/红（禁止），签到后失效。
- 员工检测：访客注册时查 `employee_sensitive.phone_hash`，命中则拦截提示走员工通道。
- 详见 [docs/03-页面/访客预约系统.md](../docs/03-页面/访客预约系统.md)。

## 测试

返回 Spring Data `Page` 的列表服务使用 `new PageResponse<>(映射后的明细, 查询结果Page)`，
响应页码、每页数量和总页数来自实际查询，不能再次使用未经归一的请求 `page/size`。
这样请求超过每页上限或页码小于 1 时，前后端仍以同一个实际分页口径工作。
```bash
mvn test
```

CI 的后端门禁使用 `UTEN_RUN_DB_TESTS=true mvn verify`，并与 Flutter 格式/analyze/test/Web 构建、
Git 历史 Gitleaks 和 OSV 依赖扫描并行。工作流文件存在或本地测试通过都不能替代远端 CI、
完整权限矩阵、关键业务 E2E 与生产同构迁移演练。发布门禁见 [ADR-060](../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 与
[新库上线与首装操作指引](../docs/99-项目治理/2026-09-01-新库上线与首装操作指引.md)。
不可变制品、原子切换、严格 health、Nginx/systemd/watchdog 见 [deploy/README.md](../deploy/README.md)。
中国大陆环境还须执行
[中国大陆部署与兼容性](../docs/99-项目治理/中国大陆部署与兼容性.md)。

## 依赖安全基线

- 本轮已把结束支持的 Spring Boot 3.3 升到受支持的 `3.5.16`，springdoc 为 `2.8.17`。
- OSV 2.4.0 初扫命中的 POI 5.2.5 `CVE-2025-31672` 已通过升级到 POI `5.5.1` 处理；
  Bouncy Castle 1.78.1 的 `CVE-2025-14813`（critical）和 `CVE-2026-0636` 已通过升级到 `1.84`
  处理；随后标准 SBOM 扫描发现的 Commons Lang 3.17.0 `CVE-2025-48924`、Jackson Databind
  2.21.4 的 `CVE-2026-59889` / `CVE-2026-54515` / `GHSA-mhm7-754m-9p8w`，以及 PostgreSQL
  JDBC 42.7.11 `CVE-2026-54291`，分别通过升级到 `3.18.0`、`2.21.5`、`42.7.12` 处理。
- 冻结后的 CycloneDX 1.6 SBOM（138 components）经 OSV Scanner 2.4.0 复扫为 0，
  `pubspec.lock`（150 packages）复扫也为 0；这表示当前输入和规则没有已知命中，不等于未来无漏洞，
  仍须远端 CI、Dependabot 和定期复扫。
