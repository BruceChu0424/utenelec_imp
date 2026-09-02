# ADR-014：会话超时与 token 刷新机制修复

> 日期：2026-07-27 · 现行补充：2026-08-09 · 状态：**源码与隔离授权 HTTP 已验证；生产 NO-GO**
> 前置：[ADR-013](ADR-013-系统设置与安全策略可视化.md)（系统设置）· 原则：安全首位、最小权限、深度防御
>
> **2026-09-02 后记**：§6 的「同源标签页共享单一记录 + BroadcastChannel 收敛」设计已被
> [ADR-061](ADR-061-多账号多标签页独立会话.md) 取代——会话记录按标签页隔离，跨标签页通知移除；
> 本 ADR 其余语义（CAS/latest-intent/撤销队列/精确拒绝/连接恢复）继续有效。原文保留下文不改。
>
> **现行 TTL 口径**：V75 的“480 分钟/8 小时”只保留为 2026-07-27 的历史决策，不是当前基线。
> `application.yml` 与 `JwtService.readLong(..., 15)` 的当前源码值为 **15 分钟**；目标库
> `system_settings.jwt_access_ttl_minutes` 可覆盖该值，所以生产实际 TTL 必须查目标库/部署配置。V133
> 只把仍等于旧默认 480 的设置收敛到 15，明确自定义值保留。V135 又加入 staff JWT
> `auth_version`/授权 `epoch` 的逐请求校验，权限形状变化会使旧 access 立即 401；该机制仍须完成
> 目标库迁移、覆盖矩阵和性能验收。

> **2026-07-30 故障复盘**：开发后端通过 `mvn spring-boot:run` 直接读取
> `server/target/classes`。进程在 22:09:34 启动后，同一目录又在 22:11:29 被 Maven 验证构建
> 重写；22:12:50 请求鉴权入口时，已经加载的 `SecurityConfig` 无法链接正在替换的
> `ErrorCode.class`，抛出 `ClassNotFoundException/NoClassDefFoundError`。JVM 会缓存失败的类链接，
> 文件恢复后该进程仍只能返回 Tomcat HTML 401，必须重启。这是开发构建目录竞争，不是 admin
> 缺少生产权限，也不是生产数据冲突。

> **2026-08-02 请求头故障后续（现行口径）**：本次“先无权限、刷新后 localhost 拒绝连接”
> 不是 admin 权限被收回。旧 staff JWT 把超管全量权限复制进 `perms` claim，Authorization 字段
> 已约 5 KiB；叠加设备审计证据和浏览器常规头后可越过 Spring Boot/Tomcat 默认 8 KiB 的组合请求头
> 上限，请求会在进入 `JwtAuthFilter` 前被解析器拒绝。请求头异常本身只拒绝该连接，不会主动关闭
> JVM；观测到后端随后无监听仍需按独立进程退出/部署故障调查。
>
> 决策是双层根治：staff JWT 缩为 `sub/typ/av/ae`，角色/权限由服务端在逐请求状态/版本校验后
> 解析（30 秒、2048 项版本键缓存）；登录/刷新响应继续返回 user 权限兼容客户端。主动改密和管理员
> 重置均递增 `auth_version`，旧 access 下一请求失败。Tomcat 使用 16 KiB 组合预算，
> Nginx 模板使用 2×8 KiB large-header buffers；可通过 `UTEN_MAX_HTTP_REQUEST_HEADER_SIZE` 调整，但不得无限放大替代 claim/设备头最小化。
> 嵌入式 Tomcat 回归需同时证明 12 KiB 通过、18 KiB 被拒绝。
>
## 背景

用户反馈两个症状，经全链路核实（前后端代码 + 只读调查 agent）锁定为**两个独立 bug**：

**症状 A：系统设置改「自动退出登录」为 1 分钟，要 ~30 分钟（旧值）才弹窗。**
- 根因：前端 `IdleTimeoutGuard._loadThreshold()` 只在进入系统时拉一次 `/api/settings/public`（注释自述「管理员改了，下次登录生效」）。超管改阈值后，当前会话不重新拉，仍用旧值。
- 后端无问题（`SystemSettingsService.readInt` 不缓存、每次查库，改了立即生效）。

**症状 B：用着用着系统显示「无权限」，重新登录才恢复正常（约每 access TTL 一次）。**
- 根因：**过期的 access token，后端返回 403 而非 401**。
  - `JwtAuthFilter` 解析过期 token 抛异常 → catch 里只 `clearContext()` + 放行（不写 401）；
  - `SecurityConfig` 没配 `AuthenticationEntryPoint`，Spring 默认 `Http403ForbiddenEntryPoint` → 返 403；
  - 前端 `AuthInterceptor` **只在 401 时刷新 token**，收到 403 就当「无权限」显示横幅。
  - access TTL 原 15 分钟 → 活跃用户每小时撞 4 次。重登拿新 token 又能用一个 TTL，故「重登才恢复」。
