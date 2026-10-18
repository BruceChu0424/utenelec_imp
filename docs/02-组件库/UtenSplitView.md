# UtenSplitView（左右分栏 + 可拖动分割线）

> 路径：`lib/components/layout/uten_split_view.dart` · 测试：`test/uten_split_view_test.dart`、`test/components/uten_list_two_pane_test.dart`
> 已接入：货品资料 / 客户分类 / 供应商分类 / 模具分类 / 部门管理 / 我的部门 / 应收应付 / 权限管理 / 货品选择滑窗（2026-09-24，见 [UtenGoodsPicker](UtenGoodsPicker.md)）；2026-09-03 起另经 `UtenListTwoPane` 内部实现覆盖 15 个「左筛选 + 右表格」页（财务单据/对账/报表/往来/钱流/应付、生产计划与报表、where-used、采购/销售/委外/仓库报表），另有生产计划向导（步骤栏）、IQC 拒收详情（事实/流转 3:2）直接接入。**大屏左右双栏一律走本组件（或 UtenListTwoPane），禁止再写固定宽 `Row(SizedBox(width:…), Expanded)` 双栏**（准则 §2 布局统一口径）。

## 一、解决什么

「左分类树 + 右详情」类页面原本是各页各写一套固定布局：

```dart
Row(children: [
  SizedBox(width: 300, child: 左树),
  Container(width: 1, color: outlineVariant), // 1px 分割线，不可调
  Expanded(child: 右详情),
])
```

左栏宽度写死 300：窗口大浪费、树名长不够看，且同一套结构在 8+ 页面重复。
UtenSplitView 把这套布局下沉为统一组件：**分割线可左右拖动**，两栏大小随拖随变。

## 二、交互

| 操作 | 行为 |
|---|---|
| 常驻握把 | 中央始终可见的圆角小块 + 抓握纹（2×3 圆点），一眼示「可拖」（触屏无 hover 也能看出） |
| 悬停分割线 | 出 `resizeColumn` 光标；线加粗染 primary；握把染主色并轻微放大 |
| 左右拖动 | 可主动缩到 `minLeadingWidth` 与行内操作安全宽度的较大值；长名称省略并保留完整路径提示，右栏保底 `minTrailingWidth` |
| 双击分割线 | 清除手动宽度偏好，按 `initialLeadingWidth` 和分类完整单行自然宽重新适配 |
| 聚焦后 ←/→ | 每次 ±16px（无鼠标 / 无障碍场景） |
| RTL | 拖动与箭头方向自动翻转 |

命中区 12px（视觉线 1px 居中），手感对齐 `master_data_table_view` / `uten_editable_grid` 的列宽拖拽。

## 三、用法

