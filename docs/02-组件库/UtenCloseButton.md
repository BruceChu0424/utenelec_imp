# UtenCloseButton 与窗口控制

按 `frontend-design` 和项目公共能力规范维护。用户于 2026-10-28 明确要求所有平台沿用 Windows 登录页的红色圆形关闭样式。

## 公共入口

源码：[`uten_close_button.dart`](../../lib/components/buttons/uten_close_button.dart)。

## 相邻分组与顺序

用户最新明确：关闭必须位于最右侧。所有平台统一从左到右为 **最小化 → 展开/还原 → 关闭**，使用 `UtenWindowControls` 作为一个不可拆分的紧凑组。此修正覆盖此前曾提出的 macOS 排列要求。有两个控件就只显示这两个，有三个就显示三个；不存在的控件不留空位。下载、刷新、文件类型等业务工具放在整个组外，禁止插在窗口按钮之间。

组内不加 Spacer、Padding 或额外间距。普通桌面按钮命中宽 36dp、圆形 28dp，相邻圆形仅 8dp 间隔；原生控制条保留 30×36dp 命中区与 22dp 圆形，同样为 8dp 间隔。触控场景继续保留至少 48dp 的独立命中区。整组放在窗口或标题栏右侧，关闭始终是最右一个控件，组内顺序始终一致。

```dart
UtenWindowControls(
  onClose: busy ? null : closePreview,
  showExpand: true,
  expanded: fullscreen,
  onExpand: busy ? null : toggleFullscreen,
  expandTooltip: fullscreen ? exitFullscreenLabel : fullscreenLabel,
)
```

| 角色 | 组件 | 视觉 |
|---|---|---|
| 关闭窗口、预览、侧栏、弹窗、通知 | `UtenCloseButton` | `UtenColors.error` 红色实心圆 + 白色圆角 × |
| 最小化、收起为浮球 | `UtenWindowControlButton.minimize` | `UtenColors.warning` 黄色实心圆 + 白色减号 |
| 最大化、全屏、还原 | `UtenWindowControlButton.expand` | `UtenColors.success` 绿色实心圆 + 白色展开/还原图标 |
| 页面返回 | 既有 `UtenBackButton` | 用户已选定的品牌青色实心圆 + 对比色返回箭头 |

关闭按钮必须放在标题栏最右端，全屏路由的关闭也使用右侧 actions，不能占用左侧 leading。左侧仅保留既有返回导航。`UtenAppBar` 将关闭和窗口控件组固定在业务动作、权限工具与“更多操作”之后，窄屏也不折入操作面板。`UtenDialogHeader`、`UtenPanelHeader`、`UtenFloatingWindow` 已组合本组件，业务页面优先复用这些标题栏。

Windows、macOS、Linux、Android、iOS 和 Web 的应用内界面使用相同颜色、圆形和图标。普通按钮可见圆形 28dp、图标 18dp，桌面命中区默认 40dp；触控平台或窄屏至少 48dp，缩小界面时通过 `UtenControlMetrics` 补偿。既有明确 48dp 的入口继续用 `desktopHitExtent: 48`。

`native: true` 仅用于现有桌面原生控制条，保留登录页 22dp 圆形、14dp 图标、30×36dp 命中区。Windows、macOS 和其他平台的组内顺序均为最小化、展开/还原、关闭，整组位于右侧，关闭在最右端。Web、手机弹窗无需额外的操作系统窗口按钮。文件选择器等系统拥有的界面遵循系统本身。

## 用法与行为

```dart
UtenCloseButton(
  tooltip: l10n.companyFilesClose,
  onPressed: busy ? null : closeWithExistingDraftGuard,
)

UtenWindowControlButton.expand(
  expanded: fullscreen,
  tooltip: fullscreen ? exitFullscreenLabel : fullscreenLabel,
  onPressed: busy ? null : toggleFullscreen,
)
```

