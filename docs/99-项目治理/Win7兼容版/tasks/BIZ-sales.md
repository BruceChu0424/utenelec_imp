# 全部业务页面迁移 / sales

由唯一进度登记表生成。

## W7-BIZ-135

- [ ] **销售 / sales doc detail** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/sales/pages/sales_doc_detail_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：approve、audit、cancel、confirm、copy、create、delete、download、edit、post、reject、restore、reverse、submit、withdraw（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/review-layout-and-refresh-20261101.json`；`clients/windows_legacy/progress/evidence/local-main-integration-20261103.json`。

接续/限制：2026-10-31 销售单据详情新增负责人待审/驳回/批准、人员及原因，销售修订后先重走负责人审核。WPF 详情尚未迁移，不把后端同步当成本端完成；见 sales-manager-review/v1.json 合同。；2026-11-01 补充：审核页悬浮动作/顶栏刷新、财务小类徽章同源、销售编辑返回认领刷新循环的客户端公共分类合同已修复；本 WPF 页面仍未迁移。详见docs/99-项目治理/2026-11-01-订单复审刷新循环与审核布局补充.md。；2026-11-03 本地整合：销售备货进度已保存稳定快照，服务端权威区分库存/自产/委外并共用 contracts/sales-preparation-progress/v1.json 样例；Dart详情面板、选单和发货预填消费同一 plan-progress 契约。WPF这些销售入口仍未迁移，不开放候选写入口、不改变本项完成状态，后续须同步数量、生命周期和未知提交语义。。

## W7-BIZ-136

- [ ] **销售 / sales doc edit** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/sales/pages/sales_doc_edit_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：audit、cancel、complete、confirm、copy、create、download、edit、export、finish、import、post、remove、restore、save、ship、start、submit、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/business-auxiliary-references-20261101.json`；`clients/windows_legacy/progress/evidence/staff-feedback-20261103.json`；`clients/windows_legacy/progress/evidence/shared-picker-field-regression-20261102.json`；`clients/windows_legacy/progress/evidence/local-main-integration-20261103.json`；`clients/windows_legacy/progress/evidence/party-master-hidden-20261103.json`；`clients/windows_legacy/progress/contracts/party-master-hidden.json`。

接续/限制：2026-11-03：订单新建无需填写发运策略，缺省 ALLOW_PARTIAL；客户切换/未落单草稿同口径，已有订单省略字段保留原策略及修订保护。WPF 尚未迁移，保持 todo。；尚未迁移；先做动作/合同审计。；2026-11-01 业务辅助选择改用已有业务动作授权的最小引用，人员仅工号、姓名、部门、职位；本次未实施或验收此WPF任务的原生增量，既有状态与DoD保留。见业务辅助引用证据及治理记录。；2026-11-02 公共选货回填修复：价格/折扣保留原独立字段权限，BOM库存预览仅goods:view；同一单调读代次覆盖分类、建议、确认和回写。共享合同 contracts/business-master-references/v1.json；当前原生业务选择/BOM编辑尚未迁移，不以Web、Flutter或服务端测试替代原生验收，状态不变。；2026-11-03 本地整合：销售备货进度已保存稳定快照，服务端权威区分库存/自产/委外并共用 contracts/sales-preparation-progress/v1.json 样例；Dart详情面板、选单和发货预填消费同一 plan-progress 契约。WPF这些销售入口仍未迁移，不开放候选写入口、不改变本项完成状态，后续须同步数量、生命周期和未知提交语义。；2026-11-03 客户/供应商资料删除确认仅设置 is_hidden，主档与新业务选择隐藏；is_deleted/status/UUID、旧单据及既有往来保留。引用提醒按 confirmationRequired 给“去查看/仍然删除”，重提只含确认子集并保留版本；权限/版本失败不得强制。负责人“未分配”用同源 Uten.Error 红色。原生页面及相关业务选择/历史筛选尚未迁移，保持 todo，不开放占位写入口；接入合同见 clients/windows_legacy/progress/contracts/party-master-hidden.json。。

## W7-BIZ-137

- [ ] **销售 / sales doc list** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/sales/pages/sales_doc_list_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：audit、delete、edit、import、post、ship（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/sales-task-prefetch-20261103.json`；`clients/windows_legacy/progress/evidence/category-prefetch-sweep-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 销售任务中心内嵌出货、客户零星发货、退货、报价及历史其它出货共用本列表。后续原生迁移须按权限有界预热非历史工作段首屏，点击复用完整同查询的在途/已完成读取，并按身份、权限、读取范围、API 实例及写修订隔离；显式刷新绕过预热，历史时间门控/筛选/排序/分页保持 owning 条件。WPF 本页尚未迁移，保持 todo；详见 E-SALES-TASK-PREFETCH-20261103。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。。

## W7-BIZ-138

- [ ] **销售 / sales hub** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/sales/pages/sales_hub_page.dart`。

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

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-217

- [ ] **销售 / sales manager review** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/sales/pages/sales_manager_review_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：cancel、close、confirm、dispatch、finish、post、restore、start、submit（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/task-sales-warehouse-repair-20261101.json`；`clients/windows_legacy/progress/evidence/review-layout-and-refresh-20261101.json`。

