# 全部业务页面迁移 / finance

由唯一进度登记表生成。

## W7-BIZ-057

- [ ] **财务 / finance account flow** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_account_flow_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy、export、post、print、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`docs/99-项目治理/2026-11-01-财务钱流全分类数据与导出审计.md`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`。

接续/限制：2026-11-01：财务数据审计修复Flutter账户旧查询金额归属、银行明细/汇总真实取数与导出；后端共享权限/筛选/金额契约已更新，本WPF页面仍未迁移，接入要求见本次审计记录。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。。

## W7-BIZ-230

- [ ] **财务 / finance application continuation** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_application_continuation_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：complete、post、restore（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-231

- [ ] **财务 / finance application edit** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_application_edit_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：complete、edit、post、remove、restore、save（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-232

- [ ] **财务 / finance application settings** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_application_settings_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：edit、post、save（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-233

- [ ] **财务 / finance applications** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_applications_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：close、create（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-058

- [ ] **财务 / finance ar ap overview** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_ar_ap_overview_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：cancel、copy、export、post、print、remove、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。。

## W7-BIZ-059

- [ ] **财务 / finance ar ap** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_ar_ap_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：post（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-060

- [ ] **财务 / finance asset workbench** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_asset_workbench_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：complete、copy、create（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/category-loading-closeout-20261101.json`。

接续/限制：2026-11-01 Flutter/Web 资产工作台补齐可见页签刷新、独立草稿计数、期间输入保留、读取归属和迟到响应围栏。本业务的 WPF UI 仍未迁移；同步时须保留同一统计/权限/版本/未知提交及懒加载门槛，不以公共传输编译代替完成。见 E-CATEGORY-LOADING-CLOSEOUT-20261101。。

## W7-BIZ-061

- [ ] **财务 / finance assets** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_assets_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
5. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
6. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
7. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
8. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-062

- [ ] **财务 / finance audit center** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_audit_center_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：audit、complete、copy（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/review-layout-and-refresh-20261101.json`；`clients/windows_legacy/progress/evidence/category-prefetch-sweep-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-01 补充：审核页悬浮动作/顶栏刷新、财务小类徽章同源、销售编辑返回认领刷新循环的客户端公共分类合同已修复；本 WPF 页面仍未迁移。详见docs/99-项目治理/2026-11-01-订单复审刷新循环与审核布局补充.md。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。。

## W7-BIZ-063

- [ ] **财务 / finance doc detail** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_doc_detail_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：approve、confirm、copy、delete、post、reverse（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`；`clients/windows_legacy/progress/evidence/internal-feedback-20261104.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。；2026-11-05 内部测试反馈（E-INTERNAL-FEEDBACK-20261104）：财务单据详情须迁移服务端生成的真实出货来源type/id/no与原应收编号区别、可选订单辅助来源及原币/费用/银行净到账的独立金额；冻结事实及反向历史不可由当前客户累计改写，金融字段继续按原单据/金额权限显示。 WPF本项保持todo，原owner/DoD/依赖/nativeTargets保留，Flutter/后端检查不构成本项或Win7验收。；2026-11-05 真UAT最终合同（E-INTERNAL-FEEDBACK-20261104）：财务单据详情须迁移服务端生成的真实出货来源type/id/no与原应收编号区别、可选订单辅助来源及原币/费用/银行净到账的独立金额；冻结事实及反向历史不可由当前客户累计改写，金融字段继续按原单据/金额权限显示。 真UAT补足：收/付款详情使用已授权DTO有限clientName/supplierName，不因缺主档查看而丢本单名字；保留原4财务金额名，现有状态同排标待审核/已审核/历史金额，紧邻hint说明本收款单结算批次（可多出货）、草稿不计系统流水或出货已收、毛额与银行净到账各自保留。 WPF保持todo；未修改原owner/DoD/依赖/nativeTargets，真实HTTP/Flutter结果不是原生验收。。

## W7-BIZ-064

