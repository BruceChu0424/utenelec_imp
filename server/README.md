# Uten IMP 后端（server/）

Spring Boot 3.5.16 · Java 21 · Spring Security 6 (stateless JWT) · Spring Data JPA + Hibernate · Flyway · PostgreSQL (pgcrypto)。

> 本目录是独立 Maven 工程，与 Flutter 前端（`lib/`）平级。

## 前置
- JDK 21（`java -version`）
- Maven 3.9+（或用 `./mvnw` 包装器）
- PostgreSQL 16+（可用下方 Docker 一键起）

## 快速开始
```bash
cd server
cp .env.example .env            # 按需改密码/密钥（生产务必换强随机值）
docker compose up -d postgres   # 起开发用 Postgres（含 pgcrypto）
mvn spring-boot:run             # 启动后端，Flyway 自动建表 + 种子
```

本地开发必须在 `.env` 中显式保留 `UTEN_PROFILE=dev`。未设置 profile 时服务端按 `prod`
启动并要求生产数据库、JWT issuer、CORS 等变量齐全，配置缺失直接失败，避免把开发默认值误带到
生产。

启动后：
- API 基址 `http://localhost:8080/api`
- Swagger UI `http://localhost:8080/swagger-ui.html`（仅显式 `dev` profile 默认开放；base/prod 默认关闭）
- 健康检查 `http://localhost:8080/actuator/health`（仅暴露 health，启用存活/就绪探针）
- 空库首次引导超管账号 `admin` / 密码 = `.env` 的 `BOOTSTRAP_ADMIN_PASSWORD`（首登强制改）。
  账号一旦存在，启动器严格跳过，不会把人工撤销的超级管理员权限重新授回。

## 本机免 Maven 启动（`_scratch/`，git-ignored）

本机没有全局 Maven 时，用「固定类路径 argfile + java 直启」的方式跑后端（2026-08-03 起实际使用）：

- `_scratch/server_classpath.argfile` — 解析好的运行时类路径（`target/classes` + `.m2` 依赖，
  一行一个长 `-cp` 参数，供 `java -cp "@<argfile>"` 使用）。
- `_scratch/run_server.bat` — 用上述 argfile 启动 `com.uten.imp.UtenImpApplication`，
  控制台输出重定向到 `_scratch/server_restart.log`。
- `_scratch/start_server.ps1` — `Start-Process` 后台拉起 `run_server.bat`（最小化窗口），
  用于重启后立即可用；停止用 `taskkill /PID <pid> /F`。

三个文件都在 git 忽略的 `_scratch/` 里，可以写本机绝对路径，不进仓库。

**两个坑（2026-08-03 实录）**：
1. **argfile 会过期**。`spring-boot:run`/IDE 生成的 argfile 是按当时依赖版本解析的，pom 升级
   （如 Spring Boot 3.3.5 → 3.5.16）后旧 argfile 仍指旧 jar，且放 `%TEMP%` 会被系统清理。
   升级依赖或清理 Temp 后必须重新生成：`mvn spring-boot:run` 跑一次会生成最新
   `spring-boot-*.argfile`，复制覆盖 `_scratch/server_classpath.argfile` 即可；或直接用
   新版解析结果重建。版本对不对：`Select-String "spring-boot-(\d)" _scratch/server_classpath.argfile`
   应与 pom 的 `spring-boot-starter-parent` 版本一致。
2. **改完代码要重编 class 再重启**。运行中的 JVM 不热加载：IDE 自动构建或手动
   `javac -d target/classes`（`-processorpath` 限定 Lombok，否则 Spring 配置处理器会读
   target 里的 metadata 报错）之后，重启进程才生效。另外给已有 Spring Bean 加第二个构造器时，
   主构造器必须显式 `@Autowired`（否则启动报 "No default constructor found"）。

