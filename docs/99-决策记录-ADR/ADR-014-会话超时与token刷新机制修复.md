# ADR-014：会话超时与 token 刷新机制修复

> 日期：2026-07-27 · 状态：已实施；2026-07-30 完成瞬态故障误登出补强与运行时冒烟
> 前置：[ADR-013](ADR-013-系统设置与安全策略可视化.md)（系统设置）· 原则：安全首位、最小权限、深度防御
>
> **2026-07-30 现行口径**：本 ADR 保留 V75 当时“480 分钟铺底”的历史决策，但它不再是文档安全基线。
> `application.yml` 与 `JwtService.readLong(..., 15)` 的源码回退值为 15 分钟；目标库
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

## 决策（4 项修复）

### 1. 后端过期/匿名 → 统一返 401（症状 B 根本修复）

`SecurityConfig.filterChain` 加 `.exceptionHandling(e -> e.authenticationEntryPoint(...))`：过期/缺失/伪造 token、匿名访问受保护资源 → **401 + `ApiError(UNAUTHORIZED)`**。前端识别 401 → 自动 refresh + 重试（**用户无感**）。

- permitAll 路径（login/refresh/health/访客）不受影响。
- 「账号锁定/停用」仍走 `JwtAuthFilter.writeUnauthorized` 主动 401，不冲突。
- 「有效 token 但权限不足」仍走 `GlobalExceptionHandler.handleAccessDenied` 返 403 FORBIDDEN（真无权限），语义不变。

### 2. access TTL 重新开放为系统设置可调项（V75）

V74 曾删 `jwt_access_ttl_minutes`（怕误调破坏刷新）。V75 重新插入，默认 **480（8 小时）**，label「登录令牌有效期」。`JwtService.issueAccess/getAccessTtlSeconds` 早已 `readLong("jwt_access_ttl_minutes",15)`，**后端零代码改动**，迁移落库自动生效。`SystemSettingsService.validate` 加最小值 5 校验（防误设 0/1 致登录即过期）。

### 3. 前端权限快照随 access 刷新滑动更新

`SessionEventBus` 加 `publishProfile(userJson)` 事件（用 `Map` 而非 `UserProfile` 类型，避免 core 层反向依赖 features/auth/model）；`AuthInterceptor._refresh` 成功后解析 `data['user']` 并发布；`sessionProvider` 监听 `onProfileRefreshed` 更新 `state.user`。效果：权限变更随刷新即时生效，不必重登；access 改长后也不会让权限生效延迟恶化。

### 4. 前端 idle 阈值实时刷新（症状 A 修复）

`IdleTimeoutGuard` 三管齐下：① 进系统拉一次；② 每 5 分钟 `Timer.periodic` 轮询；③ 监听 `idleThresholdVersionProvider`（StateProvider<int>）信号——超管在「系统设置」保存 `session_idle_timeout_minutes` 后自增，立即重拉（当前会话即时生效，不必重登）。`_check` 改秒级判定（`inSeconds >= threshold*60`）让 1 分钟等小阈值精确。

### 5. 瞬态故障不得升级为退出登录（2026-07-30）

原 `AuthInterceptor` 把 refresh 的 401、5xx、断网、超时和响应解析错误全部压成 `null`，
随后无条件清理 access/refresh token；刷新成功后的业务重放只要出现 403、5xx 或网络错误也会
无条件清会话。`SessionEventBus` 因此把一次后端部署/类加载故障放大成用户直接退出。

现行实现使用共享 `TokenRefreshResult` 明确区分：

- `refreshed`：保存新令牌、同步最新用户权限快照并重放原请求；
- `rejected`：仅本地没有 refresh token，或刷新接口明确返回 400/401/422 时清理会话；
- `unavailable`：403、429、5xx、网络/超时和异常响应都保留令牌并传播真实错误，允许后续重试。

