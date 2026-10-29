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

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-UI-004

- [ ] **公共表格完整交互** — 进行中

影响：`frontend`；负责人：Codex；依赖：W7-ENV-001, W7-GOV-002。

源入口：`lib/core/theme/uten_tokens.dart`；`clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Controls.xaml`。

完成条件：

1. 自然行高、表头/单元格角色、虚拟化、列宽/排序/筛选/多选/快捷键、状态保存。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

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

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

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