## 数据库
- schema 完全由 `src/main/resources/db/migration/` 下的 Flyway 迁移管理（`ddl-auto=validate`，当前候选源码最高为 V202）。2026-08-01 只读证据确认公司目标库最高已应用 V190；V191–V202 的源码存在、编译或隔离迁移通过都不等于目标库已升级，实际版本始终以该库 `flyway_schema_history` 为准。资产专项 V01–V186 的 SQL 顺序回放没有 Flyway 元数据，仍不得冒充目标库迁移证据。
- 迁移：`V01` pgcrypto → `V02` 部门/岗位 → `V03` 员工+7 子实体 → `V04` 鉴权+RBAC → `V05` 审计触发器 → `V06` 种子 RBAC → `V07` 种子组织树（含保安部）→ `V08` 种子 admin 员工 → `V09` 审计去密 → `V10` 身份证 HMAC → `V11` 角色/权限审计列 → `V12` 访客系统 → `V13` 访客权限拆分 → `V14` 车牌加密 → `V15` 访客通行码 → `V16` 超管 → `V17` 种子 admin 文档 → `V18` 个人信息修改申请 → `V19` 修改审批权限点 → `V20` 修改申请审计列 → `V21` 权限管理体系（部门默认角色 `department_roles` + 个人权限覆盖 `user_permission_overrides`，见 [ADR-007](../docs/99-决策记录-ADR/ADR-007-导航重构与三层权限模型.md)）→ `V22` 审计覆盖扩展（部门角色/权限覆盖/紧急联系人补触发器）→ `V23` 修复 V18 坏审计触发器（个人信息修改链路的部署级阻断 bug，见 [ADR-009](../docs/99-决策记录-ADR/ADR-009-后端安全加固与功能补全.md)）→ `V24` 岗位模板种子（ADR-010）→ `V25` 决策支持独立权限点 `analytics:view` → `V26` 工资条生成权限移交财务 → `V27` 部门直配权限点 `department_permissions` + 用户偏好 `user_preferences`（[ADR-011](../docs/99-决策记录-ADR/ADR-011-工作台部门分区与动态权限配置.md)）→ `V28` 权限目录分组名中文化 → `V29` **角色体系下线**（存量角色权限沉淀为部门配置，PermissionResolver 不再读 user_roles/department_roles）→ `V30` 敏感字段脱敏按权限点化（新增 `employee:pii:view`）→ …（`V31`–`V63` 各业务模块迁移，详见 migration 目录）→ `V64` 下线决策支持模块，删除 `analytics:view` 权限点（前端 `/analytics/*` 路由与工作台卡片同步移除）→ …（`V65`–`V120` 销售/采购/委外/仓库/生产/钱流/通知/建议/归属隔离/业务链 V90–V100，详见 [docs/数据迁移/41 需求落地总路线图](../docs/数据迁移/41-需求落地总路线图.md)）→ `V121` 客户铺底额 → `V122` **总账子系统**（`gl_vouchers`/`gl_entries` + `account_style_id()` 函数，科目复用 payment_styles 树，docs 44）→ `V123` 固定资产折旧+长期待摊（`fixed_assets`/`deferred_expenses`/计提日志 + 科目种子 /152/ 累计折旧·折旧费·摊销费，docs 45）→ `V124` 出货财务审核（`sales_shipments.finance_audit`）+ 费用单总账状态（`finance_expenses.gl_status`，docs 46）。
- `V125`–`V147`：人员 ID 回填、生产计划关联/看板、货品来源、数据完整性与长期索引、权限边界拆分、物化视图刷新状态、采购/销售/委外累计数量约束、工资/员工报销领域、迁移追溯、access JWT 授权版本、财税部报销付款权限、按 owner 聚合/索引的销售月报、工资/报销、访客、财务资产与建议长期分页索引、员工 PII/薪酬独立写权限，以及跨单据交易/上游订货分配不变量的数据库兜底。2026-07-30 的 PostgreSQL 16.14 空库基线已应用 128 个迁移到 V147；其开发库探针和生产验收边界保留在当日[生产就绪审计报告](../docs/99-项目治理/2026-07-30-生产就绪审计报告.md)，不得误作当前最高版本。
- `V145` 把货品价格从二进制浮点收敛为 `NUMERIC(18,4)` 并由 Java `BigDecimal` 对齐；
  `V146` 让后续通用审计在复制 before/after 前移除密文、HMAC、凭证与直接身份字段，不在
  Flyway 长事务内无界重写历史审计；`V147` 增加独立的高阈值鉴权 IP 粗桶设置。历史审计若需
  保留，应按主键范围分批脱敏并 `VACUUM`；V145–V147 均须在生产同构副本复跑迁移与回滚验收。
