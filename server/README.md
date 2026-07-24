# Uten IMP 后端（server/）

Spring Boot 3 · Java 21 · Spring Security 6 (stateless JWT) · Spring Data JPA + Hibernate · Flyway · PostgreSQL (pgcrypto)。

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
启动后：
- API 基址 `http://localhost:8080/api`
- Swagger UI `http://localhost:8080/swagger-ui.html`
- 引导超管账号 `admin` / 密码 = `.env` 的 `BOOTSTRAP_ADMIN_PASSWORD`（首登强制改）

## 数据库
- schema 完全由 `src/main/resources/db/migration/` 下的 Flyway 迁移管理（`ddl-auto=validate`）。
- 迁移：`V01` pgcrypto → `V02` 部门/岗位 → `V03` 员工+7 子实体 → `V04` 鉴权+RBAC → `V05` 审计触发器 → `V06` 种子 RBAC → `V07` 种子组织树（含保安部）→ `V08` 种子 admin 员工 → `V09` 审计去密 → `V10` 身份证 HMAC → `V11` 角色/权限审计列 → `V12` 访客系统 → `V13` 访客权限拆分 → `V14` 车牌加密 → `V15` 访客通行码 → `V16` 超管 → `V17` 种子 admin 文档 → `V18` 个人信息修改申请 → `V19` 修改审批权限点 → `V20` 修改申请审计列 → `V21` 权限管理体系（部门默认角色 `department_roles` + 个人权限覆盖 `user_permission_overrides`，见 [ADR-007](../docs/99-决策记录-ADR/ADR-007-导航重构与三层权限模型.md)）→ `V22` 审计覆盖扩展（部门角色/权限覆盖/紧急联系人补触发器）→ `V23` 修复 V18 坏审计触发器（个人信息修改链路的部署级阻断 bug，见 [ADR-009](../docs/99-决策记录-ADR/ADR-009-后端安全加固与功能补全.md)）→ `V24` 岗位模板种子（ADR-010）→ `V25` 决策支持独立权限点 `analytics:view`（默认 manager/admin，与 viewcontext 解耦）。
- 机密 PII（身份证/手机/银行卡/薪资/车牌）用 pgcrypto 字段级加密；主密钥走环境变量 `UTEN_PGP_MASTER_KEY`，每事务 `SET LOCAL app.pgp_key`。
- 审计：敏感表挂 `AFTER` 触发器写 `audit_log`，actor 从会话变量 `app.actor_id` 取（由后端每事务绑定）。
- 并发：员工档案写路径全量手动递增 `version`，修改申请审批时版本不符 → 409 防丢更新（ADR-009 §1）。

## 包结构（2026-07-23 重构后，见 [ADR-008](../docs/99-决策记录-ADR/ADR-008-后端代码结构重构.md)）

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
   │  │                        TokenIssuer · PermissionResolver（权限三层合成）· RefreshTokenService
   │  └─ model/                 UserAccount · RefreshToken · PasswordHistory（实体+仓库）
   ├─ rbac/                   纯 RBAC 模型：Role · Permission · UserRole · RolePermission ·
   │                             DepartmentRole · UserPermissionOverride（实体+仓库，无 API）
   ├─ admin/                  后台管理 API（/api/admin）：AdminUserController ·
   │  │                        UserAccountAdminService（账号状态/重置密码）·
   │  │                        RoleAdminService（角色/部门默认角色）· PermissionOverrideAdminService
   │  └─ dto/                  UserSummary · RoleDto · PermissionDto · 各请求/响应 DTO
   ├─ org/                   组织域
   │  ├─ department/           部门树 CRUD
   │  ├─ position/             岗位（实体+仓库，无独立 API）
   │  └─ employee/             员工：EmployeeQueryService（列表/详情脱敏）·
   │                             EmployeeOnboardingService（入职）· EmployeeCommandService（编辑/生命周期）
   ├─ profilechange/          个人信息修改：Submit/Query/Review 三 Service +
   │                             ProfileFieldApplier（字段读写映射表）· ProfileChangeMapper
   └─ visitor/                访客系统：VisitorAuthService · VisitorApplicationService ·
                                  VisitorHrApprovalService · VisitorHostConfirmService ·
                                  VisitorGateService（保安核验/QR）· VisitorApplicationMapper
```

约定：
- **Controller 不直接注入 Repository**，一律走 Service；跨域共享的小逻辑用包私有 Support 组件（如 AdminUserSupport / ProfileChangeAccess / VisitorGuard），不复制。
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
Argon2id 密码 · 短 access JWT(15min) + 不透明轮换 refresh(7d, 哈希入库, 重用检测) · 登录限流 5/min/IP · 锁定 5/15min · 首登强制改密 · 密码历史最近 5 · DTO 按角色脱敏 · HTTPS 强制(prod) · 严格 CORS · 无堆栈泄露 · **每请求主键级账号状态复查**（锁定/停用立即 401，ADR-009 §4）· **prod 关闭 swagger**（404 + 白名单回落认证，ADR-009 §3）。

## 密钥与敏感配置（务必专业）

所有敏感数据**集中在 `server/.env`，绝不硬编码进代码或进 git**：

- `server/.env.example` 是模板（占位值），`server/.env` 是真实值并已 `.gitignore`。
- 后端通过 `spring-dotenv` 自动加载 `server/.env`（开发）；`application.yml` 用 `${UTEN_DB_URL}` 等占位读取，**密钥类无弱默认值，缺失即 fail-fast**。
- 涉及的密钥：`UTEN_DB_*`（数据库连接）、`UTEN_JWT_SECRET`（≥32 字节）、`UTEN_PGP_MASTER_KEY`（PII 加密主密钥）、`BOOTSTRAP_ADMIN_PASSWORD`（引导超管一次性密码）、`UTEN_CORS_ORIGINS`。
- **生产**：不打包 `.env`，改由服务器环境变量或 Vault/KMS 注入；pgcrypto 主密钥版本化（`app.pgp_key_v1`）并规划再加密迁移路径；备份加密。
- 前端不含任何密钥：API 基址走 `--dart-define=API_BASE_URL`（编译期注入，不进包体），令牌存 `flutter_secure_storage`（iOS Keychain / Android Keystore），**绝不**进 `shared_preferences`。

## 访客系统（V12，前后端打通）

- 访客独立于员工 `users` 表（`users.employee_id NOT NULL`），走 `visitor_accounts` + **双主体 JWT**（`typ=visitor`，`JwtAuthFilter` 按 typ 分支复查状态）。
- 接口：`/api/visitor/auth/*`（手机验证码注册登录，permitAll）、`/api/visitor/applications/*`（访客自助）、`/api/visitor/directory/*`（被访人目录，**排除离职**）、`/api/visitor-approval/*`（HR 审批 / 被访人确认）、`/api/security/verify|check-in`（保安扫码核验）。
- 短信验证码：开发期 `uten.sms.provider=log`（后端日志打印 + send-code 返回 `devCode` 便于联调），生产改 `aliyun`（`AliyunSmsGateway` 已留 stub）。
- 二维码凭证：HR 批准后签发 `base64({aid,exp}).HMAC`，保安端验签 + 查状态判绿（放行）/红（禁止），签到后失效。
- 员工检测：访客注册时查 `employee_sensitive.phone_hash`，命中则拦截提示走员工通道。
- 详见 [docs/03-页面/访客预约系统.md](../docs/03-页面/访客预约系统.md)。

## 测试
```bash
mvn test    # Testcontainers 拉起真实 PostgreSQL（含 pgcrypto），验迁移/触发器/鉴权/脱敏
```
