# 全部业务页面迁移 / basic_data

由唯一进度登记表生成。

## W7-BIZ-018

- [ ] **基础资料 / account detail** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/account_detail_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：confirm、copy、delete、edit、post、reconcile、start、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/account-page-balance-20261103.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 账户资料页布局与当前余额编辑增量：Web/Flutter桌面共用AccountPage；余额改动须有account:view、account:balance:view及account:balance:adjust，经共享余额核对入口提交不可变调整批次，不使用普通主档PUT覆盖余额。WPF账户列表、详情及编辑仍未迁移，不开放写入口，不据本轮Flutter/服务端结果标完成。后续须接入expectedBalance并发、按操作者隔离幂等、服务端业务日、原因/确认、原币精度、外币显式localDelta、未知提交及历史/汇总刷新合同。见账户资料设计与余额编辑20261103证据及治理记录。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。。

## W7-BIZ-019

- [ ] **基础资料 / account** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/account_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
5. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
6. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
7. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
8. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/account-page-balance-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 账户资料页布局与当前余额编辑增量：Web/Flutter桌面共用AccountPage；余额改动须有account:view、account:balance:view及account:balance:adjust，经共享余额核对入口提交不可变调整批次，不使用普通主档PUT覆盖余额。WPF账户列表、详情及编辑仍未迁移，不开放写入口，不据本轮Flutter/服务端结果标完成。后续须接入expectedBalance并发、按操作者隔离幂等、服务端业务日、原因/确认、原币精度、外币显式localDelta、未知提交及历史/汇总刷新合同。见账户资料设计与余额编辑20261103证据及治理记录。。

## W7-BIZ-020

- [ ] **基础资料 / account workspace** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/account_workspace_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：complete、confirm、copy、create、delete、edit、export、post、print、remove、save（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/account-page-balance-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 账户资料页布局与当前余额编辑增量：Web/Flutter桌面共用AccountPage；余额改动须有account:view、account:balance:view及account:balance:adjust，经共享余额核对入口提交不可变调整批次，不使用普通主档PUT覆盖余额。WPF账户列表、详情及编辑仍未迁移，不开放写入口，不据本轮Flutter/服务端结果标完成。后续须接入expectedBalance并发、按操作者隔离幂等、服务端业务日、原因/确认、原币精度、外币显式localDelta、未知提交及历史/汇总刷新合同。见账户资料设计与余额编辑20261103证据及治理记录。。

## W7-BIZ-021

- [ ] **基础资料 / basic data hub** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/basic_data_hub_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：edit（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-022

- [ ] **基础资料 / client category** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/client_category_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：create、delete、edit、export、post、remove、save、ship、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/staff-feedback-20261103.json`；`clients/windows_legacy/progress/evidence/party-master-hidden-20261103.json`；`clients/windows_legacy/progress/contracts/party-master-hidden.json`。

接续/限制：2026-11-03：客户默认货运策略改为只读原记录，新订单固定允许分批，不再参与客户预填。WPF 客户分类编辑尚未迁移，保持 todo。；2026-11-03 客户/供应商资料删除确认仅设置 is_hidden，主档与新业务选择隐藏；is_deleted/status/UUID、旧单据及既有往来保留。引用提醒按 confirmationRequired 给“去查看/仍然删除”，重提只含确认子集并保留版本；权限/版本失败不得强制。负责人“未分配”用同源 Uten.Error 红色。原生页面及相关业务选择/历史筛选尚未迁移，保持 todo，不开放占位写入口；接入合同见 clients/windows_legacy/progress/contracts/party-master-hidden.json。。

## W7-BIZ-023

- [ ] **基础资料 / color** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/color_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：close、complete、confirm、create、delete、edit、export、post、print、remove、save、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-024

- [ ] **基础资料 / currency** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/currency_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：close、complete、confirm、create、delete、edit、export、post、print、remove、save、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-025

- [ ] **基础资料 / goods detail** — 进行中

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/goods_detail_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：confirm、create、delete、edit、post（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/mould-bom-sync-20261031.json`；`clients/windows_legacy/progress/evidence/goods-bom-comparison-20261101.json`；`docs/99-项目治理/2026-11-01-价格分析入口与商业价格权限收口.md`；`clients/windows_legacy/progress/evidence/shared-picker-field-regression-20261102.json`；`clients/windows_legacy/progress/evidence/goods-currency-selection-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`；`clients/windows_legacy/progress/evidence/platform-search-followup-20261104.json`。

