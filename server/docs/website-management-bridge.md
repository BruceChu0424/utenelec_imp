# 官网与 IMP 服务桥接契约

本文件是当前服务端桥接接口和本地联调入口的维护说明。官网与 ERP 是独立服务；源代码及本地验证不表示已部署阿里云。正式云端部署须另获用户确认。

阿里云官网与公司本地 ERP 的配置顺序、岗位操作、验收和恢复见 [联动操作手册](../../website/docs/aliyun-local-erp-integration.md)。

## 数据、权限和网络边界

- 官网公开访问不依赖 ERP 在线。客户表单在官网同一事务写入询盘及投递记录；ERP 出站拉取、幂等入库，提交成功后精确确认。
- 网站联系人、产品与旧站来源快照保留；重复来源 ID 不覆盖已经接收的事实。通知由已提交的业务 Outbox 产生。
- 销售列表、认领、跟进、关闭和转客户仍在 ERP。网站 CMS 只按 `webinquiry:view` 展示送达记录，不提供第二套办理权限。
- 官网地址只能选择运维预置的 origin。桥接拒绝重定向，只允许固定路径，响应上限 2 MiB，连接超时 3 秒、请求超时 8 秒，使用 HTTP/1.1。
- 生产地址使用 HTTPS。仅显式启用的本地回环联调允许 HTTP；该开关不能作为生产豁免。
- 服务端 Bearer token 与 `X-Uten-Site-Id` 在后通道使用，不回传 Flutter 或 CMS 页面，不进入审计和 URL。token 合同为 `[A-Za-z0-9+/=_-]{43,512}`。

## ERP 管理 API

所有入口位于 `/api/website-management`，要求真实员工、`website:view`，不接受访客、模拟身份或尚待首次改密的账号。

| 入口 | 请求及结果 |
|---|---|
| GET `/api/website-management` | 读取连接版本、状态、当前官网权限及管理入口；只有有配置权的超级管理员会看到可选 origin，响应不含服务密钥 |
| PUT `/api/website-management/config` | `{expectedVersion,displayName,publicOrigin,enabled}`；要求超级管理员、`authorization:manage`、本会话一次性再认证；版本冲突拒绝覆盖 |
| POST `/api/website-management/check` | 核验站点身份和服务状态；检查期间配置变化时不发布过期的“就绪”结果 |
| POST `/api/website-management/open` | `{section,codeChallenge}`；section 为 overview/home/products/resources/news/settings/releases，challenge 为 PKCE S256 的 43 字符 base64url 摘要；返回固定 entryUrl、一次性 code 和过期时间 |

敏感配置前调用 `POST /api/auth/step-up`，请求为 `{password}`。回执 `stepUpToken` 放入配置请求的 `X-Uten-Step-Up` 请求头；凭证仅限签发它的同一账号、同一会话，5 分钟内一次使用，不可记录明文。

管理入口固定为 `/admin/imp-entry`。Flutter 将 code 与 verifier 放在 fragment，网站立即移除 fragment，经同源 POST 验证 PKCE 和身份确认后消费 code。原始 ERP access/refresh token 不进入该网址或网站 cookie。

## 网站后通道 API

入口前缀 `/api/imp/bridge`，所有请求使用相同的站点 ID 与服务身份，响应为私有且不缓存的 JSON。

| 入口 | 合同 |
|---|---|
| GET `/status` | siteId、ready、publishedRevision、pendingInquiries、oldestPendingAt、lastDeliveryAt |
| GET `/inquiries?limit=20` | 只读待确认 items，每条含 deliveryId、sourceId、询盘正文和服务器核验的 sourceContext；读取不会删除或认领 |
| POST `/inquiries/ack` | `{items:[{deliveryId,sourceId,erpInquiryId}]}`；仅确认已经在 ERP 提交的精确来源，重复确认幂等 |
| POST `/authorizations` | requestId、actorId、authSessionId、employeeId、displayName、permissions、section、expiresAt、codeChallenge；网站只存 code 哈希，code 60 秒有效且一次消费 |
| GET `/sessions?limit=100` | 列出当前网站管理会话；后续页使用严格校验的 `after` cursor |
| POST `/sessions/renew` | `{items:[{sessionId,actorId,permissions,expiresAt,revoked}]}`，回执含 renewed/revoked/ignored 计数，不把失败当成功续期 |