- `V148`–`V168` 落地通知定向受众、生产物料履约/执行分段/供应转换/追加式台账与约束、Outbox、
  工作台概览、特权库存调整及旧数据修复；`V169` 增加审计风险、分类与 API/公开业务表完整覆盖，
  `V170` 增加人力概览索引，`V171` 增加独立导出权限和可配置两阶段留存，`V172` 增加设备证据与
  本机关联，`V173` 增加独立查看权限并在服务层/数据库层禁止部门授予两个审计权限。2026-07-31
  定向 PostgreSQL 16 空库验证到 V173 属于历史证据。
- `V174`–`V181` 覆盖政策受众、组织层级、自制子计划归属、历史货品锚标记、销售预留优先级、
  自制需求路径、模具部门/保管人 UUID 以及 BOM stub 隔离，并已在 2026-08-01 本地目标库应用。
  V181 后活动 BOM 198,025 条、活动 stub 端点 0；81 条误接边和严格证明安全的 2 条 DRAW 明细/
  1 张空采购申请链已软删，31 个历史货品锚及成本、余额和历史单据引用保留。V181 自此不可修改，
  后续修正必须新增迁移。V183 将 V123/V140 原型升级为资产/待摊专业子账，并为 9 张新表显式挂接审计触发器、自带只补缺 sweep；`V184`
  不修改已应用的 V169，而是在其后独立复核审计触发器的启用状态、AFTER ROW、I/U/D 事件与调用函数；
  `V185` 将后续软删除明确写成 delete，并扩充迁移列明的原因备注类敏感文本/大型嵌套快照脱敏且保留 V172 设备关联字段。
  `V186` 增加生产物料反查读索引，`V187` 增加销售出货策略与仓库作业结构，`V188` 增加不可变仓库状态事件账，`V189` 增加销售退货质量冻结和追加式处置证据；`V190` 在新增业务表之后重跑“每张公开业务表恰有一个有效、启用、AFTER ROW、覆盖 I/U/D 且调用批准脱敏函数”的 fail-closed 审计 sweep，只覆盖以后操作、不补历史。公司目标库只读版本证据已到 V190，但历史全量对账、运行复核和发布签字仍须单独完成。V188/V189 不回填历史状态时间线或质检结论。资产范围、默认门禁和 NO-GO 见
  [51 · 资产与待摊专业化全链路](../docs/数据迁移/51-资产与待摊专业化全链路.md)及
  [2026-08-01 验收报告](../docs/99-项目治理/2026-08-01-资产与待摊全链路实现与验收报告.md)。