接续/限制：2026-11-01 BOM对比追加：左右选中联动，目标侧按钮分组与顶部通知；编辑/替换先暂存，替换和最终保存弹窗确认，未保存关闭可保存/放弃/继续。Web和Flutter共用；完整WPF货品详情和此交互未迁移，未知回执/权限/精度须同合同接续，不算真机或原生完成。；2026-11-01 Web/Flutter goods detail gains symmetric window insets and a unified theme surface. BOM comparison uses the SAME MasterDataTableView and UtenTreeTableCell as assembly, with linked scroll/selection and bidirectional selected/all-component replacement through existing snapshot/preview/commit. Native full detail/BOM remains unported. Follow source+target fingerprints, exact decimals, permissions and unknown-commit recovery. See E-GOODS-BOM-COMPARE-20261101; current source hashes belong to that evidence.；2026-11-01价格权限收口：来源价格码、来源查看和分析权共同控制价格分析/历史入口；财务数据范围不替代商业字段码。采购/委外公共字段与草稿历史投影同源；AI登记及执行按种类重验。当前原生货品售价读取合同不变；价格分析与采购/委外原生完整入口仍未迁移，状态/DoD不变。见docs/99-项目治理/2026-11-01-价格分析入口与商业价格权限收口.md。；2026-11-02 公共选货回填修复：价格/折扣保留原独立字段权限，BOM库存预览仅goods:view；同一单调读代次覆盖分类、建议、确认和回写。共享合同 contracts/business-master-references/v1.json；当前原生业务选择/BOM编辑尚未迁移，不以Web、Flutter或服务端测试替代原生验收，状态不变。；2026-11-03：现有只读货品内嵌详情已补币种，按售价查看/编辑授权和priceMasked同步隐藏；历史空币种标未登记，不猜人民币。Dart/C#共用18个货币display样例，26个色彩token由Dart生成。WPF货品新建、编辑及完整业务详情仍未迁移，不开放写入口，Win7目标验收未完成。见 E-GOODS-CURRENCY-SELECTION-20261103。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。；S09 search follow-up: bounded in-flight reads and mandatory post-operation refresh; local dual-architecture STA checks. Original status, owner, DoD and Win7 acceptance preserved.。

## W7-BIZ-216

- [ ] **基础资料 / goods import preview** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/goods_import_preview_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：cancel、confirm、copy、edit、import、remove、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-027

- [ ] **基础资料 / goods price analysis** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/goods_price_analysis_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy、post、remove（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`docs/99-项目治理/2026-11-01-价格分析入口与商业价格权限收口.md`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-01价格权限收口：来源价格码、来源查看和分析权共同控制价格分析/历史入口；财务数据范围不替代商业字段码。采购/委外公共字段与草稿历史投影同源；AI登记及执行按种类重验。当前原生货品售价读取合同不变；价格分析与采购/委外原生完整入口仍未迁移，状态/DoD不变。见docs/99-项目治理/2026-11-01-价格分析入口与商业价格权限收口.md。。

## W7-BIZ-028

- [ ] **基础资料 / import review** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/import_review_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy、finish、import、remove（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-029

