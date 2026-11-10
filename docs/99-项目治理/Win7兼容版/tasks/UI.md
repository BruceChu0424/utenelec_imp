# Uten同源界面与交互

由唯一进度登记表生成。

## W7-UI-001

- [ ] **设计tokens生成与漂移门** — 源码已实现/待整合验证

影响：`frontend`；负责人：待认领；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 圆角/间距/配色/字号/控件几何取owning Dart源，有provenance，手改或源变化会失败。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-UI-002

- [ ] **窗口与真实圆角裁切** — 源码已实现/待整合验证

影响：`frontend`；负责人：待认领；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 控件10/表格12/卡16/对话框20按角色；子内容真裁切、Win7 GDI区域、无句柄泄漏。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-UI-003

- [ ] **表单/密码/下拉/校验控件** — 源码已实现/待整合验证

影响：`frontend`；负责人：待认领；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 尺寸和字段提示一致，显示名称不泄露类型名、无双padding，IME/焦点/禁用和验证可用。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/date-range-entry-20261103.json`；`clients/windows_legacy/progress/evidence/finance-entry-ui-20261103.json`；`docs/99-项目治理/2026-11-10-截图批注补齐与本地主链整合.md`。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。；2026-11-03：新增公共UtenDateRangeDialog，年月标题可直达年份和月份；日期边界、单日、开放起止、取消/清除与快速反复切换均有本机交互证据。复用同源主题及标题右侧红圆白X；此为公共日期增量，不提高全部表单控件或Win7目标机完成状态。见 E-DATE-RANGE-ENTRY-20261103。；2026-11-03 财务录入与公共表格增量：费用/收入项目同源新增及即时回显、备注末列、正常字号汇总、完整查询文本候选、表格工具栏日期及历史门控。来源、权限、精确金额、草稿及未知提交保留；完整调用清单见finance-entry-ui-20261103证据。 WPF已有单位修改历史日期同步同排40高按钮，范围仅留提示；本机x86/x64各dates37/history UI13通过。 完整ERP、Win7目标机与正式分发未验收；原状态、负责人、DoD及历史证据保留。；2026-11-10 补交11图：既有WPF日期窗口同步实际日期大字主色标题、零填充日期范围；x86/x64本机日期及历史控件检查通过，Win7真机与完整业务状态不提升。。

## W7-UI-004

- [ ] **公共表格完整交互** — 进行中

影响：`frontend`；负责人：Codex；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 自然行高、表头/单元格角色、虚拟化、列宽/排序/筛选/多选/快捷键、状态保存。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/Uten.Legacy.Tests/UiContractChecks.cs`；`clients/windows_legacy/progress/evidence/screenshot-feedback-20261110.json`。

接续/限制：2026-11-07 表格列宽增量：现有原生货品、单位主表、行内、批量结果、导出任务、表头及自设值、历史和本机恢复表均使用 UtenDataGrid。默认按实际表头与可见单元格测量，包含图标、内边距和控件；查询替换时重新测量 Auto 列，保留手动像素宽度、编辑控件最小尺寸及并排修改前后比较。单位偏好留空列保持自适应。x86/x64 /warnaserror 本机编译及实际窗口列宽与 UI 合同通过，包含 10000 行虚拟滚动、窄窗口横滚、结果替换及显式宽度。销售详情、编辑、进度、财务和物料分析原生入口待迁移；Win7 真机及 W7-UI-004 完整 DoD 待验。 2026-11-07 更新表头分隔线。上述已迁移的 UtenDataGrid 入口共用原生缩放手柄，分隔线两侧各 10 DIP，使用左右调整光标。悬停时 Uten 主色竖线加粗，拖动期间维持高亮。排序、重排、双击自适应及宽度限制沿用原生处理。本机 x86/x64 的表格契约与 Aero、Classic 原生模板夹具验证了命中范围、悬停、高亮位置、调整与取消。车间任务 W7-BIZ-115 仍待迁移，Win7 真机待验；2026-11-10 E-SCREENSHOT-FEEDBACK-20261110：公共空表/横滚及终身使用货品删除合同。完整入口、公共实现、真实运行时与保留差异见docs/99-项目治理/2026-11-10-十四张截图反馈修复.md。任务原status/owner/DoD/依赖/nativeTargets保留；Flutter或服务端通过不等于本项原生业务、Win7目标机或正式交付完成。。