- `V191` 保存不可变审前预排草案，`V192` 保存可修改的未来车间建议，`V193` 刷新审计覆盖，`V194` 增加直接层 MAKE 子计划供给 peg、FINISHED_IN 精确回供/红冲/重新齐套、AUTO_WAIT/DEFERRED 单向人工放行及组织层级守卫；`V195` 在 MAKE 分摊业务表之后再次刷新 fail-closed 审计覆盖。五个迁移均不回填旧业务事实，V193/V195 也不补历史审计。目标库部署与真实岗位 UAT 尚未完成；完整边界见 [52 · 生产预排审核下达与车间建议](../docs/数据迁移/52-生产预排审核下达与车间建议.md)。
- `V196` 增加采购/委外订货指定财务负责人、审批实例与追加式事件、未来入库任务及独立权限；历史 `status=1` 订货不补审批历史、不重放副作用。`V197` 在新增业务表后刷新审计触发器覆盖；`V198` 修正祖先部门权限继承，拆开计划、采购和仓库能力；`V199` 建立未分解申请明细任务投影，并从剩余量中同时扣除已生效和待财务订单；`V200` 继续阻断计划通过祖先授权查看委外商业单据和供应商主档；`V201` 增加超量到货财务审批、收货单绑定的追加额度、原下单人优先、带有效账号回退的精确退货任务、收货/订单行数据库守卫与独立权限；`V202` 在 V196/V201 新业务表之后重新扫描全部 `public` 业务表，缺失时补唯一 `trg_audit*`，并 fail-closed 校验其启用、AFTER ROW、I/U/D 与批准脱敏函数；只记录 V202 应用后的操作，不补历史审计。完整规则见 [ADR-019](../docs/99-决策记录-ADR/ADR-019-计划需求分解与采购委外财务审批.md)。
- V196–V202 当前只是源码候选：公司目标库仍只确认到 V190。源码已具备“超量触发任务但不入库/AP→精确财务负责人全批/自定义/不批→仓库再审批准量→精确退货任务负责人完成未批量退回”的 fail-closed 控制，但尚未完成目标库备份/迁移/校验、真实多账号对象范围 UAT、仓库实物与供应商退回演练、完整 IQC 及发布签字，生产继续 **NO-GO**。
- 当前 Java/API 契约是：计划链下达采购/委外申请，业务端申请 Controller 只提供列表、详情和跨申请明细分解预览；订货保存为 `status=0` 后立即调用 `/{id}/submit-finance`，只有提交快照中的精确财务负责人可通过/驳回。财务通过才令订单 `status=1`、回写来源并生成 `inbound_expectations`；预计到货不是库存、IQC 或 AP。端点、权限和状态详见[Java 后端契约 §十](../docs/数据迁移/28-Java后端契约.md#十计划需求分解订货财务审批与超量到货专用契约v196v202)。
- 数量示例（无历史收退）：订货批准 10 吨、收货草稿申报 100 吨时，先产生 90 吨 `requestedExcessQty` 并返回 409，库存/AP/订单累计均为零变化。财务全批后接受 100 吨；自定义额外批准 5 吨后接受 15 吨、85 吨交精确退货任务负责人退回；不批超量则接受 10 吨、90 吨退回。任何接受量都必须由仓库再次审核后才过账，财务决定本身不入库、不立应付。
- 2026-08-02 V196–V202 后端候选最终证据：主代码编译通过；默认 `mvn -q test` 共 221 个测试类、775 项，0 failure/error、70 skipped，实际执行 705 项全部通过；其中到货状态/权限/事务契约 8/8、全量审计迁移契约 6/6、采购/委外相关回归 7/7。隔离 PostgreSQL 的 `SecurityPermissionMigrationTest` 1/1 完整执行 Flyway 至 V202；新增到货数据库守卫测试 2/2 从空库应用 183 个迁移至 V202，并证明 INSERT 路径不读 `OLD`、未批准超量以 SQLSTATE 23514 拒绝、财务追加额度只能由绑定收货单消费。以上不是公司目标库升级、历史数据迁移或真实岗位 UAT。
- Flyway 已应用迁移必须保持原字节、文件名和顺序不变；任何共享环境一旦执行 V196–V202，后续修正只能新增 V203+。禁止修改旧迁移后清理 checksum，也禁止用 SQL 顺序回放替代 `flyway_schema_history` 证据。
- 2026-08-02 V191–V195 阶段的历史候选证据：`UTEN_RUN_DB_TESTS=true mvn verify` 曾通过 202 个测试类、699/699，0 failure/error/skip，并生成 JAR；隔离 PostgreSQL 16.14 的 21 个真实数据库测试类 69/69，空库迁移至 V195。它已被上方 V196–V202 证据后置，且从来不等于目标库升级、真实岗位 UAT、数据前后快照、压测、恢复演练或发布签字。
- 2026-08-01 最终候选在隔离 Testcontainers PostgreSQL 16.14 从空库成功迁移并 Flyway validate
  171 个迁移至 V190；19 个真实 PG 类 58/58（含 `SecurityPermissionMigrationTest` 8 项、退货质检幂等/回滚和
  库存/生产/采购/Outbox 链），Java 默认套件 611 项（0 failure/error、58 skipped），Flutter 全量
  306/306、analyze 0 issue，Web JavaScript/Windows x64 Release 与后端 JAR 均构建成功。
  这些结果不是公司目标数据库的升级/历史对账证据，也不替代真实账号岗位 UAT、压测、备份恢复、
  制品签名和发布签字；Web Wasm 仍受 `flutter_secure_storage_web` 兼容性限制。
  销售—仓库—计划—生产/采购/委外的证据范围、风险和 NO-GO 见
  [2026-08-01 全链路安全复核报告](../docs/99-项目治理/2026-08-01-销售仓库生产采购委外全链路安全复核报告.md)。
- 销售履约当前安全边界：出货商业事实由服务端从来源订单重建，财务已审先反审才可修改；所有
  `SHIPPED` 禁止普通红冲，缺 `handed_over_at` 的历史行也不例外；新退货审核只进 V189 冻结，
  仅 `GOOD_RELEASE` 入可售库存。V90 `chain_status=0` 且无预留的旧未结订单不能新建 V187 出货，
  必须逐行对账后显式激活，当前没有自动批量激活。
  退货质检普通 view 继续按销售 owner/委派过滤；现有单退货质检 GET/POST 在对象策略调用层使用 PMC 操作旁路，
  但目前没有独立跨 owner 任务列表或工作台，PMC 也不能据此打开受普通 owner 范围保护的完整退货详情。
  质检处置 Widget 7/7 和真实 PG 4/4 已证明同弹窗重试复用、跨弹窗独立键、精确重放、冲突、并发与事务回滚；
  owner 契约仍只锁定 Service 对象策略调用，不证明 view/handle 方法鉴权、handle-only 负向、任务发现或真实账号端到端完成。
- `V167` 的余额调整使用独立 `stock:balance:adjust`，迁移不默认授予部门；
  `POST /api/stock/balances/adjust` 在 Controller 与 Service 双层鉴权，以库存锁 + `expectedQty`
  防止陈旧覆盖，以服务端保留前缀和部分唯一索引保证幂等，并在同一事务生成已审核 `CHECK`、
  9/10 流水和余额变化。完整权限、API、成本及历史边界见
  [仓库盘点修正与历史单据处理](../docs/数据迁移/50-仓库盘点修正与历史单据处理.md)。
- 机密 PII（身份证/手机/银行卡/薪资/车牌）用 pgcrypto 字段级加密；主密钥走环境变量 `UTEN_PGP_MASTER_KEY`，每事务 `SET LOCAL app.pgp_key`。
- 审计：`AuditRequestContextFilter` 与 MVC 拦截器共同覆盖进入应用的
  `GET/POST/PUT/PATCH/DELETE/HEAD /api/**`，包括匿名认证、401、CORS 非法来源 403、404/405 和
  MVC 前异常；有效 JWT 绑定 request 级 actor 快照，无效令牌不绑定身份。请求层记录方法、路径、
  结果/状态码、耗时、IP、UA 与设备关联，但不保存 query 值或正文；显式安全/业务事件走
  `AuditService`，V169 为公开业务表变化补脱敏 `AFTER` before/after。审计中心只允许超级管理员或获
  个人 `audit_log:view` 授权的核查人员只读访问；导出还需 `audit_log:export`、文件密码与 Agile
  AES-256。默认最近七天的“用户操作 + 写操作”只改善可见性，系统/迁移记录仍完整保留；对象类型/ID、
  来源、Request ID、操作类型和用户/系统范围均由服务端过滤。首次列表返回 `snapshotId`，分页、统计、
  导出固定 `id <= snapshotId`，排除通常后续分配的高 ID（不是跨请求 MVCC；旧 ID 晚提交/留存并发仍需实库验收）。在线/归档记录没有人工编辑或
  删除 API，只能由 V171 留存任务先归档后按期删除。V169 或任一触发器生效前的实际历史缺口不得反向补造。
- 并发：员工档案写路径全量手动递增 `version`，修改申请审批时版本不符 → 409 防丢更新（ADR-009 §1）；V132 在数据库侧用 12 个触发器保护采购/销售/委外累计收、发、退数量，避免并发审批突破来源数量。V132 不改写历史异常，只允许其向合法方向减少。

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

## 账号状态语义（2026-07-23 修正）

| 状态 | 含义 | 登录行为 |
|---|---|---|
| `active` | 正常 | 放行（登录成功不再回写 status，避免冲掉人工状态） |
| `locked` + `lockedUntil` 未到期 | 暴力破解临时锁（5 次失败 / 15 分钟） | 拒绝「请稍后再试」，到期后登录成功自动恢复 |
| `locked` + `lockedUntil=null` | 管理员手动锁（权限管理页「锁定」） | 拒绝「账号已被管理员锁定」，仅管理端 unlock 可解 |
| `disabled` | 停用 | 拒绝 |

锁定检查同时覆盖登录（LoginService）与令牌刷新（TokenIssuer.refresh），防止被锁用户持 refresh token 续期。

## 安全要点（见顶层计划文档 §四、§十三）
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
`pg_trigger` 验证所有非白名单公开业务表；详见
[审计可见性修复与复核报告](../docs/99-项目治理/2026-08-01-审计可见性修复与复核报告.md)。

JSON Controller 请求体由 `JsonRequestBodyLimitAdvice` 统一限制，默认
`UTEN_MAX_JSON_BODY_BYTES=1048576`（1 MiB），同时覆盖无 `Content-Length` 的 chunked 请求；
超限固定返回 413 `PAYLOAD_TOO_LARGE`，畸形 JSON/类型固定返回 400 `MALFORMED_REQUEST`。
multipart/二进制不走该缓冲器，未来上传端点必须单独采用流式大小策略。导出密码请求统一使用
`@Valid @NotBlank @Size(min=6,max=128)`；`EncryptedWorkbookService` 重复校验同一边界，
报表不提供明文导出分支。登出 refresh token 最大 512 字符，同时继续接受空 body 的公开幂等登出；
已撤销/未知/空 token 都是不泄露差异的 no-op。匹配 token 的审计只记录 owner 用户 ID 与 token UUID，不记录
token 原文或 hash；after-commit 审计失败不回滚已经完成的撤销。客户端在本地 logout 返回前先把旧 refresh
写入有界加密待撤销队列，网络发送异步并可在启动/恢复后排空。普通 logout 只撤销 refresh，不保证已签发
access 立即服务端失效；access 最多存活到短 TTL，紧急全局清退需递增授权版本/epoch或轮换 issuer/签名密钥。
老库 Java 迁移模块失败只向客户端返回稳定错误码和 UUID `referenceId`，异常类型、数据库地址和
底层 message 只进受控服务端日志。

## 密钥与敏感配置（务必专业）

所有敏感数据**集中在 `server/.env`，绝不硬编码进代码或进 git**：

- `server/.env.example` 是模板（占位值），`server/.env` 是真实值并已 `.gitignore`。
- 后端通过 `spring-dotenv` 自动加载 `server/.env`（开发）；`application.yml` 用 `${UTEN_DB_URL}` 等占位读取，**密钥类无弱默认值，缺失即 fail-fast**。
- 涉及的关键配置：`UTEN_DB_*`（数据库连接）、`UTEN_JWT_SECRET`（≥32 字节）、
  `UTEN_JWT_ISSUER`（环境唯一且生产必填）、`UTEN_MAX_HTTP_REQUEST_HEADER_SIZE`
  （有限请求头预算，默认 16KB）、`UTEN_PGP_MASTER_KEY`（PII 加密主密钥）、
  `BOOTSTRAP_ADMIN_PASSWORD`（仅空库首次引导所需的一次性密码）、`UTEN_CORS_ORIGINS`；
  `UTEN_FINANCE_ASSET_POSTED_WORKFLOWS_ENABLED` 不是密钥，但属于资产核心落账高危门禁，缺省和
  `.env.example` 均必须为 `false`。在资产验收报告从 NO-GO 改判前不得启用。
- **生产**：不打包 `.env`，改由服务器环境变量或 Vault/KMS 注入；pgcrypto 主密钥版本化（`app.pgp_key_v1`）并规划再加密迁移路径；备份加密。
- 前端不含任何密钥：API 基址属于可公开的部署配置，员工端与访客端共同通过
  `lib/core/network/api_base_url.dart` 校验。开发未配置时使用
  `http://localhost:8080/api`；Web Release 未配置时使用同源 `/api`；移动/桌面 Release
  必须用 `--dart-define=API_BASE_URL=https://...` 显式指定，HTTP、回环地址及带
  userinfo/query/fragment 的异常地址会 fail-fast。`dart-define` 会编译进产物，**不得用于密钥**。
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
```bash
mvn test
```

CI 的后端门禁使用 `UTEN_RUN_DB_TESTS=true mvn verify`，并与 Flutter 格式/analyze/test/Web 构建、
Git 历史 Gitleaks 和 OSV 依赖扫描并行。工作流文件存在或本地测试通过都不能替代远端 CI、
完整权限矩阵、关键业务 E2E 与生产同构迁移演练。发布门禁见
[生产就绪审计报告](../docs/99-项目治理/2026-07-30-生产就绪审计报告.md)和
[2026-08-02 连接、会话与工作台稳定性修复报告](../docs/99-项目治理/2026-08-02-连接会话与工作台稳定性修复报告.md)。
不可变制品、原子切换、严格 health、Nginx/systemd/watchdog 见 [deploy/README.md](../deploy/README.md)。
中国大陆环境还须执行
[中国大陆部署与兼容性](../docs/99-项目治理/中国大陆部署与兼容性.md)。

2026-07-30 完整基线曾执行 `UTEN_RUN_DB_TESTS=true mvn verify`：178 tests、0 failures/errors/skipped，
并在 PostgreSQL 16.14 空库完成 128 个迁移到 V147。2026-07-31 审计中心变更另完成 Flutter 定向
28 tests、定向 analyze 无问题，后端核心 55 tests、安全链 17 tests、PostgreSQL 定向 8 tests，
空库完整应用 154 个迁移到 V173。后者是审计功能的定向历史证据，不覆盖 V174–V190，也不替代合并后
全量远端 CI、真实 HTTP 权限/E2E、生产同构迁移和发布演练。

2026-08-01 最终候选代码树：Java 21.0.11 / Maven 3.9.16 默认套件 611 项，0 failure、0 error、
58 skipped；`UTEN_RUN_DB_TESTS=true` 的 19 个 PostgreSQL 16.14 Testcontainers 类共 58/58，
0 failure/error/skip，并由 Flyway 校验 171 个迁移到 V190。销售退货质检专项真实覆盖精确重放、
同键异载荷冲突、并发串行化和库存写入后末端失败的整事务回滚。`mvn.cmd -q -DskipTests package`
成功生成 `target/uten-imp-server-0.1.0.jar`。这些是 V190/V195 阶段的历史证据。当前源码目录已继续到 V202，
公司目标库仍只确认到 V190；不得用空库或旧候选测试代替 V190→V202 的备份、迁移、对账和恢复演练。

2026-08-02 连接/会话事故候选在隔离快照编译 1007 个 main、221 个 test 源文件；22 类 89 项中实际
执行 87 项，0 failure/error，2 项 PostgreSQL 条件测试因本轮未设置 `UTEN_RUN_DB_TESTS` 跳过。Header/CORS、
Auth、最小 JWT、服务端权限、密码失效、logout/audit、Dashboard 和工作台均在执行范围；这些定向结果仍不替代
真实多账号 HTTP/UAT、目标 PostgreSQL 非空时间映射、网关 12/18 KiB、容量、恢复、外部告警与生产配置验收。

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
