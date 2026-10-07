# ADR-164 AI 用量看板与按人限额/停用

> 2026-10-07 运行门复核：网关获得并发名额后、每次向服务商发出请求之前重新检查停用和全局/个人 token 限额；无效响应可能已消费 token，重试前同样复查。限额按已回报并记账的 token 控制，已经在途的调用不能撤回，所以它控制后续调用，不承诺单次响应恰好截断于剩余额度。连接探测仍沿用管理员独立入口的既有规则。

- 日期：2026-10-06。
- 状态：已接受(2026-10-06，服务端 + 前端 + 迁移 V815(并入 main 时由临时号 V814 改号) + 文档；零新增权限码，测试按第八节的测试计划收口)。本地源码实现(分支 `feat/ai-chat-execute-and-learn`)，没有在服务器上运行过。
- 编号：ADR-164 是开工时取的号(同分支任务A已用 ADR-163，均为临时号；main 最大 ADR-161，ADR-162 已被并行分支 `feat/permission-drawer-rework` 的「页面权限抽屉」占用)，属临时号；合并时如果撞号就顺延，同时改本文件名和引用它的文档与代码(见 §十一)。迁移开工时取临时号 V814，并入 main 时同分支任务A的迁移已改号为 V814、main 又有 V812/V813，故改号为 V815，迁移文件与本文引用已同步(§十)。
- 权限：零新增权限码(循 [ADR-150](ADR-150-AI助手页面上下文有据作答与确认后执行.md) §3、[ADR-159](ADR-159-AI助手有据作答-检索门槛目录与单据进度工具.md) 与 [ADR-163](ADR-163-AI助手直接开单通道与个人操作记忆.md) 的先例)。看板与人员详情的读=超管 + `authorization:manage` 双闸(`AiUsageAdminAccess.require`，照 ADR-133 AI 服务设置同款)；改限额/停用再叠加 `@RequiresStepUp` 再认证([ADR-110](ADR-110-服务端会话与敏感操作再认证.md))。被停用/被限额的员工不需要任何新码——拦截发生在他们既有的 `ai:use` 任务提交与模型调用里。
- 修订：无(不修订任何既有 ADR 条款)。ADR-133 的全局每日 token 预算与每人每日 60 任务/并发 2 原样保留，本 ADR 只在个人维度上加覆盖与开关；ADR-105 的 `ai_call_logs` 180 天分区留存不变，`ai_usage_daily` 是它之上的汇总层。
- 关联：ADR-133(公共 AI 平台与全局限额、`ai_call_logs`)、ADR-105(审计与日志按月分区留存)、ADR-110(step-up)、ADR-155(清空业务数据口径)、ADR-152(AI 对话设置)、ADR-153(数据不是指令)、ADR-163(同分支任务A，V816)。
- 不是知识源：本 ADR 与其它 AI 助手自身的决策一样按明确清单排除在 AI 知识检索之外(`server/pom.xml` 与 `AiDocKnowledgePolicy.EXCLUDES` 里的 `ADR-164-*.md`)；管理员与员工该知道的写在 [AI 服务设置页](../03-页面/AI服务设置页.md)。

## 一、用户要求

管理员(2026-10-06)：

1. **看得见**：每个人的 AI 消耗要能按时/日/月/年看——谁用了多少 token、调了多少次、用在什么用途上；全站今天用了多少、离预算多远。现有的「AI 使用审计」只有近 N 天逐条流水，翻流水拼不出一个人一个月用了多少。
2. **管得住**：对某个人设个人额度(每天多少 token、每天多少次任务)，超了当天就拦；对滥用的人直接停掉他的 AI 使用，停了就不能再用 AI 对话与文件识别，可随时恢复。

## 二、背景(代码核对)

