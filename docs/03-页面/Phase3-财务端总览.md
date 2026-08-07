# Phase 3 — 财务端总览

> **⚠️ 2026-07-24 权限模型重构**：角色体系已下线（[ADR-011](../99-决策记录-ADR/ADR-011-工作台部门分区与动态权限配置.md)）。本文中"按角色分权/角色端"的表述仅作历史参考——现行权限 = 全员基础 ∪ 部门配置（含上级部门）± 个人覆盖，由超管在权限管理页按部门配置。


> **财务端**总纲。当前登记 6 类页面/入口：报销审批（列表+详情）、工资条审核、财务报表、资产与待摊专业工作台、采购/委外订货与超量审批任务。
> 全部复用 [全局机制](../05-架构/全局机制.md) 的**审批流**与**视角选择器**。
> 上层：[页面总览](页面总览.md)。
>
> 📍 **现状（2026-08-01）**：钱流单据与财务报表使用真实后端；员工报销和工资前端已切 Dio，
> V133 已建立独立领域结构，审批/支付/发布 API 和报销付款会计副作用已有源码实现，但
> 服务端分页也已有源码；审批口径、权限职责分离、长周期容量、真实数据库与 E2E 仍待生产验收。
> `/api/finance/expenses` 是一般费用单，不是员工报销申请。财务数据还受历史委外发料、总账开账和材料结转阻断约束。
> 资产与待摊已交付 V183 专业安全骨架及 CORPORATE 月度批次，但核心落账门禁默认关闭，完整生命周期
> **NO-GO**；详见[专项验收报告](../99-项目治理/2026-08-01-资产与待摊全链路实现与验收报告.md)。
>
> **2026-08-02 ADR-019 后置口径**（**2026-08-07 ADR-027 再覆盖**）：财务端新增订货审批任务、超量到货审批。采购/委外订货保存后立即送财务审批审核组——财务部门(DEPT_FIN 及子树)持 `finance_order_approval:review` 的员工(+跨部门点名加授)，由 `WorkflowReviewerEligibility` 实时查库判定；只有合格审核人通过才令订单 `status=1` 并形成预计到货，财务只读查看关联订单。超量收货先不写库存/AP，由审核组全批、自定义或不批，批准量交仓库再审，未批量只交原下单人退回。V229 删除「审批负责人设置」入口、`workflow_assignment:manage` 与 `workflow_responsibility_assignments` 表，不再单点配置负责人；超管不在财务部且未点名不可代审。
> V202 是全部 `public` 业务表审计 sweep。公司目标库仍只确认到 V190，V196–V202 仅源码候选，真实职责分离/实物 UAT、完整 IQC 与发布签字未完成，生产 **NO-GO**。


---

## 一、定位

finance 在**桌面端**处理：审批员工报销、审核 hr 生成的工资条、出报表、管钱流（收付款/对帐/账户流水）。手机端做移动审批。

## 二、页面清单

