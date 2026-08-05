# HR 任务中心

> 路由：`/hr/tasks`（`RouteName.hrTaskCenter`）· 实现源：`lib/features/hr_task/`（model/repository/`hr_task_count_provider`/page）
> 后端：`server/.../features/org/hrtask/`（`HrTaskController` + `HrTaskService` + `HrTaskSummary`，Pattern B 纯 JdbcTemplate）
> 入口：工作台「行政与人力资源部」分区置顶「任务中心」卡片（`WorkbenchBadgeKind.hrTask` 徽标，60s 轮询）
> 创建：2026-08-05

## 一、定位

HR 日常提醒的集中入口：**不设任务表、不落库**——所有提醒由后端按「今天」从员工档案
（入职日期 / 转正日期 / 出生日期）动态计算，结果天然随日期滚动，HR 不需要维护任何任务状态。

## 二、提醒区块与口径

| 区块 | 口径 |
|---|---|
| 转正提醒 | 预计转正日 = `hire_date` + 3 个月（`HrTaskService.PROBATION_MONTHS`）。已登记 `confirmed_at` 的员工不再提醒；逾期只跟踪近 12 个月入职者，更早未登记的聚合为「数据补录」提示条（避免上百条噪音） |
| 生日提醒 | 今日生日（含周岁）+ 30 天内（2/29 非闰年按 2/28） |
| 入职周年 | 今日入职满 N 年 |
| 新近入职 | 近 30 天入职（7 天内高亮），便于适应期跟进 |

徽标数 = 今日转正 + 逾期转正 + 今日生日 + 今日周年（`badgeCount`，与页面同源）。

- 接口：`GET /api/org/hr-tasks/summary`、`GET /api/org/hr-tasks/count`，权限 `employee:view`（与员工档案一致）。
- 行点击下钻员工详情 `/employee/{id}`；下拉/右上角刷新后同步刷新工作台徽标。
- 状态范围：`active` + `probation`（`onLeave`/离职不参与提醒）。

## 三、页面结构

四张分区卡（空分区显示空文案不隐藏）：转正提醒（逾期红 chip → 今日 → 30 天内；
底部「N 名老员工未登记转正日期」补录提示）/ 生日提醒 / 入职周年 / 新近入职。
文案硬编码中文（与 rd_task 等运维页同惯例）。

## 四、部门管理联动（同日落地）

部门管理 → 部门概览卡新增两个动作（`widget.canViewEmployees` 权限门控）：

| 动作 | 实现 |
|---|---|
| 打印花名册 | `department_roster_print.dart`：复用 `showUtenPrintPreview`（A4 横版 PDF，NotoSansSC），列为 工号/姓名/性别/部门/岗位/职级/入职日期/工龄（工龄 `work_years.dart` 按打印当天动态计算）；含下级部门全员，分页拉全（500 上限防御），排序沿用服务端「负责人→领导层→班组管理→工号」 |
| 部门架构图 | `department_org_chart_dialog.dart`：弹层缩进树（部门盒 + 负责人 + 人数 + 成员行）+「打印架构图」生成 A4 竖版 PDF（pdf 包 + `printPdfBytes`，与货品 BOM 打印同管线） |

> 待办（文档化约束）：后端需重启生效（`/api/org/hr-tasks/*` 为新端点）；前端文案如有多语言诉求再补 arb（当前与 rd_task 页面一致硬编码中文）。