1. **原料齐全、没有读口**：`ai_call_logs` 每次调用都记(成功+失败+重试)，列含 `user_id/employee_id/purpose/provider/model/ok/input_tokens/output_tokens/estimated_cost`，按月分区留存 180 天(ADR-105，归档不删)；`idx_ai_call_logs_user_created(user_id, created_at DESC)` 现成。但管理端只有 `GET /admin/ai/usage-audit` 的「近 N 天活动流水」，没有任何按人按时间序列的聚合端点。
2. **限额只有全局量**：全局每日 token 预算(`AiGateway.attempt` 里 `todayTokens()` 全局和，超了抛 `AiCallException(QUOTA)`)；每人每日任务数 60/并发 2(`AiJobService.requireWithinLimits`，提交咨询锁防并发绕过)。**无按人 token 限额、无按人停用**。
3. **停用没有载体**：账号能用的权限里没有「这个人不能用 AI」的表达；收回 `ai:use` 的路子见 §五(被否决)。
4. **管理闸已有**：`AiUsageAdminAccess.require()`=超管 + `authorization:manage` 双闸(照 ADR-133)，写操作走 `@RequiresStepUp`；`AiUsageAuditController` 已有 REPEATABLE_READ 事务与查看审计先例。
5. **用户维度**：`users.employee_id` 1:1；展示名 `coalesce(full_name, login_account)`；部门经 `employees` JOIN `departments`。

## 三、同行做法

企业 AI 管理台(Copilot 管理中心、Azure OpenAI/各 MaaS 控制台，调研出处同 ADR-150/ADR-152)的通行做法：按人用量看板(日/月/年趋势 + 按用途、按服务商分布)配按人配额与禁用开关；配额在网关/提交闸统一强制、超限用同一个错误码，不靠前端自觉；管理写操作要再认证并留审计；明细留存有限期(如 30/180 天)时用日汇总表撑更长的报表周期。共识(本 ADR 照做)：**限额与停用在服务端闸口强制**；**空配置=跟随全局默认**，不为「没设过」单建一行；**汇总层只加不减明细口径**。

## 四、决策

### 4.1 D1 数据模型(V815 两表，限额空=跟随全局)

迁移 V815 建两张表(结构与登记见 [V815 说明](../数据迁移/V815-AI用量看板与按人限额.md))：

- **`ai_user_limits`**(按人限额与停用)：`user_id` 主键(FK `users` ON DELETE CASCADE)、`disabled boolean`、`daily_token_limit bigint`(NULL 或 >0)、`daily_job_limit int`(NULL 或 >0)、`row_version`(乐观锁)、`updated_by/updated_at`。**无行=默认**(不停用、无限额)；限额列 NULL=**跟随全局**(全局每日 token 预算 / 每人每日 60 任务)，CHECK 拒绝 0 与负数——「跟随全局」是空值不是 0，0 没有合法语义。审计登记 `fn_audit_track_table('ai_user_limits','FULL','authorization',false)`(照 V670 给 `user_permission_overrides` 的先例：授权类配置表整行进审计)。
- **`ai_usage_daily`**(用量日汇总)：主键 `(user_id, usage_date)`，`calls/ok_calls/input_tokens/output_tokens`，索引 `usage_date`；**无 FK**——用户删除后统计行保留(年视图要完整)，展示名回退「已删除员工」。审计 `NONE/data_change`(纯计数，行变更由汇总任务写，显式事件见 §4.6)；表注释写明由定时任务从 `ai_call_logs` 归档汇总。
- 存量回填：同迁移内把 `ai_call_logs` 按 `(user_id, (created_at AT TIME ZONE 'Asia/Shanghai')::date)` 聚合一次性插入(ON CONFLICT DO NOTHING)，看板上线第一天就有历史。
- 清空口径：`ai_user_limits` 登记 **PRESERVE**(管理员给账号做的配置，照 `user_preferences` 口径——测试清空不该把「谁被停用/谁被限额」清掉，否则清空后停用的测试账号又恢复使用)；`ai_usage_daily` 登记 **CLEAR**(用量统计流水，照 `ai_call_logs` 口径——测试产生的假用量随测试数据清掉，不留假账)。