## W7-UI-005

- [ ] **公共层级树及选择器** — 未开始

影响：`frontend`；负责人：待认领；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. UUID关系、层级指引、懒加载/展开/同级Ctrl切换、选中保留和弹层行为一致。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-UI-006

- [ ] **对话框/详情/浮层导航** — 进行中

影响：`frontend`；负责人：Codex；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 统一20/16/12角色，取消/返回/焦点/二次操作保护，窗口和详情页一致。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-UI-007

- [ ] **状态/数量/来源呈现** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 逐模块显式状态映射，文字与底色配套，未知与零分开，不按文案猜业务状态色。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-UI-008

- [ ] **缩放/DPI/字体/低分辨率** — 进行中

影响：`frontend`；负责人：Codex；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 100/125/150%及系统/应用缩放，caption独立几何、老GPU/低内存不裁切或卡住。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/entry-scrollbar-window-20261103.json`。

接续/限制：；2026-11-03 入口页滚动栏增量：已有 DashboardView 接入 UtenEntryPageScrollBehavior，读取同源生成的 desktopStart=1280，窄屏/平板隐藏竖栏且保留触摸平移和滚轮；文档/编辑页与宽屏原栏保持。x86/x64 实际STA调用方9种宽度、400行、60次切宽、卸载恢复及编辑页隔离通过；触屏真机/Win7与完整工作台迁移仍未验，不提升本项原状态。证据 E-ENTRY-SCROLLBAR-WINDOW-20261103。。

## W7-UI-009

- [ ] **键盘/鼠标/复制/可访问性** — 未开始

影响：`frontend`；负责人：待认领；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. Tab/Enter/Escape/快捷键/右键/选择和工具提示，与当前有效组件行为对照。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-UI-010

- [ ] **路由/深链/返回与标签生命周期** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 参数/returnTo/来源恢复、多个实体实例、保留输入及权限退役，不统一导航到占位页。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-UI-011

- [ ] **主题/公司品牌与语言** — 未开始

影响：`frontend`；负责人：待认领；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 浅/深色、公司覆盖、字体fallback和中英韩等现役语言逐项对照。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-UI-012

- [ ] **跨版本视觉与交互对照** — 未开始

影响：`frontend`；负责人：待认领；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 相同数据/权限/窗口尺度对照Flutter与WPF；保存截图、操作路径和差异结论。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-UI-013

- [ ] **客户端发布工作台全宽队列与自适应布局（下一版）** — 未开始

影响：`frontend`；负责人：待实施；依赖：W7-CORE-023, W7-UI-001, W7-UI-012。

源入口：`lib/features/client_update/client_release_publish_page.dart`；`test/features/client_update/client_release_publish_test.dart`。

完成条件：

1. 迁移本批联动范围提示、全宽队列与可展开配对/草稿说明，保留Uten同源主题和既有原生键盘操作。
2. 以宽窄窗口、明暗主题、100%/200%字体和目标机DPI对照Flutter，状态结果与主操作自适应排布，不挤窄说明或遮挡关键动作。
3. 保留CORE-023的冻结、原ID核对与成功禁重传合同；完整实际交互和Win7目标机验收前保持未完成，不把旧215或仅编译证据充作新版UI通过。

证据：`docs/99-项目治理/2026-11-01-客户端发布工作台批设置与恢复.md`。

接续/限制：新布局尚未迁移到WPF；共享行为增量归CORE-023。独立下一版，不纳入2.5.39，不授权正式打包或发布。；2026-11-01：本轮已授权纳入2.5.42适用功能；原2.5.39排除仅属历史范围。原生布局及目标机验收边界不变。。