网站管理租约最多 5 分钟，绝对会话上限 8 小时。每轮出站同步根据原始 `authSessionId` 重新核验 ERP 会话与当前员工权限；登出、撤权、停用、会话过期或账号不匹配均不续期。某个身份读取失败不虚构授权，也不阻断独立的询盘投递。连接停止后未续期租约自动失效。

## ERP 销售 API

入口前缀 `/api/website-inquiries`。

- GET 列表、`/{id}`、`/counts`、`/new-count` 要求 `webinquiry:view`。列表状态 ACTIVE/HISTORY 在分页前筛选。
- POST `/{id}/status` 请求 `{status,note,assignToMe}`；认领要求 `webinquiry:claim`，关闭要求 `webinquiry:close`。不能抢占其他人的负责人。
- POST `/{id}/follow-ups` 请求 `{note}`；要求 `webinquiry:view` 和 `webinquiry:claim`，且由实际认领者办理。跟进历史只追加，不覆盖。
- POST `/{id}/convert` 要求 `webinquiry:convert_client`；并发及重试只产生一个客户，保留源询盘与负责人。
- 原 POST `/ingest` 兼容服务入口继续受共享密钥与失败限流保护；新官网使用持久拉取和精确 ACK，不采用异步发送日志作为送达依据。

新询盘通知仅投递给当前有效、实际授出 `notice:read`、`webinquiry:view`、`webinquiry:claim` 的员工。通知可进入 `/webinquiry/{id}`；被认领或完成后撤销待办。超级管理员的操作豁免不自动冒充指定销售的通知资格。

## 配置与本地合成验收

运维精确属性为 `uten.website.bridge.allowed-origins`、`token`、`site-id`、`allow-loopback-http`、`poll-delay-ms`、`initial-delay-ms`。在 `application.yml` 显式映射为 `UTEN_WEBSITE_BRIDGE_ALLOWED_ORIGINS`、`UTEN_WEBSITE_BRIDGE_TOKEN`、`UTEN_WEBSITE_BRIDGE_SITE_ID`、`UTEN_WEBSITE_BRIDGE_ALLOW_LOOPBACK_HTTP`、`UTEN_WEBSITE_BRIDGE_POLL_DELAY_MS`、`UTEN_WEBSITE_BRIDGE_INITIAL_DELAY_MS`。默认未配置身份且持久连接禁用；启用通过管理 API 完成，不在迁移中写云端地址或密钥。

本地开发显式使用 `UTEN_PROFILE=dev`，限定回环监听和独立合成数据库。必须提供 `UTEN_DB_URL/USER/PASSWORD`、`UTEN_JWT_SECRET`、`UTEN_PGP_MASTER_KEY`、`UTEN_HMAC_KEY`、`BOOTSTRAP_ADMIN_LOGIN`；空库首次还须一次性 `BOOTSTRAP_ADMIN_PASSWORD`。PGP 主密钥是由 pgcrypto 使用的高熵口令，不是 PEM 文件；新建本地库可使用独立随机 48 字节 base64url 值，不复用公司密钥。

合成账号按正式 API 建立：

1. Bootstrap 创建超管后，以 `POST /api/auth/login {loginAccount,password}` 登录。首次必须 `POST /api/auth/change-password {oldPassword,newPassword}`，使用返回的新令牌。
2. 超管通过 `GET /api/org/departments/tree` 查真实部门 ID，向 `POST /api/org/employees` 提交合成 profile、employment 和 account。必填姓名、证件类型与号码、手机号、部门、入职日期、雇佣类型、状态；active 还需确认日期，不能晚于业务今天。测试必须清楚标注合成，不使用真人信息。
3. 建号结果仅一次返回 `{employee,temporaryPassword,loginAccount}`；新员工同样登录并首次改密。不要从数据库强行关闭 mustChangePassword 来替代流程。
4. 通过 `/api/auth/me` 核验销售实际得到上述询盘与通知权限，完成网站真实提交、断线持久保存、恢复入库及 ACK 后，再从销售界面认领和保存跟进。
5. 本地禁用 AI 外呼及短信：`UTEN_AI_OUTBOUND_ENABLED=false`、`UTEN_SMS_PROVIDER=disabled`。密钥和临时密码仅写 Git 已忽略的私密配置，不进入报告。

2026-10-26 核对的基准 `f9192c79`：Spring Boot 4.1.1，项目 Java 编译目标 21；迁移头 V935、861 份版本迁移、无重复版本。官网管理迁移现为 **V879**；旧暂停记录的 V873 不是当前官网迁移，不能据此启动或核验。干净迁移与定向测试的完成结果以本轮最终报告为准。