- 配套毛病：前端 `sessionProvider.user.permissions`（权限快照）只在 login/restore/changePassword 时拉，access 静默刷新时不同步（`_refresh()` 丢弃响应里的 user）。

> 设计意图本身正确（V73 滑动会话：有操作续期、空闲 N 分钟才弹窗）——是上述实现缺口让它没按预期工作。

## 决策（现行合并口径）

### 1. 后端过期/匿名 → 统一返 401（症状 B 根本修复）

`SecurityConfig.filterChain` 加 `.exceptionHandling(e -> e.authenticationEntryPoint(...))`：过期/缺失/伪造 token、匿名访问受保护资源 → **401 + `ApiError(UNAUTHORIZED)`**。前端识别 401 → 自动 refresh + 重试（**用户无感**）。

- login/refresh/health/访客仍是 Spring authorization 的 permitAll 路径；但 local 站点的源 CIDR
  Filter 位于 JWT/Controller 前，仍覆盖 login/refresh 和访客 `/api/**`。permitAll 不是公网放行。
- 「账号锁定/停用」仍走 `JwtAuthFilter.writeUnauthorized` 主动 401，不冲突。
- 「有效 token 但权限不足」仍走 `GlobalExceptionHandler.handleAccessDenied` 返 403 FORBIDDEN（真无权限），语义不变。

### 2. access TTL 重新开放为系统设置可调项（V75）

V74 曾删 `jwt_access_ttl_minutes`；V75 历史上重新插入并给出 480 分钟。该值随后由 V133 对“仍等于
旧默认 480”的记录收敛为 **15 分钟**，明确自定义值保留。`application.yml`、`JwtService.issueAccess`
与 `getAccessTtlSeconds` 的当前回退均为 15，`SystemSettingsService.validate` 仍要求最小 5。
因此当前源码/迁移基线是 15 分钟，8 小时只能用于解释历史，生产实际值仍须读取目标库设置。

### 3. 前端权限快照随 access 刷新滑动更新

`SessionEventBus` 的 `publishProfile(userJson)` 用 Map 避免 core 反向依赖 auth model；
`AuthInterceptor` 在 refresh CAS 写回成功后为 profile 附加 generation/intent/lineage，`sessionProvider`
只有在这些字段仍匹配权威记录和可见 lineage 时才更新 `state.user`。权限快照随当前会话刷新，不接纳
迟到旧代 profile，也不依赖历史 8 小时 TTL。

### 4. 前端 idle 阈值实时刷新（症状 A 修复）

`IdleTimeoutGuard` 三管齐下：① 进系统拉一次；② 每 5 分钟 `Timer.periodic` 轮询；③ 监听 `idleThresholdVersionProvider`（StateProvider<int>）信号——超管在「系统设置」保存 `session_idle_timeout_minutes` 后自增，立即重拉（当前会话即时生效，不必重登）。`_check` 改秒级判定（`inSeconds >= threshold*60`）让 1 分钟等小阈值精确。

### 5. 瞬态故障不得升级为退出登录（2026-07-30）

原 `AuthInterceptor` 把 refresh 的 401、5xx、断网、超时和响应解析错误全部压成 `null`，
随后无条件清理 access/refresh token；刷新成功后的业务重放只要出现 403、5xx 或网络错误也会
无条件清会话。`SessionEventBus` 因此把一次后端部署/类加载故障放大成用户直接退出。

现行实现使用共享 `TokenRefreshResult` 明确区分：

- `refreshed`：保存新令牌、同步最新用户权限快照并重放原请求；
- `rejected`：仅本地没有 refresh，或响应精确匹配 `401 + UNAUTHORIZED/ACCOUNT_LOCKED/
  ACCOUNT_DISABLED`、`422 + VALIDATION_FAILED`；staff 另含
  `403 + REMOTE_ACCESS_DENIED`，visitor 另含 `403 + VISITOR_BLOCKED`。清理前
  还必须 CAS 命中提交时的当前 token record；
- `unavailable`：HTML/空体/未知 code 401、status/code 错配、任意 503、429、网络/超时、
  异常响应和缺 access 的畸形 2xx 都保留令牌并传播真实错误。

