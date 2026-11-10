# 2026-11-10 财务截图反馈覆盖核对

本组对应用户本次图4、5、8、9；图6公共合计由根任务处理，图2出货实收由根任务处理。本文件不代替整组14图验收。当前工作树 `D:/Projects/uten_imp_worktrees/screenshot-feedback-20261110`，基线 `cb6e9ad26`。

## 原需求与实现

- 图4要求已选客户、账户等与未选状态区分，并把“单据和凭证”放到明细表之前；检查财务所有相同职责的新建入口。
- 图5“生成月结批次”使用既有右下悬浮操作组。
- 图8应收账款明细表、应付账款明细表移除外置币别；在客户/供应商之后、方向之前加入币别列，使用列头筛选。
- 图9筛选字段与分类栏使用同一高度角色；年度显示为一个可打开公共年份选择弹窗的按钮，检查同类入口。

视觉继续复用 Uten 主题、字体、圆角、密度与控件，不引入第二套配色。金融字段选择采用 primaryContainer / onPrimaryContainer 的显式已选角色；普通动作、只读历史事实、其他业务的表头字段不统一染色。

## 唯一公共入口与适用清单

`UtenSelectedValueTheme` 是已选金融引用的显式视觉作用域。`UtenDropdownField`、`UtenMasterPickerField`、`UtenEmployeePicker` 和 `UtenDepartmentPicker` 只在此作用域内且具有实际选择身份时采用已选呈现；作用域外保留原有主题默认值。错误、必填、预填警示、禁用与只读限制继续由原控件维护。

| 入口族 | 适用实现 | 保留差异 |
|---|---|---|
| 五类收款/付款/费用/其他收入/转账 | `FinanceDocEditPage` 的批量与 legacy 编辑；`financeEntryColumns` 与 `financeGridColumns` 的客户/供应商、账户、来源、币种、方式、项目、部门及转入账户 | 配置/设置按钮仍是动作，不冒充已经选中来源；不同币种、单位、金额及权限不合并 |
| 附件 | `finance_doc_batch_entry.dart`、`finance_doc_edit_page.dart` 均将既有 `BusinessAttachmentSection` 和重试通知移到明细前；五类共用 | 复用原 controller、上传及恢复流程；申请引用原报销附件，资产表单未有附件写入入口，不新造重复上传流程 |
| 财务申请 | `finance_application_edit_page.dart`、`finance_application_continuation_page.dart`；真实出差申请/供应商/来源/原应付选择按钮 | 原申请草稿、来源保管与未知请求不改变 |
| 资产 | `finance_asset_form_v2.dart`、`finance_asset_opening_group_dialog.dart`、`finance_asset_policy_dialog.dart` | 主档、期初组、政策是不同业务流程，未合并其写入、审核或生命周期 |
| 应付调整与月结 | `finance_payable_statement_adjustment_dialog.dart`、`supplier_settlement_actions.dart`；列表 `SupplierSettlementPanel` 右下 `UtenFloatingActionGroup` 并预留末行空间 | 原应付、辅助对象与科目权限；生成过程仍仅有原有 busy 等待件 |
| 会计、辅助与原表录入 | accounting/auxiliary import、chart metadata、durable command、expense analysis、native legacy opening、payroll preparation、template input、subcontract loss policy、subcontract quantity evidence、material statement editor | 全部使用原 owning 表单和服务端合同；只添加显式已选视觉角色 |
| 报表筛选 | `FinanceStatementPage`、`FinanceReportTablePage`、`FinanceAccountFlowPage` 复用既有 `UtenFilterFieldTheme`；总览 display-mode 从原生 dropdown 迁移到 `UtenDropdownField` | `FinanceArApPage` 只有公共分类栏与列头筛选，无额外外置 picker；分类树和日期范围保持原语义 |
| 年份 | `UtenYearSelectionButton` → `showUtenYearPicker` → 原 `UtenDateRangePickerDialog.yearOnly`，客户/供应商年度对账同一调用 | 年选择不借用一个虚构月份/日期；工资表单年份仍为其业务字段，不把普通年/月输入强改成年度对账查询 |

金融新建表单作用域迁移不修改 `financeGridColumns` 的数量、单价、金额、单位和来源算法。已知日期/人员事实与选择引用各自保留用途。财务审核只读来源与普通报表不被批量套入选中样式。

## 币别合同

