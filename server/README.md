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

## 数据库
- schema 完全由 `src/main/resources/db/migration/` 下的 Flyway 迁移管理（`ddl-auto=validate`，当前源码最高为 V147；目标库实际版本以 `flyway_schema_history` 为准）。
- 迁移：`V01` pgcrypto → `V02` 部门/岗位 → `V03` 员工+7 子实体 → `V04` 鉴权+RBAC → `V05` 审计触发器 → `V06` 种子 RBAC → `V07` 种子组织树（含保安部）→ `V08` 种子 admin 员工 → `V09` 审计去密 → `V10` 身份证 HMAC → `V11` 角色/权限审计列 → `V12` 访客系统 → `V13` 访客权限拆分 → `V14` 车牌加密 → `V15` 访客通行码 → `V16` 超管 → `V17` 种子 admin 文档 → `V18` 个人信息修改申请 → `V19` 修改审批权限点 → `V20` 修改申请审计列 → `V21` 权限管理体系（部门默认角色 `department_roles` + 个人权限覆盖 `user_permission_overrides`，见 [ADR-007](../docs/99-决策记录-ADR/ADR-007-导航重构与三层权限模型.md)）→ `V22` 审计覆盖扩展（部门角色/权限覆盖/紧急联系人补触发器）→ `V23` 修复 V18 坏审计触发器（个人信息修改链路的部署级阻断 bug，见 [ADR-009](../docs/99-决策记录-ADR/ADR-009-后端安全加固与功能补全.md)）→ `V24` 岗位模板种子（ADR-010）→ `V25` 决策支持独立权限点 `analytics:view` → `V26` 工资条生成权限移交财务 → `V27` 部门直配权限点 `department_permissions` + 用户偏好 `user_preferences`（[ADR-011](../docs/99-决策记录-ADR/ADR-011-工作台部门分区与动态权限配置.md)）→ `V28` 权限目录分组名中文化 → `V29` **角色体系下线**（存量角色权限沉淀为部门配置，PermissionResolver 不再读 user_roles/department_roles）→ `V30` 敏感字段脱敏按权限点化（新增 `employee:pii:view`）→ …（`V31`–`V63` 各业务模块迁移，详见 migration 目录）→ `V64` 下线决策支持模块，删除 `analytics:view` 权限点（前端 `/analytics/*` 路由与工作台卡片同步移除）→ …（`V65`–`V120` 销售/采购/委外/仓库/生产/钱流/通知/建议/归属隔离/业务链 V90–V100，详见 [docs/数据迁移/41 需求落地总路线图](../docs/数据迁移/41-需求落地总路线图.md)）→ `V121` 客户铺底额 → `V122` **总账子系统**（`gl_vouchers`/`gl_entries` + `account_style_id()` 函数，科目复用 payment_styles 树，docs 44）→ `V123` 固定资产折旧+长期待摊（`fixed_assets`/`deferred_expenses`/计提日志 + 科目种子 /152/ 累计折旧·折旧费·摊销费，docs 45）→ `V124` 出货财务审核（`sales_shipments.finance_audit`）+ 费用单总账状态（`finance_expenses.gl_status`，docs 46）。
- `V125`–`V147`：人员 ID 回填、生产计划关联/看板、货品来源、数据完整性与长期索引、权限边界拆分、物化视图刷新状态、采购/销售/委外累计数量约束、工资/员工报销领域、迁移追溯、access JWT 授权版本、财税部报销付款权限、按 owner 聚合/索引的销售月报、工资/报销、访客、财务资产与建议长期分页索引、员工 PII/薪酬独立写权限，以及跨单据交易/上游订货分配不变量的数据库兜底。PostgreSQL 16.14 全新库已应用 128 个迁移到 V147。现有开发库（2,234,077,667 bytes / 2130.58 MiB）在本轮数据库实查时仍为 V144、失败 0；其 835 个约束中 834 validated，1,031 个索引全部 valid/ready，V142+V144 有 6 个完整性触发器，V142 三项和 V144 两项回滚式主动探针均被拒绝且未留测试数据。开发库及任何目标库仍须先备份并演练 V145–V147。V134 的表结构不代表增量 loader 或全模块自动对账已经实现；V135 的源码存在也不代表权限失效覆盖矩阵和逐请求查询性能已经验收；V137 重建物化视图，升级窗口须纳入耗时和并发刷新验证；V138–V143 的索引仍须以生产同构查询计划和 P95/P99 关闭性能风险；V141 的字段级写权限和 V142/V144 的跨单据兜底须做真实 HTTP/业务矩阵。
- `V145` 把货品价格从二进制浮点收敛为 `NUMERIC(18,4)` 并由 Java `BigDecimal` 对齐；
  `V146` 让后续通用审计在复制 before/after 前移除密文、HMAC、凭证与直接身份字段，不在
  Flyway 长事务内无界重写历史审计；`V147` 增加独立的高阈值鉴权 IP 粗桶设置。历史审计若需
  保留，应按主键范围分批脱敏并 `VACUUM`；V145–V147 均须在生产同构副本复跑迁移与回滚验收。