- [ ] **基础资料 / master record history** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/master_record_history_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy、edit、post（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`docs/99-项目治理/2026-11-01-资料库与权限设置共用修改历史.md`；`clients/windows_legacy/progress/evidence/date-range-entry-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-01 资料库与权限设置共用修改历史：Flutter共享实现迁入lib/shared/history，服务端V988复用永久历史。新公司历史必须复用当前对象/祖先ACL及会话密码，移动历史保护旧/新目录，访问设置另需manage_permissions；权限历史须superAdmin+authorization:manage。本项WPF仍未迁移，状态不变，不开放入口。原单位master历史JSON及恢复合同不变。见docs/99-项目治理/2026-11-01-资料库与权限设置共用修改历史.md。；2026-11-01追加：货品历史按当前价格/成本/折扣及扩展字段查看权，在服务端分页前隐藏无可读差异的记录；详情直读及恢复同样限制。物料反查使用共用货品主档/BOM入口，成功实际变更由同一数据库触发器纳入货品历史。原生全局历史/物料反查仍未迁移；见docs/99-项目治理/2026-11-01-资料库与权限设置共用修改历史.md。；2026-11-03：日期范围UI合同增量：外部单一选择日期入口，卡内最右Uten红圆白X清除，默认中国壁钟最近一个日历月，年月标题直接跳年/月。该业务WPF宿主仍未迁移；后续接入公共UtenDateRangeDialog，并保留本业务日期/时区/开放边界及服务端权威，不开放占位写入口。见 E-DATE-RANGE-ENTRY-20261103。。

## W7-BIZ-030

- [ ] **基础资料 / master record revision** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/master_record_revision_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：edit（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`docs/99-项目治理/2026-11-01-资料库与权限设置共用修改历史.md`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-01 资料库与权限设置共用修改历史：Flutter共享实现迁入lib/shared/history，服务端V988复用永久历史。新公司历史必须复用当前对象/祖先ACL及会话密码，移动历史保护旧/新目录，访问设置另需manage_permissions；权限历史须superAdmin+authorization:manage。本项WPF仍未迁移，状态不变，不开放入口。原单位master历史JSON及恢复合同不变。见docs/99-项目治理/2026-11-01-资料库与权限设置共用修改历史.md。；2026-11-01追加：货品历史按当前价格/成本/折扣及扩展字段查看权，在服务端分页前隐藏无可读差异的记录；详情直读及恢复同样限制。物料反查使用共用货品主档/BOM入口，成功实际变更由同一数据库触发器纳入货品历史。原生全局历史/物料反查仍未迁移；见docs/99-项目治理/2026-11-01-资料库与权限设置共用修改历史.md。。

## W7-BIZ-031

- [ ] **基础资料 / mould category** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/mould_category_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：confirm、create、delete、edit、export、post、save、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/mould-bom-sync-20261031.json`；`clients/windows_legacy/progress/evidence/business-auxiliary-references-20261101.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-10-31 read-only company/old-backup audit confirms original summary text is preserved as keeper while manufacturer is blank. Native mould workspace remains unported. Retain raw text, supplier UUID ambiguity and approved data-recovery boundary. See E-MOULD-BOM-WINDOWS-20261031.；2026-10-31 user confirmed summary is manufacturer/mould supplier. V972 and offline import now recover/preserve original text; company read-only preflight: 1300 eligible, zero conflicts. Production was not written. WPF mould page remains unported.；2026-11-01 业务辅助选择改用已有业务动作授权的最小引用，人员仅工号、姓名、部门、职位；本次未实施或验收此WPF任务的原生增量，既有状态与DoD保留。见业务辅助引用证据及治理记录。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-BIZ-032

- [ ] **基础资料 / party detail** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/party_detail_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：confirm、copy、delete、edit、post、save、start、stop、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/staff-feedback-20261103.json`；`clients/windows_legacy/progress/evidence/party-master-hidden-20261103.json`；`clients/windows_legacy/progress/contracts/party-master-hidden.json`。