`onPressed` 必须显式提供，类型为 `FutureOr<void> Function()?`，允许为 `null`。组件不决定 `Navigator.pop`、返回值、未保存确认、身份权限检查或网络请求；它等待回调返回的 Future 并防止重复激活，避免一次草稿退出确认导致连续 pop。空回调或执行中直接禁用，绝不自动执行返回。禁用颜色来自主题；键盘聚焦有描边，继承 `IconButton` 的键盘激活和按钮语义。

预览的下载使用既有 `UtenButton` 的 tonal/small 样式、下载图标和本地化“下载”文字，保留加载动画及重复提交守卫；下载位于窗口控件组外，排在整组左侧。

默认关闭提示来自 `MaterialLocalizations`，已有业务文案通过 `tooltip` 传入。原生最小化和最大化提示集中保留中英韩三语。没有 Overlay 的通知宿主可使用 `showTooltip: false`，保留无障碍标签。

## 语义边界

- 所有真正用于退出窗口、弹窗、预览或面板的“关闭”都使用右上角公共控件，原来位于底部的文字“关闭”也迁入标题栏；已有公共标题关闭时移除重复页脚关闭。
- 表单决策“取消”、取消后台任务、业务驳回等保留各自动作语义。混合状态只有在显示真正的关闭时才使用公共关闭，保留原来的 `false/null` 结果和忙碌禁用。
- 删除行、移除附件或权限规则、清空搜索/筛选、退出多选、驳回业务、取消订单和状态图标不属于窗口关闭，不能因图标同为 × 而改成红色窗口控件。
- 关闭、Esc、遮罩、返回键及忙碌状态仍由原宿主控制；公共样式不扩大可关闭时机。

`UtenAlertDialog` 支持 `closeEnabled`、`closeButtonKey`、`closeTooltip`，用于保留迁移前的禁用、测试定位和本地化合同；无标题时也能呈现公共关闭。`UtenAppBar` 对 `Padding`、`Align`、`SizedBox`、`Row` 和公共动作行中的窗口控件统一提取到右端，业务动作继续使用原溢出规则。

通知里的关闭与纯阅读回执分别通过 `cancelAsClose`、`confirmAsClose` 显式迁入标题。二者保留原来 `false/true` 结果和回调；默认均关闭，不为需要确认的提醒增加退出路径。打印预览标题和关闭固定在滚动区外，查看纸面后关闭仍可直接点击。

纯说明用途的 `UtenDialog.show(confirmAsClose: true)` 也使用标题关闭，保留原确认回执、`onConfirm`、`onPopped` 和路由退出等待；默认确认模式不变。说明弹窗、庆典、AI 信息提示、服务切换说明等纯退出入口统一使用公共关闭；需要记录已读、批准或其他业务事实的明确确认保留决策语义。

## 自动防回退检查

[`audit_window_controls.dart`](../../scripts/audit_window_controls.dart) 解析全部应用 Dart 源码及 ARB 文案，检查旧原生关闭、自写关闭/纯退出按钮、左侧关闭、关闭后仍有其他控件及需要复核的居中关闭。检查同时识别条件文案、本地化别名和私有动作包装。全量接入清单与当前守卫写入审计 JSON。

[`window_close_source_contract_test.dart`](../../test/core/window_close_source_contract_test.dart) 包含负向样例和仓库扫描，自动进入既有 `flutter test --no-pub` 门禁。删除、清空、业务结案和状态图标的精确例外记录在 [`window_controls_exceptions.json`](../../scripts/window_controls_exceptions.json)，按路径、所有者、标准化 AST 摘要、数量和理由匹配；没有整文件豁免，新入口或回调变化必须重新核对。

本次最终扫描 1718 个源码文件，无未分类关闭控件、过期例外或解析错误。源码审计和组件/业务回归共同验证当前实现，不替代真实员工验收或所有操作系统真机检查。

验证包含全 `TargetPlatform` 配置的深浅主题、键盘激活、禁用、原生几何和窄屏触控尺寸，以及登录控制条、公共弹窗、浮窗、通知、公司资料库预览和业务调用方的现有回归。完整本轮清单见[跨平台窗口控件统一检查](../99-项目治理/2026-10-28-跨平台窗口控件统一检查.md)。
