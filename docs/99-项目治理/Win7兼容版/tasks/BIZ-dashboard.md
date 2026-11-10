# 全部业务页面迁移 / dashboard

由唯一进度登记表生成。

## W7-BIZ-042

- [ ] **工作台 / dashboard** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/dashboard/pages/dashboard_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/employee-applications-20261103.json`；`clients/windows_legacy/progress/evidence/entry-scrollbar-window-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 报销/行政财务申请：新四级报销及四类申请、负责人本人回避、独立权限/徽章/付款与打印合同已变更；原生业务仍未迁移，保持原状态及 DoD。仅公共 read-scope 识别完成本机 x86/x64 fixture，不等于业务或目标机验收。合同见 clients/windows_legacy/progress/contracts/employee-applications-workflow.json。；2026-11-03 入口页滚动栏增量：已有 DashboardView 接入 UtenEntryPageScrollBehavior，读取同源生成的 desktopStart=1280，窄屏/平板隐藏竖栏且保留触摸平移和滚轮；文档/编辑页与宽屏原栏保持。x86/x64 实际STA调用方9种宽度、400行、60次切宽、卸载恢复及编辑页隔离通过；触屏真机/Win7与完整工作台迁移仍未验，不提升本项原状态。证据 E-ENTRY-SCROLLBAR-WINDOW-20261103。；2026-11-06 任务徽章与物料准备回归。现有原生 DashboardView 读取 dashboard/overview。工作台徽章、认证范围、停留期间刷新策略仍需接入本轮共享合同。本轮未验收本原生业务或 Win7 真机。。