### 4.2 D2 按人停用：挂 `AiJobService` 提交闸(不动 security 包)

`AiJobService.submit` 与 `submitStructured` 在 `requireWithinLimits` 同处加 `limits.requireEnabled(actor.getUserId())`：`disabled` → `ApiException(FORBIDDEN, "管理员已暂停你的 AI 使用，请联系管理员。")`，经既有错误通道到用户文案。

- **为什么挂这里**：对话、文件识别、销售 intake 的**全部 AI 任务都经 `AiJobService` 提交**(与每人每日 60 任务同一道闸、同一把提交咨询锁，并发绕不过)；`AiJobWorker.holdsAiUse` 处不重复检查(提交时已拦)。
- **为什么不动 `AiChatAccessPolicy.requireChat`**：它在 `com.uten.imp.security` 包，架构边界(`ArchitectureBoundaryTest`)管着 security 包不得 import `features.*`——security 是被所有 feature 依赖的底层包，往里注入 `features.ai` 的 `AiUserLimitsService` 会造出 security→features 的反向依赖；而且 `requireChat` 只覆盖对话提交，文件识别/intake 任务不经它，挂那里既破边界又漏任务。停用是「账号级开关」，放在所有 AI 任务的公共提交闸才是全覆盖。

### 4.3 D3 按人 token 限额：挂 `AiGateway`，与全局预算同点同错码

`AiGateway.attempt` 在全局每日预算检查之后加一段：个人限额非空且 `callLogs.todayTokens(userId) >= limit` → `AiCallException(QUOTA, "今日 AI 用量已达到你的个人限额, 请明天再试或联系管理员")`。

- **同点**：与全局预算检查在同一个位置——所有真实模型调用(对话、识别、intake)都过 `AiGateway`，改一处全覆盖；probe 探测与全局预算同口径跳过。
- **同错码**：复用 `QUOTA` 类别与既有错误通道(用户看到的是同一类「今日额度已到」文案，只是说明个人限额)，不发明新错误类别。
- 配套：`AiCallLogService` 加 `todayTokens(UUID userId)`(照现有 `todayTokens()` 加 user 过滤，走 `idx_ai_call_logs_user_created`)；`AiUserLimitsService` 只提供 `Optional<Long> tokenLimit(userId)` 查询，抛错留在 Gateway(那里才有 `AiCallException`)。
- **判断时点是「用后记、超了拦下一次」**，与全局预算完全同口径，不做预扣(见 §五)。

### 4.4 D4 按人任务数覆盖

`AiJobService.requireWithinLimits` 里 `maxJobsPerUserPerDay` 一处替换为：个人 `daily_job_limit` 非空取 `max(1, override)`，否则维持 `properties.maxJobsPerUserPerDay`。并发 2 与全局队列上限不动(那两个量没有个人维度)。

### 4.5 D5 用量日汇总 rollup(180 天留存之上撑年视图)

`ai_call_logs` 只留 180 天(ADR-105 分区留存)，年视图直接查它会「只有半年还看着像全年」。补一张 `ai_usage_daily`：

- **rollup 步骤**(新 `AiUsageDailyService`，`AiJobHousekeeping.purge()` 里追加调用并计入日志，照任务A已加的 operationMemory 步骤旁，不动已有内容)：终日回填——对 `generate_series(表内最大已完成日+1, current_date-1, '1 day')` 反连接 `ai_call_logs` 聚合插入；今日部分整日重算 `ON CONFLICT (user_id, usage_date) DO UPDATE SET ...`(幂等，重复执行不重复计数)。时区一律 `Asia/Shanghai`(与 `todayTokens` 现有口径一致)。
- **今日不靠它**：限额判断与看板「今日消耗」仍实时查 `ai_call_logs`(今日行每步定时才刷新，读它会有超支窗口)；rollup 只服务 >1 天的历史窗口。
- 窗口口径：时=近 24 个整小时(`ai_call_logs` 实时聚合)；日=近 30 天(`ai_usage_daily`)；月=近 12 个自然月(rollup 按月求和)；年=近 5 个自然年。**180 天以内的日/月桶与明细一致，更早的桶来自回填+rollup**(口径同为「按调用发生日聚合」，无重复计算)。

