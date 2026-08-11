# 敏感数据 / `.env` 安全审计（20260810）

## 结论

**整体保护到位。** 真实密钥只在 gitignore 的 `server/.env` / `website/.env` 里，从未进 git 历史；提交库里只有纯占位的 `.env.example`；生产 profile 对所有密钥 fail-fast。未发现任何真实生产凭据被硬编码进源码。仅 2 个低危项（见末节），用户决定**只交付审计结论、不改代码**。

---

## 1. env 文件清单

| 文件 | 是否入库 | 性质 |
|---|---|---|
| `server/.env` | ❌ 未入库（`server/.gitignore:7` 忽略；`git check-ignore` 实测命中） | **真实开发值**：`UTEN_DB_PASSWORD=uten`、`UTEN_JWT_SECRET=dev-...`、`BOOTSTRAP_ADMIN_PASSWORD=Admin@12345` 等，均为 dev 专用、标 `change-in-prod`。 |
| `server/.env.example` | ✅ 入库 | **纯占位**：`UTEN_JWT_SECRET=replace-with-...`、`BOOTSTRAP_ADMIN_PASSWORD=replace-with-...`、SMS/OSS key 空。 |
| `website/.env` | ❌ 未入库（`website/.gitignore:10` 忽略） | **真实开发值**（且其 `AUTH_SECRET`/`ADMIN_PASSWORD` 实际会被强度校验拒绝，仅作本地占位）。 |
| `website/.env.example` | ✅ 入库 | 纯占位。 |

**历史核查**：`git log --all -- '**/.env'` 为空 → 任何 `.env` 都从未被提交后删除。`git ls-files` 仅含两个 `.env.example`。

## 2. 三层 gitignore 覆盖

- 根 `.gitignore:47-52`：`server/.env` / `server/.env.*` + `!server/.env.example`。
- `server/.gitignore:6-10`：`.env` / `.env.local` / `!.env.example`。
- `website/.gitignore:9-12`：`.env` / `.env.local` / `.env*.local`。

## 3. 密钥加载机制（后端 Spring）

- `pom.xml` 引 `spring-dotenv`：开发期自动把 `server/.env` 注入 Spring 环境；生产走 OS 环境变量 / Vault / KMS（`deploy/cloud/README-cloud.md`），**不用** `.env`。
- 10 个 `@ConfigurationProperties`（`config/props/`）绑定命名空间配置；仅 4 处 `@Value` 绑非密开关。

| 密钥 | 配置占位（application.yml） | 默认值 | 真实来源 |
|---|---|---|---|
| JWT 签名密钥（HS256） | `uten.jwt.secret: ${UTEN_JWT_SECRET}`（:102） | **无 → fail-fast** | dev `.env` / prod 环境变量 |
| PGP 主密钥（PII 加密） | `uten.crypto.pgp-master-key: ${UTEN_PGP_MASTER_KEY}`（:117） | **无 → fail-fast** | dev `.env` / Vault·KMS |
| HMAC 密钥（身份证查重） | `uten.crypto.hmac-key: ${UTEN_HMAC_KEY}`（:121） | **无 → fail-fast** | dev `.env` / Vault·KMS |
| DB url/user/password | `spring.datasource.*`（:17-19） | dev 弱默认（uten/uten）；**prod profile 剥默认 → fail-fast** | 环境变量 / `.env` |
| 超管初始密码 | `uten.bootstrap.admin-password: ${BOOTSTRAP_ADMIN_PASSWORD:}`（:125） | 空；`BootstrapRunner` 首启强制 ≥12 位 + 首登改密 | 环境变量 / `.env` |
| SMS（阿里云）AK/SK | `${UTEN_SMS_ACCESS_KEY_*:}`（:130-131） | 空 | 环境变量 |
| OSS AK/SK | `${UTEN_OSS_ACCESS_KEY_*:}`（:150-151） | 空；云端优先 RAM 角色（`use-instance-role`） | 环境变量 / RAM 角色 |
| DeepSeek API key | `${DEEPSEEK_API_KEY:}`（:95） | 空 | 环境变量 |
| 老库（SQL Server）凭据 | `${UTEN_LEGACY_DB_*:}`（:167-168） | 空；`UTEN_LEGACY_ENABLED` 默认关 | 环境变量 |

- 生产 fail-fast：`application.yml:15` 默认 profile=prod；`application-prod.yml` 剥掉 DB/JWT issuer/CORS 默认，三大密钥任何 profile 都无默认 → 缺了直接起不来。
- 网站（Next.js）：`AUTH_SECRET`（`lib/auth-secret.ts`，<43 字符/占位/空白即抛）、`ADMIN_PASSWORD`（`prisma/seed.ts`，空/弱/黑名单即抛）均 fail-closed。
- Flutter：`--dart-define` 编译期注入 endpoint，release 强制 HTTPS/非 loopback，无运行时可改的密钥。

## 4. 部署脚本

- `deploy/postgres/prepare-primary.sh`：`umask 077` + `*_FILE` 文件式密钥（≥16 字符校验、拒多行、不入 argv）、admin/repl 密码必不同。
- `deploy/cloud/uten-imp-cloud.service.example`：`EnvironmentFile=/etc/uten-imp/server-cloud.env`（`chmod 0640 root:uten-imp`），内为占位。
- `legacy_migration/migrate.sh`：PGP/HMAC 密钥写临时文件 → docker cp → 执行后立即删本地与容器内副本，不入 git/log/库。

## 5. 低危项（记录，本次不改）

- **L1（开发）** `docker-compose.yml:8-10` 硬编码开发库 `POSTGRES_PASSWORD=uten`（已标 dev-only，与文档默认一致）。生产不共用。可选加固：改 `POSTGRES_PASSWORD_FILE` + Docker secret。
- **L2（PII）** 超管登录手机号硬编码在 3 处当默认值：`application.yml:123`、`BootstrapProperties.java:15`、`BootstrapRunner.java`（javadoc）。非凭据，但暴露了超管账号的登录名（攻击者省一半功夫）。可选加固：`uten.bootstrap.admin-login` 改无 Java 默认、仅环境变量提供（注意会影响本地开发登录，需在 `.env` 配 `UTEN_BOOTSTRAP_ADMIN_LOGIN`）。

## 附：未发现的（明确排除）

无 PEM/私钥块、无长 base64/hex 密钥字面量、无 `password="/secret="/apiKey="` 真实赋值、迁移 SQL 未写死密码哈希（V08 刻意回避）、GitHub workflows 无密钥。