刷新成功后的业务重放无论返回 401、403、5xx 或网络异常，都不直接销毁会话；账号确实被停用、
锁定或 refresh token 被撤销时，下一次刷新会由刷新接口返回上述权威结构化拒绝，再执行 fail closed 退出。
访客拦截器和应用启动恢复采用同一破坏性拒绝规则。`SessionNotifier` 的 expiration、profile 与
external-token-change 三个 Stream 订阅均随 Provider 释放，避免测试、热重载或容器重建累积监听器。

生产调度页原先会在 `TabBarView` 首次构建时同时加载待排产、进行中、已完成三个 Tab，共触发
1 个待排产请求和两组各 3 个进度请求。现在只加载当前可见 Tab：进入待排产由 7 个首批请求降为
1 个；切换到进度 Tab 时才加载该 Tab 的 3 个查询，既降低首屏延迟，也避免并发 401 放大故障。

### 6. 错峰 401、跨标签页与用户操作竞态（2026-08-02）

旧实现只用进程内 refresh Future 合并“同时到达”的 401，不能覆盖请求错峰、多个 Dio 实例、多个浏览器标签页，以及登录/退出/改密与迟到响应交错。现行决策是：

- access、refresh、`generation`、`intentGeneration`、`sessionLineage` 作为单个
  `auth.token_record.v1` JSON 权威记录（当前 schema version 2）。generation 随每次权威写递增；
  intentGeneration 只随登录、改密、退出或明确凭据失效推进；refresh 保持 intent/lineage。
- 旧双键仅在权威记录不存在时迁移，顺序为“新记录写成功 → best-effort 删旧键”。权威键存在但不可解析
  是 fail-closed 边界：直接写无 token、全新 lineage 的 tombstone，禁止残留旧键复活。
- refresh 使用独立 scope 锁：Web 首选 Web Locks，不支持时用只含随机 owner/到期时间的 90 秒可续租
  localStorage lease；非 Web 同 scope 共用进程队列。BroadcastChannel 也只发 origin、三个代次字段和
  hasTokens，锁、lease、通知都不保存 token。
- refresh 成功写回与明确拒绝清理比较完整快照 CAS；登录/改密先预留全局 intent，提交只在
  `intentGeneration + reservedLineage` 仍最新时成功。`SessionNotifier` 再用本地 mutation epoch
  对提交前后复核；网络交换不占用短提交队列。因此 latest-intent-wins，不是最后响应获胜。
- 每个受保护请求绑定 lineage/intent。迟到旧 401 若同 lineage 的 access 已更新可直接重放；用户已经
  登录/退出/改密换代时，旧请求/响应以本地 `409 SESSION_CHANGED` 丢弃，不能在新账号下重放或显示。
  会话读取不可用时以 `409 SESSION_STATE_UNAVAILABLE` 拒绝结果，并提示先核对服务端权威结果。
- 退出立即更新可见状态并激活独立、非敏感的 durable logout fence；随后在跨标签 token record 锁内读取
  最新记录，通过 `beforeClear` 先把旧 refresh 持久交接到 `flutter_secure_storage` 加密撤销队列（最多
  32 项、30 天），交接成功后才写 logout tombstone。交接/清理失败时按 0/30/120ms 重试；交接失败会
  保留 fence 与原 token record 供重试，禁止先删除设备上的唯一 refresh 副本。网络撤销不阻塞 UI；只有
  持久交接和本地清理成功才清 fence，显式新登录 intent 可安全取代它。
- 撤销 drainer 只调用公开且幂等的 `/auth/logout`，启动、连接恢复或 5s/30s/2m/10m/30m 有界退避
  唤醒，成功后删除精确 token。它不是通用业务离线队列，禁止承载订单、审批、支付或其它写 payload。
- `SessionEventBus.expire()` 的异步尾事件消费前复核本地 mutation epoch 与无 token tombstone；
  profile 刷新事件必须匹配 generation/intent/lineage。启动 `/auth/me` 成功后复核完整 identity；
  恢复信号撞上在途恢复时登记 pending，原请求结束后补跑。

该协调只决定“哪个客户端结果可以提交”，不放宽后端鉴权。明确的账号停用、授权版本变化、refresh 撤销仍 fail closed；业务写请求也不因连接恢复而重放。

### 7. 安全读有限重试与严格健康恢复（2026-08-02）

- `SafeRequestRetryInterceptor` 仅对 GET/HEAD/OPTIONS 的连接/发送/接收超时、连接错误、408/502/
  504/503 自动重试两次，延迟固定 400ms、1200ms。POST/PUT/PATCH/DELETE 不因连接恢复重放。
