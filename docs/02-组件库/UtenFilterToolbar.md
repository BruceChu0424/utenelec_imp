# UtenFilterToolbar

> 源码：`lib/components/layout/uten_filter_toolbar.dart`
> 创建：2026-09-01（全平台「分类筛选 + 搜索」统一范式）
> 相关：[UtenSearchBar](UtenSearchBar.md) · UtenSegmentBadgeLabel（`components/feedback/`）

## 一、定位

页面上凡有「分类/状态筛选」的地方一律用本组件，不再手写筛选按钮、Chip 行或
自成一套的分段样式：

- **分段导航**：M3 胶囊 StadiumBorder、**选中只变背景色不出 ✓ 图标**，
  与搜索框**结构化严格同高**（宽屏行内 `IntrinsicHeight + stretch`，谁高都拉齐；
  密度/字号档变化下恒成立——visualDensity 对两侧折减不一致，不能靠各自设高度）；
- **计数徽章**：分段可挂数量（`count`），红色圆数字（`UtenSegmentBadgeLabel`），
  与工作台角标同款；`count == null`（加载中/未知）与 `≤ 0` 都不显示——不把
  「未知」伪装成 0，`> 99` 显 `99+`。计数须取该分段**全量口径**（非当前页推算）；
- **搜索框**：全平台唯一组件 `UtenSearchBar`（胶囊 + 清除 + 300ms 防抖），
  `searchHint` 不传且无 controller 时不渲染（纯分类工具条）；
- **响应式**：宽屏一行 `分段 | 搜索 | 弹性 | trailing`；窄屏（默认 < 840）分段
  横向滚动 + 搜索换行。

## 二、用法

```dart
UtenFilterToolbar<String>(
  segmentsKey: const Key('iqc-type-segments'),   // 透传测试/语义锚点
  searchKey: const Key('iqc-search'),
  segments: [
    UtenFilterSegment(value: 'all', label: '全部待检单', count: totalCount),
    UtenFilterSegment(value: 'purchase', label: '采购收货', count: purchaseCount),
  ],
  selected: selected,
  onSelectionChanged: (value) => _selectType(value),
  searchHint: '搜索单号 / 供应商',
  initialSearchValue: _keyword,
  onSearchChanged: _applySearch,        // 300ms 防抖（异步检索）
  // onSearchInputChanged: _onInput,    // 同步（本地即时过滤）
  trailing: Text('共 ${items.length} 条'), // 宽屏行尾
)
```

范本实现：`quality/pages/quality_pending_disposal_page.dart`（待检处置）与
`production_fqc_inspections_page.dart`（生产成品质检）。

## 三、约定

- 回调语义由调用方负责：`onSelectionChanged` 单选（首个选中值）；
  搜索本地即时过滤用 `onSearchInputChanged`，异步检索用 `onChanged`。
- 泛型 `T` 直接用业务枚举，避免页面再维护 String 映射。
- 表单内的分段选择（弹窗里的 合格/不合格 等）不是分类筛选，不用本组件。