### 4.6 D6 端点(`AiUsageAuditController` 追加；读=类级权限，写加 `@RequiresStepUp`)

- `GET /admin/ai/usage-dashboard?window=hour|day|month|year`(默认 day)：`todayTokens/dailyTokenBudget/todayCalls/activeUsersToday/disabledCount` + 窗口 `series`(bucket/label/tokens/calls/okCalls) + `people`(窗口内有用量的用户 ∪ 有 limits 行的用户，按窗口消耗降序，**上限 500**；每人带姓名/工号/部门/disabled/两档限额/今日消耗/窗口消耗与次数/最近使用时间)。事务 REPEATABLE_READ 照 usage-audit；**查看记审计 `view_ai_usage_dashboard`**(照既有 logExplicit 先例——按人聚合用量属敏感管理视图)。
- `GET /admin/ai/usage-people/{userId}?window=`：用户信息 + limits + 同款窗口序列 + `byPurpose`(窗口内按用途聚合，label 用现有人话)/`byProvider` 两分布 + `recentUses`(近 20 条，照 usage-audit 的 Use 投影精简)；用户不存在 404；查看同样记审计。
- `PUT /admin/ai/usage-people/{userId}/limits`：body `{disabled, dailyTokenLimit, dailyJobLimit, rowVersion}`；`AiUsageAdminAccess.require()` + `@RequiresStepUp`；UPSERT 带 `row_version` CAS(`expected<0` 表示首建；冲突 409「配置有变化，请刷新后再保存」，照 `AiProviderBillingService` 的先例)；成功由 save 写显式审计 `ai_user_limits.update`(detail=停用与限额变更摘要)。body 校验：disabled 布必填；limit null 或 ≥1；token 上限 10^12、任务数上限 10000。

### 4.7 D7 前端(独立看板页 + 人员详情页，从 AI 服务设置页进)

- 路由 `/admin/ai-usage` 与 `/admin/ai-usage/:userId`(照 `RoutePath.adminAuditSession` 先例)；守卫复用 `/admin/` 兜底的 `authorization:manage`，页内叠加 AI 服务设置页同款超管门禁(非超管显示「只有超级管理员…」)，不登记 `permission_by_path`、不加权限码。
- 入口：AI 服务设置页的 `AiUsageCard` 卡头加「用量与额度」按钮；从设置页 push 进入，设置页补 `ref.onPageResume` 静默刷新。`ai-feature-map.json` 随路由改动重新生成(ADR-159 的生成与逐字比对机制)。
- 看板页：KPI 四卡(今日消耗含预算进度条、今日调用、今日活跃人数、已停用人数) + 时/日/月/年窗口切换 + 趋势柱卡 + 人员表(人员/窗口消耗/今日消耗/个人限额(null 显示「跟随全局」)/状态徽章三态(正常/已超限/已停用)/最近使用；客户端分页，行点进详情)。
- 人员详情页：今日消耗环形进度(对个人限额，无限额按全站预算并注明) + 窗口趋势 + 按用途/按服务商分布 + 最近使用列表 + 已停用横幅 +「设置限额」。
- 限额编辑面板(照 ai_provider_editor 先例)：停用开关(危险语义，**开启停用二次确认**)、每日 token 限额、每日任务数限额(留空=跟随全局，helper text 常驻)、当前今日已用对照；保存带 `rowVersion`，409 提示「配置有变化，请刷新后再保存」。
- 额度语义 UI 硬约束：数值常显 + 进度双通道，≥80% warning、≥100% danger，且必带文字不只靠色；柱顶数值常显(≤30 桶)；状态徽章色+文字。