- 机密 PII（身份证/手机/银行卡/薪资/车牌）用 pgcrypto 字段级加密；主密钥走环境变量 `UTEN_PGP_MASTER_KEY`，每事务 `SET LOCAL app.pgp_key`。
- 审计：`UserOperationAuditInterceptor` 为所有认证后的 `POST/PUT/PATCH/DELETE` 请求记录账号、方法、路径、结果/状态码、耗时、IP 与 UA，且刻意不保存请求正文以避免复制密码/PII；关键表再由 `AFTER` 触发器提供 before/after，显式安全/业务事件走 `AuditService`。通用请求审计不等于所有表都有 before/after，上线前仍须完成“写端点→业务事件→表触发器”矩阵验收。
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
├─ audit/                  审计写入（AuditService · AuditLog 实体/仓库）
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
   │  └─ asset/                  固定资产折旧 + 长期待摊摊销（docs 45）
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

JSON Controller 请求体由 `JsonRequestBodyLimitAdvice` 统一限制，默认
`UTEN_MAX_JSON_BODY_BYTES=1048576`（1 MiB），同时覆盖无 `Content-Length` 的 chunked 请求；
超限固定返回 413 `PAYLOAD_TOO_LARGE`，畸形 JSON/类型固定返回 400 `MALFORMED_REQUEST`。
multipart/二进制不走该缓冲器，未来上传端点必须单独采用流式大小策略。导出密码请求统一使用
`@Valid @NotBlank @Size(min=6,max=128)`；`EncryptedWorkbookService` 重复校验同一边界，
报表不提供明文导出分支。登出 refresh token 最大 512 字符，同时继续接受空 body 的幂等登出。
老库 Java 迁移模块失败只向客户端返回稳定错误码和 UUID `referenceId`，异常类型、数据库地址和
底层 message 只进受控服务端日志。

## 密钥与敏感配置（务必专业）

所有敏感数据**集中在 `server/.env`，绝不硬编码进代码或进 git**：

- `server/.env.example` 是模板（占位值），`server/.env` 是真实值并已 `.gitignore`。
- 后端通过 `spring-dotenv` 自动加载 `server/.env`（开发）；`application.yml` 用 `${UTEN_DB_URL}` 等占位读取，**密钥类无弱默认值，缺失即 fail-fast**。
- 涉及的关键配置：`UTEN_DB_*`（数据库连接）、`UTEN_JWT_SECRET`（≥32 字节）、
  `UTEN_JWT_ISSUER`（环境唯一且生产必填）、`UTEN_PGP_MASTER_KEY`（PII 加密主密钥）、
  `BOOTSTRAP_ADMIN_PASSWORD`（仅空库首次引导所需的一次性密码）、`UTEN_CORS_ORIGINS`。
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
[生产就绪审计报告](../docs/99-项目治理/2026-07-30-生产就绪审计报告.md)。
中国大陆环境还须执行
[中国大陆部署与兼容性](../docs/99-项目治理/中国大陆部署与兼容性.md)。

本轮最终工作树已执行 `UTEN_RUN_DB_TESTS=true mvn verify`：81.369 秒、退出码 0，
56 份 Surefire XML 精确汇总 178 tests、0 failures、0 errors、0 skipped；完整编译 842 个 main
与 56 个 test 源文件，并在 PostgreSQL 16.14 空库完成 128 个迁移到 V147。该本地结果仍不替代远端受保护分支 CI、真实 HTTP 权限/E2E 与生产同构
发布演练。

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