- 结构化 `503 + SERVICE_UNAVAILABLE` 允许安全读短重试，但说明 HTTP 服务可达、认证状态解析暂不可用；
  它不触发全局 disconnected、不清会话。其它瞬态失败耗尽后才进入后台探测。
- 探测固定走同源根 `/actuator/health`，不拼到 `/api`；2/5/10/15 秒档位采用 85%–100% jitter，
  手动重试跳过等待，重叠探测合并。只有 `HTTP 200 + JSON Map + status=UP` 才恢复；HTML、空体、
  空对象、DOWN 或非 200 都失败。Nginx 精确代理 health/liveness/readiness，其它 Actuator 路径 404，
  防止 Flutter SPA fallback 返回假 200。

### 8. 最小 JWT、服务端权限解析与请求头预算（2026-08-02）

- staff access JWT 只含标准签发字段与 `sub/typ/av/ae`，不含账号、员工、角色、权限或
  `mustChangePassword`；登录/刷新/改密响应 profile 仍返回服务端合成的 roles/permissions。
- `JwtAuthFilter` 每请求先查当前账号状态、员工绑定和两个版本，再从服务端解析权限；版本键 LRU
  只缓存 30 秒、最多 2048 项。账号不存在/停用/删除、绑定无效或版本不匹配为结构化 401；数据库、
  账号投影或权限解析器异常为结构化 `503 + SERVICE_UNAVAILABLE`，客户端保留会话。
- Tomcat 对请求行加全部请求头设置 16 KiB 有限预算；Nginx 模板为 4 KiB 常规缓冲和
  `2 × 8 KiB` large buffers（单字段仍不超过 8 KiB）；设备审计上下文编码最多 1536 字符。先最小化
  JWT/设备证据再做目标环境测量，禁止无限上调。嵌入式 Tomcat 合同测试覆盖约 12 KiB 接受、18 KiB
  返回 400/431。
- 请求头超限只发生在容器解析阶段，不能证明、也不会主动造成 JVM 停止监听；“localhost 拒绝连接”
  必须单独按进程退出、端口、部署版本和监督服务调查。

### 9. 可信双端点、站点门禁与断链语义（2026-08-09）

- 原生 Release 只在构建期固定的 `API_BASE_URL`（公司本地）与 `CLOUD_API_BASE_URL`（云端）之间
  选择；auto 在本地 health 可达时优先本地。Web Release 固定当前页面同源 `/api`，由受控入口或
  split-horizon DNS 决定站点，不接受绝对 API 地址或浏览器“局域网推断”。
- local 站点的 `LocalNetworkGuardFilter` 在 JWT 之前按可信代理处理后的 `remoteAddr` 对全部
  `/api/**` fail-closed，覆盖员工/访客 login、refresh 和业务请求。Filter 不直接相信调用者伪造的
  `Forwarded`/`X-Forwarded-For`。
- cloud 站点只允许 `users.remote_access=true` 的 staff：密码与账号状态校验后的 login、refresh
  轮换前、以及每个已认证请求三处都复核。visitor 是独立公网 OTP 主体，只豁免员工远程字段，仍受
  访客状态、权限、对象范围、限流和审计控制。
- 超管变更远程授权时，授权和撤权两个方向都 bump 目标 `auth_version` 并撤销全部 refresh token，
  要求重新登录。撤权后旧 access 先因版本不匹配得到 `401 UNAUTHORIZED`；旧 refresh 在 cloud 得到
  `403 REMOTE_ACCESS_DENIED` 且无新 token。客户端把后者视为精确破坏性拒绝。
- cloud 到公司主库的链路断开时，写事务返回 `503 PRIMARY_UNAVAILABLE`；staff 账号/授权版本无法
  从主库确认时可能先返回 `503 SERVICE_UNAVAILABLE`。两者都保留本地会话且不得解释为提交成功；
  客户端不排队、自动重放或合并业务写，恢复后先重读权威状态。

## 安全权衡

- **access TTL**：8 小时只记录 V75 历史；当前源码/迁移基线为 15 分钟，仍保留系统设置覆盖与最小 5。
  生产实际值必须读取目标库，不能从本 ADR 的历史段落推断。
- **entry point 返 401**：标准做法，未认证本就该 401，无新增风险。
- **权限快照随 refresh 更新**：权限变更更快生效，符合「权限变更即时生效」原则，更安全。
- **idle 阈值定时重拉**：仅拉非敏感的 `idleTimeoutMinutes`（`/api/settings/public` 本就对所有登录用户只读）。
- **瞬态故障保留令牌**：不会放宽后端授权；它只避免客户端把代理/容器 HTML、空体、未知 401、
  503/断网误判成 refresh token 已撤销。只有固定 status+code 且 CAS 命中当前记录才破坏本地会话。
