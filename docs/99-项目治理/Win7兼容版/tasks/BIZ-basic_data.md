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

证据：`clients/windows_legacy/progress/evidence/mould-bom-sync-20261031.json`；`clients/windows_legacy/progress/evidence/goods-bom-comparison-20261101.json`；`docs/99-项目治理/2026-11-01-价格分析入口与商业价格权限收口.md`；`clients/windows_legacy/progress/evidence/shared-picker-field-regression-20261102.json`；`clients/windows_legacy/progress/evidence/goods-currency-selection-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`；`clients/windows_legacy/progress/evidence/platform-search-followup-20261104.json`；`clients/windows_legacy/progress/evidence/order-bom-delivery-20261104.json`；`clients/windows_legacy/progress/evidence/platform-loading-20261105.json`；`clients/windows_legacy/progress/evidence/platform-loading-main3068-20261105.json`；`clients/windows_legacy/progress/evidence/wpf-goods-summary-20261106.json`；`clients/windows_legacy/progress/evidence/screenshot-feedback-20261110.json`。

接续/限制：2026-11-01 BOM对比追加：左右选中联动，目标侧按钮分组与顶部通知；编辑/替换先暂存，替换和最终保存弹窗确认，未保存关闭可保存/放弃/继续。Web和Flutter共用；完整WPF货品详情和此交互未迁移，未知回执/权限/精度须同合同接续，不算真机或原生完成。；2026-11-01 Web/Flutter goods detail gains symmetric window insets and a unified theme surface. BOM comparison uses the SAME MasterDataTableView and UtenTreeTableCell as assembly, with linked scroll/selection and bidirectional selected/all-component replacement through existing snapshot/preview/commit. Native full detail/BOM remains unported. Follow source+target fingerprints, exact decimals, permissions and unknown-commit recovery. See E-GOODS-BOM-COMPARE-20261101; current source hashes belong to that evidence.；2026-11-01价格权限收口：来源价格码、来源查看和分析权共同控制价格分析/历史入口；财务数据范围不替代商业字段码。采购/委外公共字段与草稿历史投影同源；AI登记及执行按种类重验。当前原生货品售价读取合同不变；价格分析与采购/委外原生完整入口仍未迁移，状态/DoD不变。见docs/99-项目治理/2026-11-01-价格分析入口与商业价格权限收口.md。；2026-11-02 公共选货回填修复：价格/折扣保留原独立字段权限，BOM库存预览仅goods:view；同一单调读代次覆盖分类、建议、确认和回写。共享合同 contracts/business-master-references/v1.json；当前原生业务选择/BOM编辑尚未迁移，不以Web、Flutter或服务端测试替代原生验收，状态不变。；2026-11-03：现有只读货品内嵌详情已补币种，按售价查看/编辑授权和priceMasked同步隐藏；历史空币种标未登记，不猜人民币。Dart/C#共用18个货币display样例，26个色彩token由Dart生成。WPF货品新建、编辑及完整业务详情仍未迁移，不开放写入口，Win7目标验收未完成。见 E-GOODS-CURRENCY-SELECTION-20261103。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。；S09 search follow-up: bounded in-flight reads and mandatory post-operation refresh; local dual-architecture STA checks. Original status, owner, DoD and Win7 acceptance preserved.；2026-11-04：订单BOM交付配置、必要加工、组件实物库存及发货合同新增；本WPF入口尚未迁移，保留原状态/DoD/依赖，不开放占位写入。见E-ORDER-BOM-DELIVERY-20261104。；2026-11-05 最新Main3068输出协议与本任务完整列表已在候选安全合成：保留allRows/100行有界传输及首响应权威total供打印/导出范围，不恢复页码。最新186源码/资源零漂移，x86/x64各警告视为错误编译及历史、连续列表、搜索、输出协议实际STA组全部自然0；每架构各命名scope合计307断言（非完整runner/全ERP终验，旧228不重复叠加）。372项status/owner/DoD/依赖/nativeTargets不提升，完整ERP、Win7目标机、正式分发仍未完成。见E-PLATFORM-LOADING-MAIN3068-20261105。；2026-11-06 货品只读完整摘要已合本地Main：每批100、强身份/数据/快照证明后最多4批并行，10001行/101批及2414行/25批完整到尾，滚动0请求；x86/x64警告视为错误编译、原Core/Goods合同与实际连续/搜索/币种UI通过。原有按钮等待及取消后文案收尾完成，取消保完整结果且0写。仅既有只读入口，不新增原生写业务、不提升原status/owner/DoD/依赖/nativeTargets，不代表Win7目标机或完整ERP验收。见E-WPF-GOODS-SUMMARY-20261106。；2026-11-10 E-SCREENSHOT-FEEDBACK-20261110：公共空表/横滚及终身使用货品删除合同。完整入口、公共实现、真实运行时与保留差异见docs/99-项目治理/2026-11-10-十四张截图反馈修复.md。任务原status/owner/DoD/依赖/nativeTargets保留；Flutter或服务端通过不等于本项原生业务、Win7目标机或正式交付完成。。

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