接续/限制：2026-10-31 新增销售负责人订单审核，原生 WPF 尚未迁移，不开放占位写入口。共享契约 contracts/sales-manager-review/v1.json；八个独立权限、两类认领、版本校验、驳回/反审核/批量/未知提交恢复均须迁移。详见 docs/99-项目治理/2026-10-31-销售负责人前置审核.md。；2026-11-01 审核队列新增 kind=all / HISTORY 与分页前全列表头筛选；UI 仅待审核/历史记录、首列状态，搜索与分类同高。合同见 sales-manager-review/v1.json queue。WPF 仍未迁移，不开放写入口。；2026-11-01 补充：审核页悬浮动作/顶栏刷新、财务小类徽章同源、销售编辑返回认领刷新循环的客户端公共分类合同已修复；本 WPF 页面仍未迁移。详见docs/99-项目治理/2026-11-01-订单复审刷新循环与审核布局补充.md。；2026-11-01 补充：Flutter/Web 订单审核队列接入 UtenCollapsingHeaderScrollView + primary 表格，流程提示及分类搜索先收起、表格置顶后内滚，未知提交提示保持常驻。手机公共触摸协调由独立任务处理；WPF 仍未迁移，不开放写入口。范围及回归见 docs/99-项目治理/2026-11-01-订单审核表格置顶接入.md；源码指纹由最终集成任务基于 canonical 源统一刷新。。

## W7-BIZ-139

- [ ] **销售 / sales order progress** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/sales/pages/sales_order_progress_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：cancel、delete、edit、post、ship、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/task-sales-warehouse-repair-20261101.json`；`clients/windows_legacy/progress/evidence/sales-task-prefetch-20261103.json`；`clients/windows_legacy/progress/evidence/category-prefetch-sweep-20261103.json`。

接续/限制：2026-10-31 订单进度新增 managerReviewState/managerRejectReason，区分等待负责人、负责人驳回和财务状态。WPF 进度入口未迁移；不能把负责人批准解释为财务已通过。；2026-11-01 审核未完成的有库存订货单统一归进行中/PENDING，状态明确等待销售负责人审核；不能因预留量将新单提前放入可发货。WPF 本页仍未迁移。；2026-11-03 订单进度子分类徽章同源消费 TASK_*（badge-summary salesStage.*）口径，避免另发重复阶段统计；非历史工作段首屏可有界预热并完整匹配查询复用，按身份/权限/读取范围/API 实例/本端写修订隔离，显式刷新绕过缓存。WPF 本页尚未迁移，保持 todo，不开放占位入口；详见 E-SALES-TASK-PREFETCH-20261103。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。。

## W7-BIZ-140

- [ ] **销售 / sales report** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/sales/pages/sales_report_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 源码发现的动作线索须逐项核实：copy、export、post、print、remove、update（仅静态线索，不等于完整动作清单）。
5. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
6. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
7. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
8. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
9. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：尚未登记，不得推定通过。

接续/限制：尚未迁移；先做动作/合同审计。。

## W7-BIZ-141

- [ ] **销售 / sales scarcity** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/sales/pages/sales_scarcity_page.dart`。

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

## W7-BIZ-142

- [ ] **销售 / sales task center** — 未开始

影响：`frontend+shared-contract`；负责人：待认领；依赖：W7-GOV-005, W7-GOV-006, W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014, W7-UI-001。

源入口：`lib/features/sales/pages/sales_task_center_page.dart`。

完成条件：

1. 核实本页有效入口、路由/别名/内嵌/退役分类，以及静态发现之外的所有实际动作。
2. 逐一对照 owning Flutter UI/公共组件及后端DTO/权限/动作合同；缺失接口单独登记必要增量，不能猜测。
3. 原生WPF实现全部适用读取、筛选/排序/分页、详情/导航与业务动作，不能只做菜单或只读代替写流程。
4. 若源有新增/编辑/审核/批量/附件/导入导出/打印/历史，逐项迁移，保留币种/单位/来源/归属及精度/未知语义。
5. 权限/数据集/读范围、草稿、版本/幂等、未知提交、取消/断网/重启/升级行为有合同及恢复证据。
6. 复用同源Uten圆角/控件/字体/间距，完成键盘/IME/缩放/状态/焦点与现版本实际对照。
7. 当前源码x86与x64合同及调用方检查通过；在Win7 SP1两架构验证完整适用流程，并确认Win10相关回归。
8. 更新该页、相关FLOW链和证据记录；只有全部适用条件满足或有证据的N/A才可完成。

证据：`clients/windows_legacy/progress/evidence/sales-task-prefetch-20261103.json`；`clients/windows_legacy/progress/evidence/category-prefetch-sweep-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 销售任务中心需与订单进度和单据列表共用权威子类计数及有界首屏预热，保留不同徽章口径、权限、历史时间门控与旧结果退休。WPF 本页尚未迁移，nativeTargets 为空；本轮只登记后续消费者合同，状态保持 todo，完整 ERP/Win7 真机及正式交付未验收。详见 E-SALES-TASK-PREFETCH-20261103。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。。