`FinanceAuxiliaryReports` 原14列原始名称和相对次序保留，只在往来名称后插入“币别”。币别来自真实 `currency_id`，分面及过滤使用 `__currencyId`，相同显示名的不同币种身份不相并。总账金额仍取原 `amount_local`，不是把本币金额改成对应列头的原币金额；列头提示明确这一点。

所有读取、候选、合计、导出、打印复用 `FinanceProjectedReportTable` 的同一投影和过滤。前端不再传辅助报表的旧隐藏 `currencyId`，导入原明细表取已选币别列头 UUID。未知币别/期初/期间完整性继续未知，不补零；原始会计导入模板未改名、未改列顺序或造出另一金额源。

## 年份等待与退休

打开/取消年选择只发生交互，不发报表请求、不叠 busy。确认后由 `FinanceStatementPage._persistAndReload`、`_loadGeneration`、`ReportPagedRead` 和原有 `UtenBusyOverlay` 接管读取、旧代次退休及失败收尾。当前调用不返回第二个异步等待给按钮，因此同一动作只用页面已有等待件；不重放写入。取消返回 null，已有查询和完整结果不因打开选择器被清空。

## 验证与原始失败

- 首轮8套 Flutter 104项通过：`build/finance-feedback-tests-initial.log`；后继三套63项通过：`build/finance-feedback-tests-final.log`。两轮重叠，不加总。
- 扩大到19套后205项通过、1项失败：`build/finance-feedback-scoped-all-entry-tests.log`。失败为旧原生菜单测试没有滚动到新公共菜单中的尾项；保留截图和失败日志。
- 后继6套公共/筛选验证47项通过、1项原有显式skip（人员多选 + label hydration 原用例组合）：`build/finance-feedback-filters-passed.log`。覆盖主档、人员、部门和下拉选择的角色、已选回显、竞态、窄屏/深色/大字体，以及总览四个窗口与200%缩放的真实菜单操作。失败后按菜单内 Scrollable 完成实际滚动选择，未改成直接调用回调。
- 新主档筛选在桌面曾被原 IconButton 的 padded 48px 触控框撑高，与36px搜索不齐；在 filter role 内改为共享36/48角色和 shrinkWrap，普通表单保持原角色。原始失败 `finance-feedback-filters-final.log`、`finance-feedback-filters-rerun.log` 保留。
- 后台真 PostgreSQL 46项通过：`server/target-finance-feedback-run.log`；追加同名不同 UUID 隔离后，同一 Completeness 文件3项通过：`server/target-finance-feedback-currency-final.log`。两轮有2项重叠。验证真实币别列、UUID筛选/分面、金额完整性、原有投影/原币合同。
- 最后4套 owner 回归77项通过：`build/finance-feedback-final-owner-regression.log`，覆盖最终显式视觉作用域、aux币别无隐藏查询、五类录入附件、1000快速编辑与未知提交；与早先轮次重叠。
- 年度真实业务owner专项1项通过：`build/finance-feedback-year-owner-passed.log`，验证取消无请求、交互阶段不叠busy、确认后只有原页面等待件、year=2025查询及结束收尾。新增测试首轮在退出动画100ms时过早检查弹窗已销毁；等待既有退出动画400ms后通过，未改生产等待或直接调用回调。原失败 `build/finance-feedback-year-owner-test.log` 保留。
- 全财务和本组公共入口静态检查无问题：`build/finance-feedback-final-analysis.log`。新增测试的无效非空断言与 if 花括号已修；测试源静态检查另记 `build/finance-feedback-final-test-analysis-passed.log`。
- 年选择与已选字段截图：`build/ui-audit/year-selector-{1440,375}.png`、`selected-filter-{1440,375}.png`；已查看窄屏深色年选择和宽屏已选字段。业务页面多视口截图在 `output/finance-redesign/previews/`。均为匿名夹具，不替代公司数据核账。

本组产品源码已冻结，测试和上述匿名截图已核对。统一 Web/Windows 实际运行、源码整合和整组交付结论由根任务追加；本文件不预先把仍在运行的检查记成通过。

## 多端

Flutter Web 与现有 Flutter 桌面共享这些 owning 页面、视觉作用域和服务端合同。WPF 对应任务 `W7-BIZ-057/058/064/072/077/078/230/231` 仍为 todo、`nativeTargets=[]`，本次没有已迁移的同责金融表单可同步，不开放原生占位写入口。公共角色没有修改共享生成 token。后续原生迁移须保留已选引用、附件/未知提交恢复、币别UUID与本币金额区别、年度取消/读取owner语义。完整 ERP/Win7目标机和正式产物验收不因本次 Flutter/PG 结果改变。
