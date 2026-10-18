# 官网管理与询盘桥接

IMP 是员工入口和询盘处理权威。官网独立保存公开内容及客户原始提交。公司内网服务从官网拉取持久待投递记录；无需公开内部 ERP 接口。默认关闭，不会自行连接阿里云或发布内容。

## 服务器配置

- `UTEN_WEBSITE_BRIDGE_ALLOWED_ORIGINS`：运维预置的逗号分隔完整 HTTPS origin；不允许路径、用户信息、query 或 fragment。
- `UTEN_WEBSITE_BRIDGE_TOKEN`：独立随机服务身份秘密，格式统一为 `[A-Za-z0-9+/=_-]{43,512}`（建议生成至少 32 随机字节后 Base64/Base64url 编码；不含空白）。仅运行环境注入，与官网服务端规则一致，不返回客户端或写入配置表。
- `UTEN_WEBSITE_BRIDGE_SITE_ID`：固定站点身份，默认 `uten`，须与官网 `WEB_SITE_ID` 匹配。
- `UTEN_WEBSITE_BRIDGE_ALLOW_LOOPBACK_HTTP`：默认 false。仅本机独立测试可设置 true，且 HTTP 仅允许 localhost、127.0.0.1、::1。
- `UTEN_WEBSITE_BRIDGE_POLL_DELAY_MS`：默认 30000。配置启用后由非 cloud profile 服务每轮拉取最多 20 条；同一进程串行，跨进程依靠既有 sourceId 事务锁去重。

迁移 V873 保存非敏感连接配置，初始 enabled=false。超级管理员通过既有再认证机制和 `PUT /api/website-management/config` 选择预置 origin。请求必须携带 expectedVersion，两个管理员不能覆盖彼此的设置。数据库及图片部署、备份、域名变更均不属于启用此功能的自动动作。

## 员工 API

进入页面须 `website:view`；`GET /api/website-management` 返回配置、可用操作权限和最近检测/同步时间。allowedOrigins 只对具备 authorization:manage 的超级管理员可见；没有任何密钥字段。

- `POST /api/website-management/check`：真实只读网站检查，区分可达与 ready；失败保留明确时间和信息，不显示模拟绿色状态。
- `POST /api/website-management/open`：接收 section 和 PKCE S256 codeChallenge；返回 entryUrl、code、expiresAt。entryUrl 只可能是配置 origin + `/admin/imp-entry`，没有 query/fragment。
- Flutter 生成并保留 verifier，只将 code 与 verifier 放在最终浏览器 fragment 中。网站入口确认身份后由同源后端单次兑换，代码哈希和 PKCE 由官网验证。

员工授权经 IMP 到网站的服务间 POST 注册，浏览器不获得 ERP JWT 或 bridge secret。授权同时绑定原始 IMP authSessionId，携带 5 分钟租约；一次性 code 最多 60 秒有效。IMP 每轮出站拉取活跃网站会话，按原会话归属、服务端撤销/绝对期限、当前账号/员工状态与实时权限续期，最多续至网站规定的创建后 8 小时；此后必须重新从 IMP 进入。禁用、首登改密、离职、撤去 website:view、未知身份、缺失原始会话、密码重置/退出/顶号后已撤销的原会话均明确撤销；其他官网权限变更随本轮续期同步。后台续期不更新 IMP last_seen_at，不伪造用户活动。同步失败不虚构续期，旧租约到期后停止访问。配置关闭后不再续期，最长 5 分钟自动失效。授权 code/token/challenge 不进入业务审计。

独立权限：website:content_edit、website:product_edit、website:media_manage、website:publish、website:rollback；均依赖 website:view，不授予全员基础包。网站写端也必须逐项复核这些权限，不能仅依赖隐藏按钮。官网“询盘送达”只读页另透传调用人已经拥有的 webinquiry:view；没有此权限的内容/媒体编辑不获得客户信息，claim/close/convert_client 不透传到官网。

## 网站桥接 API