刷新成功后的业务重放无论返回 401、403、5xx 或网络异常，都不直接销毁会话；账号确实被停用、
锁定或 refresh token 被撤销时，下一次刷新会由刷新接口明确返回 401，再执行 fail closed 退出。
访客拦截器和应用启动恢复采用同一规则。`SessionNotifier` 的两个全局事件订阅也会随 Provider
释放，避免测试、热重载或容器重建时累积监听器。

生产调度页原先会在 `TabBarView` 首次构建时同时加载待排产、进行中、已完成三个 Tab，共触发
1 个待排产请求和两组各 3 个进度请求。现在只加载当前可见 Tab：进入待排产由 7 个首批请求降为
1 个；切换到进度 Tab 时才加载该 Tab 的 3 个查询，既降低首屏延迟，也避免并发 401 放大故障。

## 安全权衡

- **access TTL 改长（15 分 → 8 小时）**：token 泄露可滥用窗口变长。缓解三重：① idle timeout（30 分无操作）登出清 token；② refresh 重用检测仍生效；③ TTL 可调，管理员可按需调短；④ 最小值 5 校验防误设。用户已知悉并选择此方向。
- **entry point 返 401**：标准做法，未认证本就该 401，无新增风险。
- **权限快照随 refresh 更新**：权限变更更快生效，符合「权限变更即时生效」原则，更安全。
- **idle 阈值定时重拉**：仅拉非敏感的 `idleTimeoutMinutes`（`/api/settings/public` 本就对所有登录用户只读）。
- **瞬态故障保留令牌**：不会放宽后端授权；后端仍逐请求拒绝无效 access。它只避免客户端把
  5xx/断网错误误判成 refresh token 已撤销。明确的刷新 400/401/422 仍会立即清理本地会话。

## 开发构建纪律

- `mvn spring-boot:run` 与 Maven 编译/验证共享 `server/target/classes`，禁止在该开发服务运行时
  对同一工作树执行 `mvn clean`、`mvn verify` 或任何会重写 `target/classes` 的任务。
- 需要验证时先停止开发服务；验证完成后再启动。确需并行时使用独立 Git worktree/独立构建目录，
  不能共享 `target`。
- 生产环境必须运行一次构建生成的不可变版本化 JAR/镜像，不得从可变的 exploded classes 启动。

## 不做（范围控制）

- 不删/不大改 refresh 轮换 + 重用检测机制（用户选择保留）。
- 不动 `JwtAuthFilter` catch 放行逻辑（配 entry point 后链路自洽）。
- 不做多 tab token 同步（Web storage 事件，独立问题）。
- 不改 idle 滑动会话设计本身（设计正确）。

## 验证

- 当前后端完整门禁：178/178；PostgreSQL 16 空库与开发库均校验 128 个迁移至 V147。
- 2026-07-30 重启受污染的开发后端后，`/api/production/schedule/pending` 与
  `/api/production/plans/progress` 的匿名访问均稳定返回 JSON
  `401 + UNAUTHORIZED`，不再出现 `ErrorCode` 类加载错误或 HTML 401。
- refresh/重放/启动恢复新增 18 个定向测试：缺 refresh/明确 401 清会话；403/429/5xx/超时保留会话；
  重放 401/403/500 保留新令牌；并发 401 只刷新一次；畸形 200 不删令牌；访客同型行为一致。
- `dart format` 427 文件零变化，`flutter analyze --no-pub` 0 issue，
  `flutter test --no-pub` 108/108。
- idle=1 分钟弹窗、系统设置 TTL 修改及真实浏览器长会话仍须在目标发布环境完成最终 E2E。

## 关联

- [ADR-013](ADR-013-系统设置与安全策略可视化.md)：系统设置机制
- [../05-架构/安全策略.md §3.2/§3.2.5](../05-架构/安全策略.md)：token 与 idle 机制
- [../03-页面/系统设置页.md](../03-页面/系统设置页.md)：可配项表
- 实施计划：`plans/vivid-humming-lighthouse.md`
