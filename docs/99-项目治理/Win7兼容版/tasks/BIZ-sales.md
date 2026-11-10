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

证据：`clients/windows_legacy/progress/evidence/review-layout-and-refresh-20261101.json`；`clients/windows_legacy/progress/evidence/local-main-integration-20261103.json`；`clients/windows_legacy/progress/evidence/order-bom-delivery-20261104.json`；`clients/windows_legacy/progress/evidence/internal-feedback-20261104.json`；`clients/windows_legacy/progress/evidence/screenshot-feedback-20261110.json`。

接续/限制：2026-10-31 销售单据详情新增负责人待审/驳回/批准、人员及原因，销售修订后先重走负责人审核。WPF 详情尚未迁移，不把后端同步当成本端完成；见 sales-manager-review/v1.json 合同。；2026-11-01 补充：审核页悬浮动作/顶栏刷新、财务小类徽章同源、销售编辑返回认领刷新循环的客户端公共分类合同已修复；本 WPF 页面仍未迁移。详见docs/99-项目治理/2026-11-01-订单复审刷新循环与审核布局补充.md。；2026-11-03 本地整合：销售备货进度已保存稳定快照，服务端权威区分库存/自产/委外并共用 contracts/sales-preparation-progress/v1.json 样例；Dart详情面板、选单和发货预填消费同一 plan-progress 契约。WPF这些销售入口仍未迁移，不开放候选写入口、不改变本项完成状态，后续须同步数量、生命周期和未知提交语义。；2026-11-04：订单BOM交付配置、必要加工、组件实物库存及发货合同新增；本WPF入口尚未迁移，保留原状态/DoD/依赖，不开放占位写入。见E-ORDER-BOM-DELIVERY-20261104。；2026-11-05 内部测试反馈（E-INTERNAL-FEEDBACK-20261104）：销售单据详情须同步本批货款/已收/还欠的精确资金投影、真实到期和当前/审核时点区别；订单金额仅辅助，未抵定金不计本批，金融读取先原对象范围再有限金额权限，仓库不能透传私有金融JSON。收款/反向后的公共刷新与未知来源显示须迁移，不用客户累计推算。 WPF本项保持todo，原owner/DoD/依赖/nativeTargets保留，Flutter/后端检查不构成本项或Win7验收。；2026-11-05 真UAT最终合同（E-INTERNAL-FEEDBACK-20261104）：销售单据详情须同步本批货款/已收/还欠的精确资金投影、真实到期和当前/审核时点区别；订单金额仅辅助，未抵定金不计本批，金融读取先原对象范围再有限金额权限，仓库不能透传私有金融JSON。收款/反向后的公共刷新与未知来源显示须迁移，不用客户累计推算。 真UAT补足：客户端读取时刻按真实instant转北京且只标一次，有权只读附件移表后资料折叠区；不改当前本批资金算法或隐私权限。 WPF保持todo；未修改原owner/DoD/依赖/nativeTargets，真实HTTP/Flutter结果不是原生验收。；2026-11-06 任务徽章与物料准备回归。原生销售订货单详情仍待迁移。交付方式只读查看与编辑、审核职责分开，保持紧凑行高。本轮未验收本原生业务或 Win7 真机。；2026-11-10 E-SCREENSHOT-FEEDBACK-20261110：本批已收与来源折扣展示合同。完整入口、公共实现、真实运行时与保留差异见docs/99-项目治理/2026-11-10-十四张截图反馈修复.md。任务原status/owner/DoD/依赖/nativeTargets保留；Flutter或服务端通过不等于本项原生业务、Win7目标机或正式交付完成。。

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

证据：`clients/windows_legacy/progress/evidence/business-auxiliary-references-20261101.json`；`clients/windows_legacy/progress/evidence/staff-feedback-20261103.json`；`clients/windows_legacy/progress/evidence/shared-picker-field-regression-20261102.json`；`clients/windows_legacy/progress/evidence/local-main-integration-20261103.json`；`clients/windows_legacy/progress/evidence/party-master-hidden-20261103.json`；`clients/windows_legacy/progress/contracts/party-master-hidden.json`；`clients/windows_legacy/progress/evidence/order-bom-delivery-20261104.json`；`clients/windows_legacy/progress/evidence/internal-feedback-20261104.json`；`clients/windows_legacy/progress/evidence/screenshot-feedback-20261110.json`。