- **退出撤销最终一致**：本地先 fail closed，远端撤销可以等待网络；代价是设备上短期保存加密 refresh。
  通过 32 项/30 天边界、专用存储/锁、幂等 logout 和精确删除控制，禁止扩大为业务离线队列。

## 开发构建纪律

- `mvn spring-boot:run` 与 Maven 编译/验证共享 `server/target/classes`，禁止在该开发服务运行时
  对同一工作树执行 `mvn clean`、`mvn verify` 或任何会重写 `target/classes` 的任务。
- 需要验证时先停止开发服务；验证完成后再启动。确需并行时使用独立 Git worktree/独立构建目录，
  不能共享 `target`。
- 生产环境必须运行一次构建生成的不可变版本化 JAR/镜像，不得从可变的 exploded classes 启动。

## 不做（范围控制）

- 不删/不大改 refresh 轮换 + 重用检测机制（用户选择保留）。
- 2026-07-27 当时不动 `JwtAuthFilter` catch；该范围控制已被 2026-07-30 fail-closed 修复及
  2026-08-02 服务端权限解析取代，不再是现行约束。
- 2026-07-27 当时未做多标签页 token 协调；该范围已被 2026-08-02 的 Web Locks / 有界租约和原子 token record 取代，不再是现行约束。
- 不改 idle 滑动会话设计本身（设计正确）。

## 验证与发布边界

- 2026-07-30 的历史复现已证明：共享 `server/target/classes` 被运行时构建重写会造成类链接污染；
  停止共享构建并重启后，匿名受保护接口恢复 JSON `401 + UNAUTHORIZED`。这不是本次生产发布证明。
- 2026-08-02 在新的无 `target` 隔离快照中，事故相关后端集合编译主源码 1007、测试源码 221；
  Surefire 22 类/89 项，failure 0、error 0、skipped 2。执行范围包含请求头真实 Tomcat parser、
  JWT/StaffAuthority、密码失效、logout/audit、Dashboard 与履约工作台时间戳/query/access。
- 2026-08-09 在隔离克隆库执行真实 local/cloud HTTP：未授权 local 登录 200、cloud 登录
  `403 REMOTE_ACCESS_DENIED` 且无 token；授权后 cloud 登录/refresh 200；撤权后旧 access 401、
  旧 refresh `403 REMOTE_ACCESS_DENIED` 且无替代 token，本地可重新登录；空/缺远程授权 body 不
  改值。该授权矩阵使用隔离候选并随后验证克隆迁移到 V244，不是目标生产环境放行证据。
- 两项 skipped 全部属于 `FulfillmentWorkbenchProvisionalStockPostgresTest`，因为
  `UTEN_RUN_DB_TESTS` 未设置；因此不能把 89 项结果表述成 PostgreSQL 条件路径已通过。
- Flutter 源码已有原子 token record、跨标签页协调、logout fence、撤销队列、精确拒绝、连接恢复和
  health routing 的定向测试文件；仍须以当前候选重新跑完整 Flutter analyze/test/build，不能沿用
  2026-07-30 的 108/108 或其它旧数字作为本次证明。
- 部署模板静态合同可以验证精确 health/Actuator 路由、auth/health 独立限流、原子 release 与 watchdog
  形状，但不等于真实 Nginx/systemd/容器已部署或运行。

**生产 NO-GO 门禁**：目标 PostgreSQL/Flyway 与实际 15 分钟 TTL、真实 Nginx/Tomcat header envelope、
最小 JWT 滚动窗口、多个真实浏览器标签页、Keychain/Keystore/Web secure storage 故障注入、离线退出
后撤销 drain、原生 Release 双端点、Web 同源/split DNS、公司 CIDR/可信代理、visitor 公网边界、
主库断链 503 与恢复、NAT/CGNAT 千客户端恢复波次、进程退出监督、备份/恢复/回滚、岗位 UAT 和
P95/P99 尚未完成。上述证据关闭前，本 ADR 不能批准生产。

## 关联

- [ADR-013](ADR-013-系统设置与安全策略可视化.md)：系统设置机制
- [../05-架构/安全策略.md §3.2/§3.2.5](../05-架构/安全策略.md)：token 与 idle 机制
- [../03-页面/系统设置页.md](../03-页面/系统设置页.md)：可配项表
- 实施计划：`plans/vivid-humming-lighthouse.md`