```dart
UtenSplitView(
  persistenceKey: 'basicData.goods', // 保留既有偏好key
  minTwoPaneWidth: 840,             // 主档页按实际内容宽度回退
  selectedLeadingLabel: selectedPath,
  selectedLeadingKey: selectedId,   // 业务ID；不按名称合并节点
  compactHeader: unifiedSearch,
  leading: _buildTree(...),          // 左面板（分类树 / 列表）
  trailing: selected == null ? 空态 : _DetailPane(...), // 右面板（占满剩余）
)
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `initialLeadingWidth` | 300 | 初始宽，也是双击复位值（对齐旧版固定宽） |
| `controlledLeadingWidth` | null | 可选的共享左栏宽度；非空变化同步到当前分栏，仍遵守布局宽度边界 |
| `minLeadingWidth` | 220 | 手动缩窄的最小宽基准；同时保留行内按钮、计数和可读标题片段 |
| `maxLeadingWidth` | 520 | 常规最大宽；自然宽更大时允许平滑从自然宽向左拖，并继续保留右栏最低宽度 |
| `minTrailingWidth` | 360 | 右栏保底宽：不足时切为单内容区和完整目录 |
| `persistenceKey` | null | 传页面级唯一 key → 宽度存本地 shared_preferences（`uten.splitView.<key>`），下次进页面自动恢复 |
| `onWidthChanged` | null | 宽度变化回调 |

宽度记忆只走本地、不走服务端偏好：像素宽与设备屏幕相关，跨端同步无意义。

`controlledLeadingWidth` 默认为 null，保留各分栏原有的独立拖动和本地偏好恢复。
需要跨模式同步时，由页面保存 `onWidthChanged` 的值并传给各分栏；不用重挂载内容，
选中对象、未保存草稿和输入状态均可保留。受控宽度视为显式选择的宽度，保留行内操作的安全下限；
它优先于本地恢复，迟到的偏好读取不能覆盖已经同步的宽度。账号与权限管理页通过
`AdminPermissionWorkspaceScope` 共享员工、部门、全员基础包的宽度。
接口回归见 `test/uten_split_view_controlled_width_test.dart`，跨模式拖动与草稿回归见
`test/features/admin/admin_permissions_layout_test.dart`。

## 四、边界与注意

- 界面与交互修改默认使用 `frontend-design`，沿用现有 Uten 组件、主题及业务约束。
- 回退由共享`UtenAdaptiveHierarchyPane`统一处理，判定使用`LayoutBuilder`实际内容宽度，
  不是整屏宽度。两栏所需宽度至少为`max(minTwoPaneWidth, 实际左栏下限 + 12 + minTrailingWidth)`。
  主档页使用840；选择器默认600并继续检查左右最低宽度。未手动调整时使用完整标题自然宽；
  手动调整后使用控件安全宽度，不因长标题强行撑回。空间不足仍回退目录入口，不产生负宽度。
- 窄屏正文显示当前完整路径和目录入口，目录在本面板内全宽打开。
  树与内容通过稳定key保持挂载；关闭、返回、Escape或明确选树行后回到原内容。
  搜索自动定位、计数返回、权限刷新不会自动关闭目录；大缩放后按新的有效宽度重排。
- `leadingNoun`、`selectedLeadingLabel`、`compactHeader`、`openLeadingButtonKey`
  为窄屏入口的配置；分类、部门、权限资源及事实面板应使用各自准确文案。
- 窄屏正文可用高度小于共享断点600时，`compactHeader`与目录入口复用
  `UtenCollapsingHeaderScrollView`的整页滚动契约，正文保留至少360高度及独立内滚。
  `UtenHierarchyTreeView`在短高度下将完整搜索/加载/错误区与节点一起滚动；
  正常高度仍固定搜索区。隐藏但保持挂载的目录与正文也必须安全布局。
  跨高度重排保留输入焦点、中文输入组合、目录展开、选中状态和正文元素。
- 依赖父容器给出有界宽度（页面 body 天然有界）。
- 各页面已使用的 persistenceKey：`basicData.goods`、`basicData.client`、
  `basicData.supplier`、`basicData.mould`、`department.manage`、
  `department.mine`、`finance.arAp`、`admin.permissions`、
  `goodsPicker.categoryTree`（货品选择滑窗左树，2026-09-24 起；`initialLeadingWidth`
  传全树最长行的 TextPainter 实测宽，实现「默认划分 = 左边最宽内容」）。新页面接入请起新 key。
- 与 `UtenListTwoPane`（筛选 + 表格）的区别：UtenListTwoPane 自 2026-09-10 起**所有断点都是「筛选在上 / 表格在下」**（列表页表格要横向空间，筛选窄栏会压表格），本组件只服务分类树主档页的「树 + 详情」左右分栏。以下旧描述保留作背景：UtenListTwoPane 曾是断点驱动的
  筛选侧栏布局；UtenSplitView 是「树 + 详情」的可拖分栏。需要拖宽的用本组件。


## 五、分类树可读性与验证

全站分类/组织树共用`UtenHierarchyTreeView`。长名称允许换行；缩进最多占行宽12%，
深层与无缩进模式同时显示层数和父分类，选中项显示完整祖先路径，颜色只作辅助。
窄行把计数、部门徽标和操作移到下一行；展开和删除图标保留小视觉，触控命中至少48。
分类默认宽度测量使用实际TextScaler，业务UUID、排序、权限谓词、搜索与上下文操作保持原来源。

验收：160/320/375/600/768/840/960/1440逻辑宽度，100%至200%缩放，10层树、长名称/编码、
同名不同ID、搜索慢请求、选择后关闭、跨断点展开/内容状态保留、权限撤销、多选确认与取消。
新增压力回归在`test/components/layout/uten_adaptive_category_layout_test.dart`，
原刷新/分页/搜索竞态测试继续保留业务断言。

短高度回归见`test/shared/widgets/uten_hierarchy_short_viewport_test.dart`：
179高度、1.5倍文字、长错误提示、相关开关、目录开关、节点/结果选择及700↔179高度切换。
完整物料反查交互回归保留844×390横屏场景，覆盖选择物料和返回报表的过程。


## 六、2026-10-13 消费者覆盖

| 层 | 消费者 |
|---|---|
| 主档分类壳 | 客户、模具、货品、供应商资料四页 |
| 其它分类页 | 即时库存、应收应付、收付款类别 |
| 组织页 | 部门管理、我的部门 |
| 两栏选择器 | 货品选择、客户/供应商/模具共用主档选择、部门员工选择、共享员工选择、页面权限选人 |
| 非分类分栏 | 权限资源管理、IQC拒收案件事实/办理；各自声明准确入口文案 |
| 单树面板与编辑 | 货品分类选择面板、分类编辑、收付款类别父级选择、部门选择与编辑；通过共享树改善长名和深层阅读 |

分类分段覆盖68个`UtenFilterToolbar`消费者文件、10个直接`UtenSegmentRow`消费者文件和14个
`UtenSegmentedFilter`消费者文件；共享适配无需按业务页复制。销售接单审核原非flex Row已改为
窄宽上下排布、宽宽给分类真实有界宽度；AppBar分类中央区域由共享AppBar提供真实局部约束。
未更改仓储调用、业务模型、权限谓词、数量统计、UUID选择和确认流程。

## 七、2026-10-13 分类行与拖动下限修正

分类树的展开箭头、名称、徽标与选择控件始终同行居中。叶节点保留同尺寸展开空位，
同层文字起点一致；展开后只显示原分类标题，不额外显示层数或父级副行，完整路径保留在提示中。

`UtenHierarchyContentWidthScope` 统一收集分类标题与实际行内控件尺寸，
包含文字缩放、触屏点击区域、复选框、选中标记、内边距和滚动条余量。
完整标题自然宽用于首次展示和双击复位；2026-10-17 起，用户拖动、键盘微调和恢复已存偏好
可主动缩窄名称区域，长标题使用现有省略号和完整路径提示。行内操作安全宽度独立保留，
不会把选中标记移到下一行；空间不足时仍改为完整目录入口。

页面表格只保留内部行列分隔线，统一表格表面及冻结操作列最外缘不绘制外框；
圆角裁切与单元格交互反馈保持。

## 八、手动宽度与默认适配

最长分类名称不再作为手动拖动的硬下限。共享组件保持两种状态：未调整时按完整内容适配；
拖动或键盘调整后记住用户宽度，分类展开、滚动到长名称、搜索和数据刷新不会按标题自然宽
重新撑大左栏。行内按钮、计数及按文字缩放的标题片段仍决定安全下限。

保留 `uten.splitView.<persistenceKey>` 键和已有数值偏好，重进页面恢复主动选择的宽度。
双击清除该偏好并回到自动适配；迟到的偏好读取不得覆盖新拖动或另一页面的宽度。
货品、客户、供应商、模具及其它复用 `UtenSplitView` 的树形分栏遵循同一交互。
