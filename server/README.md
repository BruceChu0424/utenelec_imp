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
- 迁移：`V01` pgcrypto → `V02` 部门/岗位 → `V03` 员工+7 子实体 → `V04` 鉴权+RBAC → `V05` 审计触发器 → `V06` 种子 RBAC → `V07` 种子组织树（含保安部）→ `V08` 种子 admin 员工 → `V09` 审计去密 → `V10` 身份证 HMAC → `V11` 角色/权限审计列 → `V12` 访客系统（5 表 + security 角色 + visitor 权限点）。
- 机密 PII（身份证/手机/银行卡/薪资）用 pgcrypto 字段级加密；主密钥走环境变量 `UTEN_PGP_MASTER_KEY`，每事务 `SET LOCAL app.pgp_key`。
- 审计：敏感表挂 `AFTER` 触发器写 `audit_log`，actor 从会话变量 `app.actor_id` 取（由后端 AOP 每事务绑定）。

## 安全要点（见顶层计划文档 §四、§十三）
Argon2id 密码 · 短 access JWT(15min) + 不透明轮换 refresh(7d, 哈希入库, 重用检测) · 登录限流 5/min/IP · 锁定 5/15min · 首登强制改密 · 密码历史最近 5 · DTO 按角色脱敏 · HTTPS 强制(prod) · 严格 CORS · 无堆栈泄露。

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