- [ ] **财务 / finance doc edit** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_doc_edit_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：audit、complete、confirm、copy、create、edit、export、finish、import、post、restore、save、start、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/business-auxiliary-references-20261101.json`；`clients/windows_legacy/progress/evidence/finance-batch-entry-20261102.json`；`clients/windows_legacy/progress/evidence/party-master-hidden-20261103.json`；`clients/windows_legacy/progress/contracts/party-master-hidden.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`；`clients/windows_legacy/progress/evidence/internal-feedback-20261104.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-01 业务辅助选择改用已有业务动作授权的最小引用，人员仅工号、姓名、部门、职位；本次未实施或验收此WPF任务的原生增量，既有状态与DoD保留。见业务辅助引用证据及治理记录。；2026-11-02 钱流五类新建改为逐行往来单位/账户/方式/币种及同条件自动合单；新增 /api/finance/{seg}/batch 原子幂等合同，流水号选填、数量单价金额公共联动。WPF尚未迁移；不开放写入口，不据Flutter/后端结果标记本任务完成。接手须复用 contracts/finance-entry-grouping-v1.json、服务端分组与金额权威、整批回滚、未知提交及附件恢复。源码与验证边界见finance-batch-entry-20261102证据。；2026-11-03 客户/供应商资料删除确认仅设置 is_hidden，主档与新业务选择隐藏；is_deleted/status/UUID、旧单据及既有往来保留。引用提醒按 confirmationRequired 给“去查看/仍然删除”，重提只含确认子集并保留版本；权限/版本失败不得强制。负责人“未分配”用同源 Uten.Error 红色。原生页面及相关业务选择/历史筛选尚未迁移，保持 todo，不开放占位写入口；接入合同见 clients/windows_legacy/progress/contracts/party-master-hidden.json。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。；2026-11-05 内部测试反馈（E-INTERNAL-FEEDBACK-20261104）：收款录入须以明确选择的实际出货AR批次为主，新行本次金额留空且必填，普通NULL订单合法、不跨批自动挑款；订单预收（定金/多付）单独引用订单，履约完成可记真实多付，中止/撤销新定金仍拒绝。复用有限来源scope，保留财务交接原绑定、服务端来源快照、草稿/未知提交/同键恢复与200货款-10费用=190净到账；实际审核拒未来银行时间。界面连续一表，800px/手机全宽设置及固定右底操作、附加还欠末列均尚待原生迁移。 来源选择器须固定全宽底栏（摘要左、取消/引用右，手机分行），完整模式名称和审核前还欠不提前扣减提示同步。 WPF本项保持todo，原owner/DoD/依赖/nativeTargets保留，Flutter/后端检查不构成本项或Win7验收。；2026-11-05 真UAT最终合同（E-INTERNAL-FEEDBACK-20261104）：收款录入须以明确选择的实际出货AR批次为主，新行本次金额留空且必填，普通NULL订单合法、不跨批自动挑款；订单预收（定金/多付）单独引用订单，履约完成可记真实多付，中止/撤销新定金仍拒绝。复用有限来源scope，保留财务交接原绑定、服务端来源快照、草稿/未知提交/同键恢复与200货款-10费用=190净到账；实际审核拒未来银行时间。界面连续一表，800px/手机全宽设置及固定右底操作、附加还欠末列均尚待原生迁移。 来源选择器须固定全宽底栏（摘要左、取消/引用右，手机分行），完整模式名称和审核前还欠不提前扣减提示同步。 真UAT补足：原编辑优先本单DTO姓名并随真实party UUID变化失效，草稿保留原标签、不扩大新选；非转账收付款方式仅字典有选项才标必填，费用/收入style沿真实保存必填元数据。 WPF保持todo；未修改原owner/DoD/依赖/nativeTargets，真实HTTP/Flutter结果不是原生验收。。

## W7-BIZ-065

- [ ] **财务 / finance doc list** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_doc_list_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：create、delete、post（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`；`clients/windows_legacy/progress/evidence/internal-feedback-20261104.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。；2026-11-05 真UAT最终合同（E-INTERNAL-FEEDBACK-20261104）：财务收/付款列表须优先读取已授权单据DTO的clientName/supplierName；服务端先财务对象范围，再按本页真实FK有界批量解引用，仅id/name、不N+1、不放宽客户主档owner范围或供应商PII。隐藏/停用旧引用保持名称，缺值沿旧未知回退，不冒充可新选主档；同一入口同步详情与原编辑。 WPF保持todo；未修改原owner/DoD/依赖/nativeTargets，真实HTTP/Flutter结果不是原生验收。。

## W7-BIZ-066

- [ ] **财务 / finance hub** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_hub_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：audit、copy（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/employee-applications-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 报销/行政财务申请：新四级报销及四类申请、负责人本人回避、独立权限/徽章/付款与打印合同已变更；原生业务仍未迁移，保持原状态及 DoD。仅公共 read-scope 识别完成本机 x86/x64 fixture，不等于业务或目标机验收。合同见 clients/windows_legacy/progress/contracts/employee-applications-workflow.json。。