接续/限制：2026-11-03：订单新建无需填写发运策略，缺省 ALLOW_PARTIAL；客户切换/未落单草稿同口径，已有订单省略字段保留原策略及修订保护。WPF 尚未迁移，保持 todo。；尚未迁移；先做动作/合同审计。；2026-11-01 业务辅助选择改用已有业务动作授权的最小引用，人员仅工号、姓名、部门、职位；本次未实施或验收此WPF任务的原生增量，既有状态与DoD保留。见业务辅助引用证据及治理记录。；2026-11-02 公共选货回填修复：价格/折扣保留原独立字段权限，BOM库存预览仅goods:view；同一单调读代次覆盖分类、建议、确认和回写。共享合同 contracts/business-master-references/v1.json；当前原生业务选择/BOM编辑尚未迁移，不以Web、Flutter或服务端测试替代原生验收，状态不变。；2026-11-03 本地整合：销售备货进度已保存稳定快照，服务端权威区分库存/自产/委外并共用 contracts/sales-preparation-progress/v1.json 样例；Dart详情面板、选单和发货预填消费同一 plan-progress 契约。WPF这些销售入口仍未迁移，不开放候选写入口、不改变本项完成状态，后续须同步数量、生命周期和未知提交语义。；2026-11-03 客户/供应商资料删除确认仅设置 is_hidden，主档与新业务选择隐藏；is_deleted/status/UUID、旧单据及既有往来保留。引用提醒按 confirmationRequired 给“去查看/仍然删除”，重提只含确认子集并保留版本；权限/版本失败不得强制。负责人“未分配”用同源 Uten.Error 红色。原生页面及相关业务选择/历史筛选尚未迁移，保持 todo，不开放占位写入口；接入合同见 clients/windows_legacy/progress/contracts/party-master-hidden.json。；2026-11-04：订单BOM交付配置、必要加工、组件实物库存及发货合同新增；本WPF入口尚未迁移，保留原状态/DoD/依赖，不开放占位写入。见E-ORDER-BOM-DELIVERY-20261104。；2026-11-05 内部测试反馈（E-INTERNAL-FEEDBACK-20261104）：销售开单通过sales_doc_edit_page.dart的showUtenGoodsPickerMulti共用货品选择器；图1即时库存须沿服务端批量良品现存与原字段权限，区分现存/可用、不扣预留、不逐行N+1，完整十进制与未知不填假零，新增库存列置原业务列之后。该原生销售开单尚未迁移，不能仅登记直接变更页面而漏掉公共调用义务；不开放占位写入口。 WPF本项保持todo，原owner/DoD/依赖/nativeTargets保留，Flutter/后端检查不构成本项或Win7验收。；2026-11-10 E-SCREENSHOT-FEEDBACK-20261110：本批已收与来源折扣展示合同。完整入口、公共实现、真实运行时与保留差异见docs/99-项目治理/2026-11-10-十四张截图反馈修复.md。任务原status/owner/DoD/依赖/nativeTargets保留；Flutter或服务端通过不等于本项原生业务、Win7目标机或正式交付完成。。

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

