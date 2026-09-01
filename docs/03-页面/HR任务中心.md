# HR 工作台（原「任务中心」，2026-08-05 v2 重构）

> 路由：`/hr/tasks`（工作台主页）· `/hr/tasks/:type`（事务子页：confirm/birthday/anniversary/newhire）
> 实现源：`lib/features/hr_task/`（`hr_workbench_page` / `hr_task_list_page` / `hr_task_widgets` /
> `hr_task_summary_provider` / `hr_task_count_provider` / repository）
> 后端：`server/.../features/org/hrtask/`（`HrTaskController` + `HrTaskService` + `HrTaskClaimService`，
> Pattern B 纯 JdbcTemplate；认领走 `hr_task_claims` 表）
> 入口：工作台「行政与人力资源部」分区置顶「任务中心」卡片（`WorkbenchBadgeKind.hrTask` 徽标，60s 轮询）
> 决策：[ADR-021](../99-决策记录-ADR/ADR-021-人事域完善-转正车辆多联系方式与任务软认领.md)

## 一、定位

HR 日常事务的集中办理台：提醒仍由后端按「今天」从员工档案动态计算（不落任务表），
v2 解决 v1「四块平铺一页、内容太多、没有快捷操作、多人重复办理」三个问题：

1. **工作台化**：主页 = 今日概览统计卡 + 我处理中的事项 + 事务入口；每类事务独立子页面；
2. **快捷操作**：转正办理行内一键「登记转正」（日期默认今天可改）；
3. **软认领防重复**：任务显示「XXX 处理中」，他人快捷操作禁用（见 §五）。

## 二、页面结构

### 主页（`/hr/tasks`）

| 区块 | 内容 |
|---|---|
| 今日概览 | 4 张统计卡：转正待办（今日+逾期）/ 今日生日 / 今日周年 / 新入职（近 30 天）；点击进对应子页 |
| 我处理中的事项 | 跨区块汇总我认领的任务（最多 5 条 + 计数），可继续处理/释放 |
| 事务办理 | 4 个入口卡（图标 + 计数 + 口径说明）→ 子页 |
| 数据补录提示 | 入职满一年仍未登记转正日期的人数（V210 回填后应为 0） |

### 子页（`/hr/tasks/:type`）

列表 + 行内操作：点行进员工详情；认领/释放/接管图标；「登记转正」按钮（仅转正类、
`employee:edit`）。转正口径 = 入职 + 3 个月（`HrTaskService.PROBATION_MONTHS`）；
试用期员工调 `/confirm`（写 `employment_history` confirm 事件）；服务端回 409（已是正式员工
但未登记转正日期）时前端自动改为 `PUT /{id}` 补登 `confirmedAt`。

## 三、提醒区块与口径（沿用 v1）

| 区块 | 口径 |
|---|---|
| 转正提醒 | 预计转正日 = `hire_date` + 3 个月。已登记 `confirmed_at` 不再提醒；逾期只跟踪近 12 个月入职者，更早聚合为补录提示 |
| 生日提醒 | 今日生日（含周岁）+ 30 天内（2/29 非闰年按 2/28） |
| 入职周年 | 今日入职满 N 年 |
| 新近入职 | 近 30 天入职（7 天内高亮） |

徽标数 = 今日转正 + 逾期转正 + 今日生日 + 今日周年。接口：
`GET /api/org/hr-tasks/summary`、`GET /api/org/hr-tasks/count`，权限 `employee:view`。
状态范围：`active` + `probation`。

> 2026-08-17 补充：从子页点「送祝福」跳通知发布页发布祝福后，任务列表若仍保活在栈下，「未祝福」标记不会自己更新——现发布页在祝福类发布成功后同步 `hrTaskSummaryProvider.reloadSilently()`，返回子页即见「已祝福」，角标同步减。

> 2026-08-06 升级（ADR-026）：①顶部 4 张统计卡改为**≈72dp 紧凑磁贴**（图标+数字同行、标签下行，固定高度不随屏宽漂移）；②「快捷发布祝福」**移入对应子页**——生日/周年子页顶部「一键全部送祝福」（`POST /notices/celebration/batch`，默认模板+去重）+ 每行「送祝福」（预填对象进发布页），主页仅保留通用/新婚/新生儿精简行；③发布祝福后**角标即减**——`HrTaskService` 标记本类型本年已祝福者为 `blessed`，徽标按未祝福计数；④祝福对象改选标题残留 bug 已修（见[通知发布页](通知发布页.md)）。

## 四、转正日期口径（ADR-021 §一）

- 老数据：V210 已把 `confirmed_at IS NULL` 的非试用期员工回填为入职日期；
  名录重迁移脚本同口径（批注优先，否则=入职日期）。
- 新数据：入职「正式」必填转正日期；「试用」走本工作台到期办理。
- 详见 [74-转正日期回填与员工车辆联系方式](../数据迁移/74-转正日期回填与员工车辆联系方式.md)。

## 五、任务软认领（Soft Claim）

**调研结论**（Jira / 钉钉审批 / 飞书工单 / Zendesk 等工单与审批系统）：
业界主流**不隐藏**他人处理中的任务，而是显示处理人并阻止他人重复操作；
隐藏会导致工作不可见、被重复创建、卡住无人发现。本系统按此设计：

| 规则 | 行为 |
|---|---|
| 可见性 | 任务始终对所有人可见；被认领的行显示「XXX 处理中」徽标 |
| 防重复 | 他人认领中的行：「登记转正」禁用（锁图标提示处理人） |
| 认领 | 点认领图标即认领（幂等：自己重复认领 = 续租 24h）；他人已认领 = 409 |
| 租约 | 24 小时（`lease_until`），过期读取时惰性失效，无需定时任务/人工释放 |
| 释放 | 本人可释放；持 `employee:edit` 者可释放他人认领 |
| 接管 | 持 `employee:edit` 者可「接管」：原认领强制释放并转由我认领（防认领人请假卡死） |

接口：`POST /api/org/hr-tasks/claims`（body: taskType+employeeId）、
`DELETE /api/org/hr-tasks/claims/{taskType}/{employeeId}`、
`POST .../takeover`。taskType = confirm/birthday/anniversary/newhire。
认领状态存 `hr_task_claims`（V210，部分唯一索引 + 审计触发器），任务本体仍动态计算。

## 六、前端数据流

`hrTaskSummaryProvider`（AsyncNotifier）一次加载，主页与各子页共享；
快捷操作/认领操作后 `reloadSilently()` 静默重取并同步工作台徽标
（`hrTaskCountProvider` 60s 轮询保留）。文案硬编码中文（与 rd_task 等运维页同惯例）。

## 七、部门管理联动

部门管理 → 部门概览卡两个动作（均 `employee:view` 门控）：

| 动作 | 实现 |
|---|---|
| 打印花名册 | **需 `employee:export`（V210 新权限点，无权限隐藏）**；A4 横版 PDF，含下级部门全员 |
| 部门架构图 | v2 重构（ADR-021 §七）：节点卡片化 + 引导线层级 + 负责人归入班组（非直属标挂职）+ 成员领导徽章 + 节点折叠；弹层内「打印架构图」同样需 `employee:export` |

> 待办（文档化约束）：后端需重启生效（`/api/org/hr-tasks/claims*` 与 V210/V211 为新端点/新迁移）；
> 前端文案如有多语言诉求再补 arb。

**最后更新**：2026-08-05 · **状态**：工作台/子页/软认领/快捷转正已接入源码并通过后端编译；
目标库 V210/V211、运行实例重启与多账号协同 E2E 待验收。