## W7-BIZ-067

- [ ] **财务 / finance procurement approval review** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_procurement_approval_review_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：approve、close、confirm、copy、dispatch、finish、post、reject、remove、restore、start、submit（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-068

- [ ] **财务 / finance procurement approval tasks** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_procurement_approval_tasks_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：approve、complete、issue、post、reject、remove（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/category-prefetch-sweep-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。。

## W7-BIZ-069

- [ ] **财务 / finance quote review list** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_quote_review_list_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy、post（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/category-prefetch-sweep-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。。

## W7-BIZ-070

- [ ] **财务 / finance quote review** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_quote_review_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：cancel、close、confirm、copy、dispatch、edit、finish、post、remove、restore、save、start、submit（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：2026-10-31 报价审核新增负责人前置阶段，Flutter 复用核价页；WPF 本页仍未迁移。须按 contracts/sales-manager-review/v1.json 区分负责人审核事实和财务事实，保留独立定价来源及租约/版本/反审核守卫。。

## W7-BIZ-071

- [ ] **财务 / finance reconciliation** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_reconciliation_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：post（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-072

- [ ] **财务 / finance report table** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_report_table_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：export、post、print、remove、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`docs/99-项目治理/2026-11-01-财务钱流全分类数据与导出审计.md`；`clients/windows_legacy/progress/evidence/staff-feedback-20261103.json`；`clients/windows_legacy/progress/evidence/party-master-hidden-20261103.json`；`clients/windows_legacy/progress/contracts/party-master-hidden.json`；`clients/windows_legacy/progress/evidence/date-range-entry-20261103.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`。

接续/限制：2026-11-03：客户对账单新增 clientName/客户名称；列表、筛选、排序、打印及导出须同一投影。WPF 报表尚未迁移，保持 todo。；2026-11-03 客户/供应商资料删除确认仅设置 is_hidden，主档与新业务选择隐藏；is_deleted/status/UUID、旧单据及既有往来保留。引用提醒按 confirmationRequired 给“去查看/仍然删除”，重提只含确认子集并保留版本；权限/版本失败不得强制。负责人“未分配”用同源 Uten.Error 红色。原生页面及相关业务选择/历史筛选尚未迁移，保持 todo，不开放占位写入口；接入合同见 clients/windows_legacy/progress/contracts/party-master-hidden.json。；2026-11-03：日期范围UI合同增量：外部单一选择日期入口，卡内最右Uten红圆白X清除，默认中国壁钟最近一个日历月，年月标题直接跳年/月。该业务WPF宿主仍未迁移；后续接入公共UtenDateRangeDialog，并保留本业务日期/时区/开放边界及服务端权威，不开放占位写入口。见 E-DATE-RANGE-ENTRY-20261103。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。。

## W7-BIZ-073

- [ ] **财务 / finance sales order confirmation** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_sales_order_confirmation_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：complete、confirm、copy、post、remove（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/review-layout-and-refresh-20261101.json`；`clients/windows_legacy/progress/evidence/category-prefetch-sweep-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-01 补充：审核页悬浮动作/顶栏刷新、财务小类徽章同源、销售编辑返回认领刷新循环的客户端公共分类合同已修复；本 WPF 页面仍未迁移。详见docs/99-项目治理/2026-11-01-订单复审刷新循环与审核布局补充.md。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。。

## W7-BIZ-074