### 4.8 D8 权限、并发与审计(零新增权限码)

- 读=超管 + `authorization:manage`(`AiUsageAdminAccess.require`，非模拟身份、非锁定、非强制改密)；写再叠加 `@RequiresStepUp`。不加新码的理由同 ADR-159 §4.6：这是系统管理功能，ADR-133 已把 AI 管理面收在这对闸上，另加码只会两套口径。
- CAS：两管理员同时改同一人，后提交者 409 刷新重试，不静默覆盖。
- 审计三处：`ai_user_limits` 行级 FULL(authorization)；写操作显式 `ai_user_limits.update`；读操作显式 `view_ai_usage_dashboard`/人员详情查看——**读也记审计**(按人用量聚合能看出谁在什么时间用什么功能，属敏感管理视图；照 usage-audit「查看也记」的先例)。

## 五、备选方案

| 方案 | 不采用的原因 |
|---|---|
| 用权限 revoke(收回 `ai:use`)实现停用 | 与并行会话 V813 的 baseline 化(`ai_use_baseline_for_everyone`)纠缠——个人 override 会被 baseline 合成逻辑冲掉/要跟着版本演进走；生效链路长(权限集随会话刷新)；文案不可控(用户只看到「无权限」，不知道是被停用、找谁恢复)；把「账号级开关」塞进「页面权限」模型，两套口径永远对不齐 |
| 停用检查挂 `AiChatAccessPolicy.requireChat` | `security` 包不得依赖 `features.*`(`ArchitectureBoundaryTest` 的边界，security 是底层包)；且 `requireChat` 只覆盖对话提交，文件识别与销售 intake 任务不经它，破边界还漏任务(§4.2) |
| 年视图封顶 180 天(不做 rollup，直接查 `ai_call_logs`) | `ai_call_logs` 留存 180 天(ADR-105)，年视图会只有半年数据还显示成全年，用户明确要年视图；日汇总表每用户每天一行，成本低、口径与明细一致(§五下条) |
| 今日用量也读 rollup 表(省一次实时聚合) | 今日行随 rollup 定时刷新，读它做限额判断有超支窗口；实时查有 `idx_ai_call_logs_user_created` 现成索引，与全局预算 `todayTokens()` 同口径；rollup 只服务历史窗口(§4.5)——这是「实时查 vs rollup」的取舍：**今日实时、历史汇总** |
| 提交时预扣 token(预留额度) | 任务失败要归还、重试要续借，复杂度高；全局预算也不是这么做的，保持「用后记、超了拦下一次」同口径 |
| 给 `ai_user_limits` 加读缓存 | PK 点查，`AiChatAccessPolicy` 本就每次跑部门递归 SQL，多一查可接受；缓存引入失效问题——管理员刚点的停用必须立即生效 |
| 新增 `ai:usage:manage` 之类权限码 | 管理面复用超管+`authorization:manage` 是 ADR-133 既有口径，零新增权限码先例(ADR-150/159/163)；另加码两套口径 |
| `ai_usage_daily` 加 FK 到 users | 用户删除后统计要保留(年视图完整)，无 FK + 展示名回退「已删除员工」 |
| people 列表不设上限 | 窗口内有用量的用户 ∪ 有 limits 行的用户理论上可到全员，按窗口消耗降序截断 500——管理视角看头部用量，超限的尾部本来不进决策 |
| 停用/限额写进 `business_data_reset` 的 CLEAR 段(随测试清空) | 限额与停用是管理员对账号的配置不是测试数据，清空后「被停用的测试账号恢复使用」是安全缺口；照 `user_preferences` PRESERVE 口径(§4.1) |

## 六、安全与隐私

