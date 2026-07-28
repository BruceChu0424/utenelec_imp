# ADR-014：会话超时与 token 刷新机制修复

> 日期：2026-07-27 · 状态：已实施（mvn test 6 过 / flutter analyze 0 error；运行时冒烟待重启后端）
> 前置：[ADR-013](ADR-013-系统设置与安全策略可视化.md)（系统设置）· 原则：安全首位、最小权限、深度防御

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

## 安全权衡

- **access TTL 改长（15 分 → 8 小时）**：token 泄露可滥用窗口变长。缓解三重：① idle timeout（30 分无操作）登出清 token；② refresh 重用检测仍生效；③ TTL 可调，管理员可按需调短；④ 最小值 5 校验防误设。用户已知悉并选择此方向。
- **entry point 返 401**：标准做法，未认证本就该 401，无新增风险。
- **权限快照随 refresh 更新**：权限变更更快生效，符合「权限变更即时生效」原则，更安全。
- **idle 阈值定时重拉**：仅拉非敏感的 `idleTimeoutMinutes`（`/api/settings/public` 本就对所有登录用户只读）。

## 不做（范围控制）

- 不删/不大改 refresh 轮换 + 重用检测机制（用户选择保留）。
- 不动 `JwtAuthFilter` catch 放行逻辑（配 entry point 后链路自洽）。
- 不做多 tab token 同步（Web storage 事件，独立问题）。
- 不改 idle 滑动会话设计本身（设计正确）。

## 验证

- 后端 `mvn test` 6 过 BUILD SUCCESS；`flutter analyze` 0 error。
- V75 启动后端自动迁移（Flyway）。
- 运行时冒烟（待重启后端）：① 改 idle=1 分不操作约 60s 弹窗 + 当前会话即时生效；② 持续用 15+ 分不再出现「无权限」；③ 系统设置页「登录令牌有效期」可改（默认 480，最小 5）。

## 关联

- [ADR-013](ADR-013-系统设置与安全策略可视化.md)：系统设置机制
- [../05-架构/安全策略.md §3.2/§3.2.5](../05-架构/安全策略.md)：token 与 idle 机制
- [../03-页面/系统设置页.md](../03-页面/系统设置页.md)：可配项表
- 实施计划：`plans/vivid-humming-lighthouse.md`
