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
| 左右拖动 | 最小宽为配置值与分类完整单行实测宽的较大值；右栏保底 `minTrailingWidth` |
| 双击分割线 | 复位到 `initialLeadingWidth`，仍遵守完整单行下限 |
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
| `minLeadingWidth` | 220 | 左栏最小宽基准；不能覆盖共享树的完整单行下限 |
| `maxLeadingWidth` | 520 | 常规最大宽；完整单行下限更大时优先保留内容，并检查两栏是否能同时容纳 |
| `minTrailingWidth` | 360 | 右栏保底宽：不足时切为单内容区和完整目录 |
| `persistenceKey` | null | 传页面级唯一 key → 宽度存本地 shared_preferences（`uten.splitView.<key>`），下次进页面自动恢复 |
| `onWidthChanged` | null | 宽度变化回调 |

宽度记忆只走本地、不走服务端偏好：像素宽与设备屏幕相关，跨端同步无意义。

## 四、边界与注意

- 界面与交互修改默认使用 `frontend-design`，沿用现有 Uten 组件、主题及业务约束。
- 回退由共享`UtenAdaptiveHierarchyPane`统一处理，判定使用`LayoutBuilder`实际内容宽度，
  不是整屏宽度。两栏所需宽度至少为`max(minTwoPaneWidth, 实际左栏下限 + 12 + minTrailingWidth)`。
  主档页使用840；选择器默认600并继续检查左右最低宽度。空间不足不再压窄树或产生负宽度。
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

`UtenHierarchyContentWidthScope` 统一收集分类标题与实际行装具尺寸，
包含文字缩放、触屏点击区域、复选框、选中标记、内边距和滚动条余量。
拖动、键盘微调、双击和恢复旧偏好都遵守这一真实下限；空间不足时改为完整目录入口，
不通过把选中标记移到下一行或压窄分类来挤出双栏。

页面表格只保留内部行列分隔线，统一表格表面及冻结操作列最外缘不绘制外框；
圆角裁切与单元格交互反馈保持。