- **写操作三重**：`AiUsageAdminAccess.require()`(超管+`authorization:manage`+非模拟+非锁定) + `@RequiresStepUp`(输密码再认证，ADR-110 的 5 分钟一次性凭证) + `row_version` CAS(并发不覆盖)；写显式审计 `ai_user_limits.update`(变更摘要)。
- **读也记审计**：看板与人员详情查看记 `view_ai_usage_dashboard`/人员详情查看事件——按人用量聚合能还原「谁在什么时间用什么功能」，与 usage-audit 的查看同等待遇；事务 REPEATABLE_READ 保证窗口内数字自洽。
- **限额校验范围**：停用拦在 `AiJobService.submit/submitStructured`(全部 AI 任务的公共提交闸、既有咨询锁内)；按人 token 拦在 `AiGateway.attempt`(与全局预算同点，probe 同口径跳过)；按人任务数拦在 `requireWithinLimits`。提交后才被停用的账号，**已提交任务跑完但不能再提交新的**——不追溯杀运行中任务(与「清空对话记录不删已出回答」同一哲学，杀任务另立决策)。已知边界：个人 token 限额的检查-计数存在单次调用时长的竞态窗口(与全站预算同款，超限量受在途任务数与单次输出上限约束，属软目标)。
- **不外送**：看板、限额、人员详情不进任何提示词与对话；`ai_usage_daily` 只有计数无内容；停用/超限的固定文案不外送。
- **越权面**：被停用者得到的 FORBIDDEN 文案不透露是谁停的、为什么(联系管理员即可)；限额判断只查本人，不因看别人用量而扩大读面——所有按人读端点都在管理双闸后。
- **数据治理**：两表都登记 `business_data_reset`(PRESERVE/CLEAR 各随其类，§4.1)；`ai_user_limits` 行级审计 FULL；`ai_usage_daily` NONE(行由汇总任务写，异常会显形为数字对不上而不是丢审计)；无新增权限码。

## 七、后果

正面：

- 管理员第一次能看到每人时/日/月/年的 AI 消耗、全站今日对预算的进度、按用途/服务商的分布；不再翻流水拼数字。
- 「这个人每天最多用多少 token/跑多少任务」「停掉这个人的 AI」都成了页面上的操作：停用即拦提交与调用，恢复一键；限额空=跟随全局，不用给每个人配一遍。
- 限额与停用全部在服务端闸口强制(提交闸+网关)，前端只是显示；与全局预算同点同错码，用户看到的错误口径一致。

代价与限制：

- 要维护 rollup：housekeeping 多一步(终日回填+昨日/今日重算)，时区口径钉死 Asia/Shanghai；rollup 停跑超过一天时年/月视图的「昨天」会缺，直到下次跑补上(幂等，可重跑)。rollup 依赖 `AiJobHousekeeping` 调度器(`@Profile("!cloud")`)，云端 profile 下没有这个调度器，日/月/年序列停留在迁移回填快照。
- 180 天以前的年视图精度是「日汇总」，没有小时粒度、没有按用途回溯(回填只到 `ai_call_logs` 还在的 180 天；更早的历史从零开始积累)。
- 每次模型调用多一次限额点查、每次 AI 提交多一次停用点查(PK 点查，可接受，§五)。
- 运行中任务不追溯：停用后已提交的任务会跑完(§六)。
- people 上限 500：超出部分不显示(窗口消耗降序截断)。

## 八、测试计划