- [ ] **财务 / finance sales order review** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_sales_order_review_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：close、confirm、copy、dispatch、finish、post、reject、remove、restore、start、submit（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/order-bom-delivery-20261104.json`；`clients/windows_legacy/progress/evidence/internal-feedback-20261104.json`。

接续/限制：2026-10-31 负责人订货审核仍未迁移；反审核须先持久化decisionId并按不可变事件身份、下一修订号、员工及原因核对未知结果，不能凭状态猜成功或重放。合同见contracts/sales-manager-review/v1.json。；2026-11-04：订单BOM交付配置、必要加工、组件实物库存及发货合同新增；本WPF入口尚未迁移，保留原状态/DoD/依赖，不开放占位写入。见E-ORDER-BOM-DELIVERY-20261104。；2026-11-05 内部测试反馈（E-INTERNAL-FEEDBACK-20261104）：订单财审须把订单预收与未收计划标为辅助，未发货计划不得当本批应收/红色催收余额；有限订单资金权限与客户全账分开、客户累计到账折叠辅助，保持原审核边界、不可变历史依据及未知非零语义。 WPF本项保持todo，原owner/DoD/依赖/nativeTargets保留，Flutter/后端检查不构成本项或Win7验收。。

## W7-BIZ-075

- [ ] **财务 / finance sales shipment audit** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_sales_shipment_audit_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：audit（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/review-layout-and-refresh-20261101.json`；`clients/windows_legacy/progress/evidence/category-prefetch-sweep-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-01 补充：审核页悬浮动作/顶栏刷新、财务小类徽章同源、销售编辑返回认领刷新循环的客户端公共分类合同已修复；本 WPF 页面仍未迁移。详见docs/99-项目治理/2026-11-01-订单复审刷新循环与审核布局补充.md。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。。

## W7-BIZ-076

- [ ] **财务 / finance sales shipment audit review** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_sales_shipment_audit_review_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：approve、audit、close、confirm、copy、dispatch、finish、post、reject、remove、restore、reverse、start、submit（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/internal-feedback-20261104.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-05 内部测试反馈（E-INTERNAL-FEEDBACK-20261104）：出货财审须以唯一有效本批AR的货款/已核准现金+实际定金抵款/还欠/到期为主，退货/减免/其他抵款分列，不拿订单计划或客户累计充本批。当前读与当时放行冻结依据分开、缺源/客户币种状态金额不符未知；原对象及金额权限、RR边界、仓库打印白名单和有限辅助折叠均须原生实现与验证。 WPF本项保持todo，原owner/DoD/依赖/nativeTargets保留，Flutter/后端检查不构成本项或Win7验收。；2026-11-05 真UAT最终合同（E-INTERNAL-FEEDBACK-20261104）：出货财审须以唯一有效本批AR的货款/已核准现金+实际定金抵款/还欠/到期为主，退货/减免/其他抵款分列，不拿订单计划或客户累计充本批。当前读与当时放行冻结依据分开、缺源/客户币种状态金额不符未知；原对象及金额权限、RR边界、仓库打印白名单和有限辅助折叠均须原生实现与验证。 真UAT补足：客户端本次读取DateTime是真实instant，须UTC转换北京并仅一次时区标记，不把本机墙上时间标北京、不改server asOf/金额；有权只读附件移入表后折叠资料区。 WPF保持todo；未修改原owner/DoD/依赖/nativeTargets，真实HTTP/Flutter结果不是原生验收。。

## W7-BIZ-077

- [ ] **财务 / finance statement** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/pages/finance_statement_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：export、post、print、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`docs/99-项目治理/2026-11-01-财务钱流全分类数据与导出审计.md`；`clients/windows_legacy/progress/evidence/party-master-hidden-20261103.json`；`clients/windows_legacy/progress/contracts/party-master-hidden.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`。

接续/限制：2026-11-01财务审计续修：客户/供应商流水、明细、年度的月汇总同快照回放与重算并发保护需共享接入；年度退货不单列时为NULL并明确已并入发生额，不能伪报0。本WPF页面仍未迁移。；2026-11-03 客户/供应商资料删除确认仅设置 is_hidden，主档与新业务选择隐藏；is_deleted/status/UUID、旧单据及既有往来保留。引用提醒按 confirmationRequired 给“去查看/仍然删除”，重提只含确认子集并保留版本；权限/版本失败不得强制。负责人“未分配”用同源 Uten.Error 红色。原生页面及相关业务选择/历史筛选尚未迁移，保持 todo，不开放占位写入口；接入合同见 clients/windows_legacy/progress/contracts/party-master-hidden.json。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。。

## W7-BIZ-078

- [ ] **财务 / finance payables** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/finance/payables/pages/finance_payables_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy、create、post、remove（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/party-master-hidden-20261103.json`；`clients/windows_legacy/progress/contracts/party-master-hidden.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 客户/供应商资料删除确认仅设置 is_hidden，主档与新业务选择隐藏；is_deleted/status/UUID、旧单据及既有往来保留。引用提醒按 confirmationRequired 给“去查看/仍然删除”，重提只含确认子集并保留版本；权限/版本失败不得强制。负责人“未分配”用同源 Uten.Error 红色。原生页面及相关业务选择/历史筛选尚未迁移，保持 todo，不开放占位写入口；接入合同见 clients/windows_legacy/progress/contracts/party-master-hidden.json。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。。