固定 origin，禁止重定向；使用 HTTP/1.1 避免 Next Node 服务拒绝明文 h2c 升级，HTTPS 的证书校验保持启用。连接超时 3 秒、整个响应超时 8 秒、响应上限 2 MiB（覆盖最多 20 条、有界来源快照与中文正文）。每次发送 Authorization Bearer 与 X-Uten-Site-Id。

- GET `/api/imp/bridge/status`：siteId、ready、publishedRevision、pendingInquiries、oldestPendingAt、lastDeliveryAt。
- GET `/api/imp/bridge/inquiries?limit=20`：items；只读查询未 ACK 的持久记录，不依赖内存 lease。
- 每个 item：deliveryId 与原有 IngestRequest 字段，附 sourceContext 对象。sourceContext 保留 series、products[{id,name,series,sourceIdentity?}]、pageUrl、consentAt、consentPolicyVersion 等来源，原始快照不被重试覆盖。
- POST `/api/imp/bridge/inquiries/ack`：`{items:[{deliveryId,sourceId,erpInquiryId}]}`。只有单条 ingest 事务提交成功并查询到正式 ERP UUID 后才进入 ACK；失败项不混入批量回执。断网或 ACK 丢失会再次拉取同一来源并返回同一个 ERP UUID。
- POST `/api/imp/bridge/authorizations`：requestId、actorId、authSessionId、employeeId、displayName、permissions、section、expiresAt、codeChallenge；网站返回单次 code 和 expiresAt。
- GET `/api/imp/bridge/sessions?limit=100`，后续页 `?after=<id>&limit=100`：items[{sessionId,actorId,authSessionId}] 与 nextCursor；网站只返回有效且创建未满 8 小时的会话。ERP 将安全游标限制在固定路由，最多每轮 100 页，重复游标失败关闭。权限缓存仅在单页内按 actorId+authSessionId 区分，不能把同账号另一台有效设备的权限借给已撤销设备。
- POST `/api/imp/bridge/sessions/renew`：items[{sessionId,actorId,permissions,expiresAt,revoked}]。网站检查原始 actor 匹配、不可复活已撤销/过期会话、最长 5 分钟租约与绝对 8 小时上限；回执为 renewed/revoked/ignored 数量。ERP 不保存 session token，不从网站旧权限推导新权限；某个账号读取失败时跳过其续期并报告失败，其他账号仍可处理。

会话续期与询盘投递互不阻断。一页续期失败会保留失败状态并继续后续页；配置版本变化立即停止旧配置续期。浏览器可以通过官网同源刷新短 cookie，但每次内容写操作仍由官网数据库租约和当前权限裁定；浏览器刷新不得自行延长 IMP 租约。

## 销售处理

原有 ingest sourceId advisory lock 与转客户悲观锁保留。第二个员工认领已有负责人的询盘会收到 409；本人重复认领不重复产生时间线。追加跟进必须由当前跟进人对 following 状态执行，历史记录只追加。

详情新增 sourceContext 与 timeline，含姓名、工号快照和时间；历史 note 迁入 LEGACY_NOTE。sourceContext、自由文本和联系人内容不复制进通用行审计。转客户仍保留 sourceId 和 clientId 溯源。

询盘提交时在同一事务写 business_outbox。通知 worker 只发给当前真实授出 notice:read、webinquiry:view、webinquiry:claim 且账号/员工有效的人员。领取或办结后撤销相应待办。独立 websiteInquiry 徽标红色为未认领，黄色为本人跟进中；不与销售管理模块重复累加。

## 本地验证

定向运行 WebsiteInquiryServiceTest、WebsiteBridgeClientTest、WebsiteInquiryBridgeSchedulerTest、WebsiteManagementServiceTest。开启 `UTEN_RUN_DB_TESTS=true` 后运行 WebsiteInquiryConcurrencyPostgresTest，可在一次性 Testcontainers PostgreSQL 中验证完整迁移、并发领取/转客户、来源重放、时间线不可覆盖、有效通知收件人。

测试运行结果与正式部署证据须分别记录。此文档不表示已部署、已连接真实云端或完成业务岗位验收。