- 服务端单元：`AiUserLimitsServiceTest`——save 的 CAS(旧版本 409、首建 `expected<0`、并发只成一次)、校验(null 或 ≥1、token ≤10^12、job ≤10000、disabled 必填)、`requireEnabled` 的 FORBIDDEN 文案、`tokenLimit/jobLimitOverride` 空行语义。
- 挂点测试(就近加在挂点所在类的既有测试文件)：停用后 `submit`/`submitStructured` 403 且文案正确、恢复后可提交；按人任务数覆盖(override 生效、null 回落全局 60)；按人 token 超限在 `AiGateway` 抛 `QUOTA` 且与全局预算同点(probe 不触发)、`todayTokens(userId)` 只算本人当日。
- 端点测试：dashboard 四窗口的序列边界(24 整小时/30 天/12 自然月/5 自然年)、people 聚合(∪ 逻辑、500 截断、排序、今日/窗口口径)、REPEATABLE_READ、查看审计落库；人员详情 404/分布/近 20 条；PUT limits 的 409/校验/step-up 缺凭证 403/审计事件。
- rollup：幂等(重复执行计数不变)、终日回填边界(空表从 `ai_call_logs` 最早日开始)、今日整日重算、时区(23 点的调用落对日)。
- 迁移：V815 自检 DO 块(两表存在、reset 登记、锚点唯一)在真实 Postgres 迁移链上通过；回填与 180 天内明细口径一致(抽样对账)。
- 契约：`ArchitectureBoundaryTest`(security 仍不依赖 features)、`BusinessDataResetSqlContractTest` 运行时扩展登记 814(迁移头版本对由编排者统一登记)、`AiDocKnowledgePolicyTest` 打包清单比对随 §十一 排除项同步。
- 前端：`admin_ai_usage_page_test`(fake 仓储 + 守卫断言 + KPI/窗口切换/人员表/状态徽章/限额编辑含 409 与停用二次确认)、人员详情页测试(环形进度、分布、recentUses)、l10n 三语键齐备；`ai-feature-map` 重生成后 `ai_feature_map_test` 绿。

## 九、延后与不在本次范围

1. 按月/按年的**预算**(本期限额)——现在只有每日维度；要加月度预算得先定「自然月还是滚动 30 天」与超限文案，另立决策。
2. 按人限额的**提醒**(达到 80% 时给管理员/用户发通知)。
3. 停用**追溯杀运行中任务**与「停用原因」字段(现在停用即拦新提交，原因只在审计摘要里)。
4. 用量**费用**维度的按人看板(`ai_call_logs.estimated_cost` 有列，看板先只报 token 与次数，费用口径随 ADR-133 计费快照另算)。
5. rollup 提前到「小时级」汇总支撑超长时段的小时视图(现在时窗只看近 24 小时实时数据)。

## 十、迁移(V815，由临时号 V814 改号)

两张表、审计登记、reset 登记(PRESERVE/CLEAR 两个锚点各自带「计数==1 与已存在」双重守卫 + 末尾自检 DO 块，照 V816 写法)与存量回填见 [V815 说明](../数据迁移/V815-AI用量看板与按人限额.md)。开工时取临时号 V814，并入 main 时同分支任务A的迁移终号为 V816、main 又有 V812/V813/V814，故改号为 V815，本 ADR 与说明文档的引用已同步；改号时一并核对 README 头行、reset 脚本版本对、两个 ops 契约测试、migrationsExecuted、MigrationRehearsalSupport 五处无本迁移专属条目(本迁移不重写既有函数，无需三处同步)。

## 十一、文档同步与合并改号

- 本次同步：[ADR 索引](README.md)、[V815 说明](../数据迁移/V815-AI用量看板与按人限额.md)、[AI 服务设置页](../03-页面/AI服务设置页.md)(「用量与额度」入口与两个新页)、`server/pom.xml` 与 `AiDocKnowledgePolicy.EXCLUDES`(两处同步加 `99-决策记录-ADR/ADR-164-*.md`，顺序一致，排在 ADR-163 行后)。
- ADR-164 撞号顺延时改：本文件名与标题、ADR 索引「最新」与表格行、AI 服务设置页的新页小节、V815 说明文档，以及代码里的引用：`server/pom.xml` 与 `AiDocKnowledgePolicy.EXCLUDES` 的 `ADR-164-*.md`、`AiDocKnowledgePolicyTest` 里的文件名、新代码 Javadoc 中的「ADR-164」注释(`AiUserLimitsService`、`AiUsageDailyService`、`AiJobService` 停用检查、`AiGateway` 个人限额、`AiUsageAuditController` 新端点、`AiCallLogService.todayTokens(UUID)`)。