证据：`clients/windows_legacy/progress/evidence/table-output-selection-20261105.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-05图3/4：货品Excel按模具编号匹配、预览与确认由Flutter/后端实现；原生导入预览/模具关系确认未迁移，不开放占位写入口。后续须复用权限、错误/歧义报告及未知提交保护。见E-TABLE-OUTPUT-SELECTION-20261105。。

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

证据：`clients/windows_legacy/progress/evidence/mould-bom-sync-20261031.json`；`clients/windows_legacy/progress/evidence/business-auxiliary-references-20261101.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`；`clients/windows_legacy/progress/evidence/table-output-selection-20261105.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-10-31 read-only company/old-backup audit confirms original summary text is preserved as keeper while manufacturer is blank. Native mould workspace remains unported. Retain raw text, supplier UUID ambiguity and approved data-recovery boundary. See E-MOULD-BOM-WINDOWS-20261031.；2026-10-31 user confirmed summary is manufacturer/mould supplier. V972 and offline import now recover/preserve original text; company read-only preflight: 1300 eligible, zero conflicts. Production was not written. WPF mould page remains unported.；2026-11-01 业务辅助选择改用已有业务动作授权的最小引用，人员仅工号、姓名、部门、职位；本次未实施或验收此WPF任务的原生增量，既有状态与DoD保留。见业务辅助引用证据及治理记录。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。；2026-11-05图2：服务端已有mould后台流式全量导出数据集；公共主档selectedIds增加当前筛选/权限交集及精确核对，未删除同步500行安全预算。原生模具主档/导出/打印仍未迁移，后端合同不代表原生入口完成。见E-TABLE-OUTPUT-SELECTION-20261105。。

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

影响：`frontend+shared-contract`；负责人：Codex；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

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

证据：`clients/windows_legacy/progress/evidence/mould-bom-sync-20261031.json`；`clients/windows_legacy/progress/evidence/goods-bom-comparison-20261101.json`；`docs/99-项目治理/2026-11-02-货品表格保存后退出编辑.md`；`clients/windows_legacy/progress/evidence/goods-currency-selection-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`；`clients/windows_legacy/progress/evidence/platform-search-followup-20261104.json`；`clients/windows_legacy/progress/evidence/table-output-selection-20261105.json`；`clients/windows_legacy/progress/evidence/platform-loading-20261105.json`；`clients/windows_legacy/progress/evidence/platform-loading-main3068-20261105.json`；`clients/windows_legacy/progress/evidence/wpf-goods-summary-20261106.json`；`clients/windows_legacy/progress/evidence/complete-master-stream-20261106.json`；`clients/windows_legacy/progress/evidence/screenshot-feedback-20261110.json`。

接续/限制：货品完整列表已改一次NDJSON HTTP读取，服务端100行帧，complete及EOF后经公共快照校验才发布；x86/x64 Debug/Release编译及PE、本机10001行虚拟滚动/取消/退休验证通过。仅候选本机证据，货品完整业务及Win7真机仍未完成。；2026-11-06 历史货品组件粘贴按服务端授权来源核对原数量及有符号历史金额，普通新增或修改继续执行非负约束。原生写入迁移状态保持。；2026-11-10 E-SCREENSHOT-FEEDBACK-20261110：公共空表/横滚及终身使用货品删除合同。完整入口、公共实现、真实运行时与保留差异见docs/99-项目治理/2026-11-10-十四张截图反馈修复.md。任务原status/owner/DoD/依赖/nativeTargets保留；Flutter或服务端通过不等于本项原生业务、Win7目标机或正式交付完成。。

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

证据：`docs/99-项目治理/Win7兼容版/02-业务流程迁移与验收矩阵.md`；`docs/99-项目治理/Win7兼容版/09-本机草稿与单位首批写入接续.md`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`；`clients/windows_legacy/progress/evidence/biz037-flow001-upd009-20261030.json`；`clients/windows_legacy/progress/evidence/goods-currency-selection-20261103.json`；`clients/windows_legacy/progress/evidence/date-range-entry-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-followup-20261104.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`；`clients/windows_legacy/progress/evidence/date-range-compact-20261103.json`；`clients/windows_legacy/progress/evidence/date-range-clear-circle-20261104.json`；`clients/windows_legacy/progress/evidence/table-output-selection-20261105.json`；`clients/windows_legacy/progress/evidence/platform-loading-20261105.json`；`clients/windows_legacy/progress/evidence/platform-loading-history-20261105.json`；`clients/windows_legacy/progress/evidence/platform-loading-main3068-20261105.json`；`clients/windows_legacy/progress/evidence/complete-master-stream-20261106.json`。

接续/限制：单位完整列表同步一次NDJSON HTTP读取并保留精确/空值筛选、scope、未知写及500项命令上限；x86/x64 Debug/Release编译及PE、本机501行连续读取/全选/拒绝超限写验证通过。完整28动作/Win7目标机未验收，其余9类基础资料原生入口未迁移。。

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