接续/限制：2026-11-03：客户详情公共编辑字段保留原货运策略只读且不回传。WPF 客户详情尚未迁移，保持 todo。；2026-11-03 客户/供应商资料删除确认仅设置 is_hidden，主档与新业务选择隐藏；is_deleted/status/UUID、旧单据及既有往来保留。引用提醒按 confirmationRequired 给“去查看/仍然删除”，重提只含确认子集并保留版本；权限/版本失败不得强制。负责人“未分配”用同源 Uten.Error 红色。原生页面及相关业务选择/历史筛选尚未迁移，保持 todo，不开放占位写入口；接入合同见 clients/windows_legacy/progress/contracts/party-master-hidden.json。。

## W7-BIZ-033

- [ ] **基础资料 / payment style** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/payment_style_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：close、complete、confirm、copy、create、edit、post、remove、restore、save、submit、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。。

## W7-BIZ-034

- [ ] **基础资料 / product category** — 进行中

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/product_category_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：close、confirm、copy、create、delete、edit、export、import、paste、post、save、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/mould-bom-sync-20261031.json`；`clients/windows_legacy/progress/evidence/goods-bom-comparison-20261101.json`；`docs/99-项目治理/2026-11-02-货品表格保存后退出编辑.md`；`clients/windows_legacy/progress/evidence/goods-currency-selection-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`；`clients/windows_legacy/progress/evidence/platform-search-followup-20261104.json`。

接续/限制：2026-11-01 多窗口BOM交互补充未迁入原生：目标侧按钮、顶部非模态通知、联动勾选、草稿替换及最终确认保存、未保存离开和同请求结果恢复；Flutter已实现不代表WPF已支持，维持未迁移记录。；2026-11-02：Web/Flutter 货品资料分类/搜索表格普通与全屏统一为整批保存确认成功后直接退出编辑；失败、未知新增及过期回执不清除草稿，公共 controller 参数维护同一入口。本机 74 项定向回归及静态检查通过。WPF GoodsWorkspaceView 仍为只读，货品编辑未迁移；后续接入须遵守此合同，当前状态及最终 DoD 不变。见 docs/99-项目治理/2026-11-02-货品表格保存后退出编辑.md。；2026-11-03：原生货品只读列表售价右侧新增高色差币种，内嵌详情同步；离开及货品→单位详情清表格选中，返回不恢复旧选中。x86/x64 /warnaserror编译、各66条模型/同源样例断言及真实native UI/60次快速选行/卸载返回通过；完整货品写业务和Win7目标机仍未验收，DoD状态不变。见 E-GOODS-CURRENCY-SELECTION-20261103。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。；S09 search follow-up: bounded in-flight reads and mandatory post-operation refresh; local dual-architecture STA checks. Original status, owner, DoD and Win7 acceptance preserved.。

## W7-BIZ-035

- [ ] **基础资料 / settlement method** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/settlement_method_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy、create、edit、export、post、print、remove、save、submit、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-036

- [ ] **基础资料 / supplier category** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/supplier_category_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：create、delete、edit、export、post、save、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/party-master-hidden-20261103.json`；`clients/windows_legacy/progress/contracts/party-master-hidden.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 客户/供应商资料删除确认仅设置 is_hidden，主档与新业务选择隐藏；is_deleted/status/UUID、旧单据及既有往来保留。引用提醒按 confirmationRequired 给“去查看/仍然删除”，重提只含确认子集并保留版本；权限/版本失败不得强制。负责人“未分配”用同源 Uten.Error 红色。原生页面及相关业务选择/历史筛选尚未迁移，保持 todo，不开放占位写入口；接入合同见 clients/windows_legacy/progress/contracts/party-master-hidden.json。。

## W7-BIZ-037

- [ ] **基础资料 / unit** — 进行中

影响：`frontend+shared-contract`；负责人：Codex；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/unit_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：close、complete、confirm、create、delete、edit、export、post、print、remove、save、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`docs/99-项目治理/Win7兼容版/02-业务流程迁移与验收矩阵.md`；`docs/99-项目治理/Win7兼容版/09-本机草稿与单位首批写入接续.md`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`；`clients/windows_legacy/progress/evidence/biz037-flow001-upd009-20261030.json`；`clients/windows_legacy/progress/evidence/goods-currency-selection-20261103.json`；`clients/windows_legacy/progress/evidence/date-range-entry-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-followup-20261104.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`；`clients/windows_legacy/progress/evidence/date-range-compact-20261103.json`；`clients/windows_legacy/progress/evidence/date-range-clear-circle-20261104.json`。