| # | 页面 | 路由 | 文档 | 状态 |
|---|---|---|---|---|
| 1 | 员工报销审批列表 | `/expense/approval` | [报销审批列表页.md](报销审批列表页.md) | 🟡 真实 API 与服务端分页源码已接，待容量/权限/E2E 验收 |
| 2 | 员工报销审批详情 | `/expense/approval/:id` | [报销审批详情页.md](报销审批详情页.md) | 🟡 单阶段审批和事务化付款已有源码，待会计/E2E 验收 |
| 3 | 工资条审核 | `/payroll/review` | [工资条审核页.md](工资条审核页.md) | 🟡 状态机与分页已有源码，待职责分离/容量/E2E 验收 |
| 4 | 财务报表（22 报表 5 卡 + 钱流管理 hub） | `/finance`、`/finance/report` | [财务报表页.md](财务报表页.md) | ✅ 真实后端（[doc26](../数据迁移/)） |
| 5 | 资产与待摊专业工作台 | `/finance/assets` | [资产与待摊管理页.md](资产与待摊管理页.md) | 🟡 安全骨架/月度不可变批次已交付；核心落账默认关闭，完整生产 NO-GO |
| 6 | 采购/委外订货与超量审批任务 | `/finance/procurement-approvals`、`/finance/procurement-arrival-exceptions` | [生产履约任务工作台.md §4.4](生产履约任务工作台.md#44-财务任务负责人设置与未来入库) | 🟡 V196–V202 源码候选；审批人为财务部门持 `finance_order_approval:review` 的审核组（+跨部门点名加授） |

> **钱流管理**（销售收款/采购付款/一般费用/其它收入/银行存取款 + 应收应付台账 + 往来对帐 + 账户流水 + 账户/收付款类别主档）以独立业务模块形式落地，路由前缀 `/finance`；hub 同时聚合本人订货审批、超量审批任务。审批权在权限管理授权 `finance_order_approval:review`（V229/ADR-027）。通知只提醒，任务投影才是权威。

## 三、角色权限（历史参考，已下线）

| 页面 | finance | manager | admin | 其他 |
|---|---|---|---|---|
| 报销审批 | ✅ 审批 | ✅ 只读 | ✅ | ❌ |
| 工资条审核 | ✅ 审核 | ✅ 只读 | ✅ | ❌ |
| 财务报表 | ✅ | ✅ 只读 | ✅ | ❌ |

权限点：`expense:approve` / `expense:pay`、`payroll:generate` / `payroll:review` / `payroll:publish` /
`payroll:view:all`、`finance_report:view` / `finance_report:export`、`finance_shipment_audit`
（销售发货财务审核）、`ar_ap:*` / `bank_account:*`（详见权限管理页目录，按部门/个人配置）。
采购工作流另用 `finance_order_approval:view`、`finance_order_approval:review`；审批人为财务部门持
`finance_order_approval:review` 的审核组（+跨部门点名加授），超级管理员不在财务部且未点名不可代审（V229/ADR-027）。
查看钱流报表不能替代报销打款、工资发布或发货审核权限；V136 已把 `expense:pay` 写入财税部现行
`department_permissions`，不能依赖已下线的角色授权。V201 仅为财务关联任务补采购/委外订单 view，不授 edit。

资产工作流单独使用 `finance_asset:view/edit/approve/post/dispose/export` 与
`finance_asset_period:manage`。V183 只给 `DEPT_FIN` 默认授予 view/edit；approve/post/dispose/
export/period manage 均须个人点名授权，不能因为拥有 `finance_report:view` 自动获得。

## 四、资产与待摊专业子账

- 页面不是旧的固定资产/待摊双 Tab CRUD，而是概览、固定资产、长期待摊、月结过账四区；
- 主档和月度批次动作取“本地权限 ∩ 服务端 `allowedActions`”，本人不得自审或执行本人发起的最终过账；
- 月度流程为预览 → 提交 → 他人审批 → 过账；错误创建正常反向批次，保留原批次、原日志和原凭证；
- `UTEN_FINANCE_ASSET_POSTED_WORKFLOWS_ENABLED=false` 时，激活/初始确认、处置批准和提前终止批准
  在服务端 fail-closed；补齐类别或科目不能解除该门禁；
- 当前允许在非生产/UAT 准备类别、草稿、提交和他人审批/驳回，并用隔离数据验证月度引擎；不得录入
  真实资产后绕过门禁，也不得把正常月度反冲描述成资本化/处置/终止事件反冲。

完整流程、API 和阻断清单见
[51 · 资产与待摊专业化全链路](../数据迁移/51-资产与待摊专业化全链路.md)。

## 五、当前审批流

- 报销：`DRAFT → SUBMITTED → APPROVED/REJECTED → PAID`。当前是单阶段审批；付款在同一事务内扣减账户并生成费用、对账和总账记录。页面时间线由报销单时间字段合成，没有通用 `ApprovalRecord`。
- 工资：`DRAFT → SUBMITTED → APPROVED/REJECTED → PUBLISHED`。工资条在草稿创建时生成，发布后才对员工可见；驳回为终态。
- 两类状态变更均使用后端行锁，但仍须验证真实数据库并发和权限矩阵。详见 [全局机制 §3.3](../05-架构/全局机制.md#33-报销审批流expenseclaim) 与 [§3.4](../05-架构/全局机制.md#34-工资条审批流payrollslip--payrollbatch)。

## 六、视角选择器

`ViewContextProvider` 仍是规划能力；当前不得宣称报销、工资和财务报表已经统一跟随视角切换。

## 七、依赖组件

财务报表使用 `MasterDataTableView`（统一表格：列排序 + autofilter + 加密导出，[文档](../02-组件库/MasterDataTableView.md)）与 `UtenExportButton`；报销/工资当前使用 `UtenPagedGrid`、`UtenCard`、`UtenStatusBadge`、`UtenBottomActionBar` 和自有状态时间线。钱流主档使用 `UtenCategoryTreeView`。

---

**最后更新**：2026-08-02 · **状态**：钱流/报表真实；V196–V202 订货/超量任务与负责人设置为源码候选、目标库仍 V190；资产完整生命周期、采购/委外 IQC、真实职责分离/实物 UAT 和发布签字均 NO-GO
