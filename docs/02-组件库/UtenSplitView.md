# UtenSplitView（左右分栏 + 可拖动分割线）

> 路径：`lib/components/layout/uten_split_view.dart` · 测试：`test/uten_split_view_test.dart`、`test/components/uten_list_two_pane_test.dart`
> 已接入：货品资料 / 客户分类 / 供应商分类 / 模具分类 / 部门管理 / 我的部门 / 应收应付 / 权限管理；2026-09-03 起另经 `UtenListTwoPane` 内部实现覆盖 15 个「左筛选 + 右表格」页（财务单据/对账/报表/往来/钱流/应付、生产计划与报表、where-used、采购/销售/委外/仓库报表），另有生产计划向导（步骤栏）、IQC 拒收详情（事实/流转 3:2）直接接入。**大屏左右双栏一律走本组件（或 UtenListTwoPane），禁止再写固定宽 `Row(SizedBox(width:…), Expanded)` 双栏**（准则 §2 布局统一口径）。

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
| 左右拖动 | 实时改左栏宽；clamp 在 `[minLeadingWidth, maxLeadingWidth]`，且右栏永远保底 `minTrailingWidth` |
| 双击分割线 | 复位到 `initialLeadingWidth` |
| 聚焦后 ←/→ | 每次 ±16px（无鼠标 / 无障碍场景） |
| RTL | 拖动与箭头方向自动翻转 |

命中区 12px（视觉线 1px 居中），手感对齐 `master_data_table_view` / `uten_editable_grid` 的列宽拖拽。

## 三、用法

```dart
UtenSplitView(
  persistenceKey: 'basicData.goods', // 可选：本地记住用户拖定的宽度
  leading: _buildTree(...),          // 左面板（分类树 / 列表）
  trailing: selected == null ? 空态 : _DetailPane(...), // 右面板（占满剩余）
)
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `initialLeadingWidth` | 300 | 初始宽，也是双击复位值（对齐旧版固定宽） |
| `minLeadingWidth` | 220 | 左栏最小宽 |
| `maxLeadingWidth` | 520 | 左栏最大宽（另受右栏保底约束） |
| `minTrailingWidth` | 360 | 右栏保底宽：极窄窗口也不会把详情拖没 |
| `persistenceKey` | null | 传页面级唯一 key → 宽度存本地 shared_preferences（`uten.splitView.<key>`），下次进页面自动恢复 |
| `onWidthChanged` | null | 宽度变化回调 |

宽度记忆只走本地、不走服务端偏好：像素宽与设备屏幕相关，跨端同步无意义。

## 四、边界与注意

- **compact 断点的抽屉回退仍由页面自己处理**：本组件只替换「分栏分支」，
  各页面原来的 `if (bp == compact) → endDrawer` 逻辑不动。
- 依赖父容器给出有界宽度（页面 body 天然有界）。
- 各页面已使用的 persistenceKey：`basicData.goods`、`basicData.client`、
  `basicData.supplier`、`basicData.mould`、`department.manage`、
  `department.mine`、`finance.arAp`、`admin.permissions`。新页面接入请起新 key。
- 与 `UtenListTwoPane`（筛选 + 表格）的区别：UtenListTwoPane 是断点驱动的
  筛选侧栏布局；UtenSplitView 是「树 + 详情」的可拖分栏。需要拖宽的用本组件。