接续/限制：本轮>32种persisted平台列已修复：ProjectBounded有界投影(添加列优先+UUID稳定顺序)+OverflowedDefinitionIds显式溢出，读取验证只覆盖可见预算、全部持久化cells/定义/整行写保全保留，表尾与表头设置显式提示修复入口，输出不再暂停；单行>32字段仍按服务端合同拒绝。columns 46→55双架构runner绿；28动作Win7目标机终验仍待。；2026-11-03：单位详情/编辑/历史/打印/导出在目的窗口准备成功后，通过公共TableSelection清除行、单元格和跨页已选索引，返回不恢复旧选中；菜单、表头工具及批量写确认保留既有语义，草稿/未知提交不变。实际打开并关闭UnitDetailWindow验证通过，x86/x64全部native UI fixtures通过；完整模块DoD及Win7真机状态不变。见 E-GOODS-CURRENCY-SELECTION-20261103。；2026-11-03：单位修改历史开始/结束文本框改为单一选择日期卡片，卡内最右红圆白X可清除；默认中国壁钟最近一个日历月（月末clamp），保留开放区间和服务端dateFrom/dateTo权威。选择/清除作废旧读取且保留其他筛选；x86/x64各37公共日期与10历史UI检查通过。完整单位模块DoD及Win7真机状态不变。见 E-DATE-RANGE-ENTRY-20261103。；S09 search follow-up: bounded in-flight reads and mandatory post-operation refresh; local dual-architecture STA checks. Original status, owner, DoD and Win7 acceptance preserved.；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 WPF已有单位修改历史日期同步同排40高按钮，范围仅留提示；本机x86/x64各dates37/history UI13通过。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。；2026-11-03：单位修改历史日期入口接公共 UtenDateRangeButton/UtenDateRangePresentation，与普通按钮同源40高，删除日历/提示/清除图标，清除改文字；选后近1个月/近N天或历史共N天，鼠标即时与键盘提示精确 yyyy.MM.dd-yyyy.MM.dd。12组共享显示样例及x86/x64每架构61公共日期、13历史UI检查通过；仅本机候选增量，完整单位DoD及Win7真机状态不变。见 E-DATE-RANGE-COMPACT-20261103。。

## W7-BIZ-038

- [ ] **基础资料 / warehouse** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/warehouse_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：cancel、close、complete、confirm、copy、create、delete、edit、export、post、print、remove、save（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/instant-inventory-period-20261102.json`；`clients/windows_legacy/progress/evidence/inventory-column-order-20261102.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：2026-11-02：仓库资料内嵌库存共享日期、成本权限及默认列序/个人布局 v2，打印导出同业务顺序。WPF 仓库资料与内嵌库存宿主仍未迁移，保持 todo；后续原生接入按 W7-BIZ-152 同一统计、排序合同及成本门禁验收。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-BIZ-026

- [ ] **基础资料 / goods import problems** — 进行中

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/basic_data/pages/goods_import_problems_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：finish、import、restore（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。；源清单已不再发现该页，须人工分类退役/改名；不得自动删除历史任务。；源清单已不再发现该页，须人工分类退役/改名；不得自动删除历史任务。；源清单已不再发现该页，须人工分类退役/改名；不得自动删除历史任务。；源清单已不再发现该页，须人工分类退役/改名；不得自动删除历史任务。。