证据：`clients/windows_legacy/progress/evidence/sales-task-prefetch-20261103.json`；`clients/windows_legacy/progress/evidence/category-prefetch-sweep-20261103.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`；`clients/windows_legacy/progress/evidence/order-bom-delivery-20261104.json`；`clients/windows_legacy/progress/evidence/internal-feedback-20261104.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 销售任务中心内嵌出货、客户零星发货、退货、报价及历史其它出货共用本列表。后续原生迁移须按权限有界预热非历史工作段首屏，点击复用完整同查询的在途/已完成读取，并按身份、权限、读取范围、API 实例及写修订隔离；显式刷新绕过预热，历史时间门控/筛选/排序/分页保持 owning 条件。WPF 本页尚未迁移，保持 todo；详见 E-SALES-TASK-PREFETCH-20261103。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。；2026-11-04：订单BOM交付配置、必要加工、组件实物库存及发货合同新增；本WPF入口尚未迁移，保留原状态/DoD/依赖，不开放占位写入。见E-ORDER-BOM-DELIVERY-20261104。；2026-11-05 内部测试反馈（E-INTERNAL-FEEDBACK-20261104）：销售列表须在表末追加已收/还欠/到期并按精确原币显示；只看还欠切已出库+全部日期，列表与分面共用服务端谓词、先对象范围/资金权限再分页，关闭恢复原本地筛选。订单未收计划仅中性辅助；真实收款/反向刷新、窄屏Uten菜单和未知金额不当零须原生实现。 WPF本项保持todo，原owner/DoD/依赖/nativeTargets保留，Flutter/后端检查不构成本项或Win7验收。。

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

证据：`clients/windows_legacy/progress/evidence/task-sales-warehouse-repair-20261101.json`；`clients/windows_legacy/progress/evidence/review-layout-and-refresh-20261101.json`；`clients/windows_legacy/progress/evidence/employee-applications-20261103.json`；`clients/windows_legacy/progress/evidence/order-bom-delivery-20261104.json`。

接续/限制：2026-10-31 新增销售负责人订单审核，原生 WPF 尚未迁移，不开放占位写入口。共享契约 contracts/sales-manager-review/v1.json；八个独立权限、两类认领、版本校验、驳回/反审核/批量/未知提交恢复均须迁移。详见 docs/99-项目治理/2026-10-31-销售负责人前置审核.md。；2026-11-01 审核队列新增 kind=all / HISTORY 与分页前全列表头筛选；UI 仅待审核/历史记录、首列状态，搜索与分类同高。合同见 sales-manager-review/v1.json queue。WPF 仍未迁移，不开放写入口。；2026-11-01 补充：审核页悬浮动作/顶栏刷新、财务小类徽章同源、销售编辑返回认领刷新循环的客户端公共分类合同已修复；本 WPF 页面仍未迁移。详见docs/99-项目治理/2026-11-01-订单复审刷新循环与审核布局补充.md。；2026-11-01 补充：Flutter/Web 订单审核队列接入 UtenCollapsingHeaderScrollView + primary 表格，流程提示及分类搜索先收起、表格置顶后内滚，未知提交提示保持常驻。手机公共触摸协调由独立任务处理；WPF 仍未迁移，不开放写入口。范围及回归见 docs/99-项目治理/2026-11-01-订单审核表格置顶接入.md；源码指纹由最终集成任务基于 canonical 源统一刷新。；2026-11-03 报销/行政财务申请：新四级报销及四类申请、负责人本人回避、独立权限/徽章/付款与打印合同已变更；原生业务仍未迁移，保持原状态及 DoD。仅公共 read-scope 识别完成本机 x86/x64 fixture，不等于业务或目标机验收。合同见 clients/windows_legacy/progress/contracts/employee-applications-workflow.json。；2026-11-04：订单BOM交付配置、必要加工、组件实物库存及发货合同新增；本WPF入口尚未迁移，保留原状态/DoD/依赖，不开放占位写入。见E-ORDER-BOM-DELIVERY-20261104。。

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

证据：`clients/windows_legacy/progress/evidence/task-sales-warehouse-repair-20261101.json`；`clients/windows_legacy/progress/evidence/sales-task-prefetch-20261103.json`；`clients/windows_legacy/progress/evidence/category-prefetch-sweep-20261103.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`；`clients/windows_legacy/progress/evidence/order-bom-delivery-20261104.json`。

接续/限制：2026-10-31 订单进度新增 managerReviewState/managerRejectReason，区分等待负责人、负责人驳回和财务状态。WPF 进度入口未迁移；不能把负责人批准解释为财务已通过。；2026-11-01 审核未完成的有库存订货单统一归进行中/PENDING，状态明确等待销售负责人审核；不能因预留量将新单提前放入可发货。WPF 本页仍未迁移。；2026-11-03 订单进度子分类徽章同源消费 TASK_*（badge-summary salesStage.*）口径，避免另发重复阶段统计；非历史工作段首屏可有界预热并完整匹配查询复用，按身份/权限/读取范围/API 实例/本端写修订隔离，显式刷新绕过缓存。WPF 本页尚未迁移，保持 todo，不开放占位入口；详见 E-SALES-TASK-PREFETCH-20261103。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。；2026-11-04：订单BOM交付配置、必要加工、组件实物库存及发货合同新增；本WPF入口尚未迁移，保留原状态/DoD/依赖，不开放占位写入。见E-ORDER-BOM-DELIVERY-20261104。；2026-11-06 任务徽章与物料准备回归。原生销售订货进度仍待迁移。后续接入读范围变化自动退役与可见时首读恢复。本轮未验收本原生业务或 Win7 真机。。

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

证据：`clients/windows_legacy/progress/evidence/date-range-entry-20261103.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`。

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03：日期范围UI合同增量：外部单一选择日期入口，卡内最右Uten红圆白X清除，默认中国壁钟最近一个日历月，年月标题直接跳年/月。该业务WPF宿主仍未迁移；后续接入公共UtenDateRangeDialog，并保留本业务日期/时区/开放边界及服务端权威，不开放占位写入口。见 E-DATE-RANGE-ENTRY-20261103。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 本任务WPF同责业务仍未迁移或未完成原DoD，不开放占位写入口，不据Flutter/后端验证提升完成状态。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。。

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

接续/限制：尚未迁移；先做动作/合同审计。；2026-11-03 销售任务中心需与订单进度和单据列表共用权威子类计数及有界首屏预热，保留不同徽章口径、权限、历史时间门控与旧结果退休。WPF 本页尚未迁移，nativeTargets 为空；本轮只登记后续消费者合同，状态保持 todo，完整 ERP/Win7 真机及正式交付未验收。详见 E-SALES-TASK-PREFETCH-20261103。；2026-11-03 同类任务页面预加载扩查：前端同口径徽章/有界首屏交接已按当前源码处理；WPF 对应业务仍未迁移，不因 Dart 或公共测试提高状态。后续接入须遵守完整查询、源实例/身份/权限/写修订隔离、全 App 两条物理投机预算及原历史/期间/能力闸门；详见本轮 evidence。；2026-11-06 任务徽章与物料准备回归。原生销售任务中心仍待迁移。后续接入单次可见读取与写后徽章刷新。本轮未验收本原生业务或 Win7 真机。。
