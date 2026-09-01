# UtenFilterToolbar

> 源码：`lib/components/layout/uten_filter_toolbar.dart`
> 创建：2026-09-01（全平台「分类筛选 + 搜索」统一范式；同日引入层级/默认不选/徽章口径）
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

## 二、层级与选中规则（2026-09-01 全平台统一）

1. **大类在上、小类在下**：双维度页（来源/方向=大类，状态=小类）大类行
   （含搜索框）在上，小类行在下。范本：`warehouse_quality_results_page.dart`
   （来源类型+搜索在上，作业状态在下）。
2. **进页面默认不选**：`selected` 传**空集**（`const {}`），数据等价于不过滤；
   页面状态用「筛选值 + 是否已选」两个变量表达（如 `_orderType` +
   `_typeSelected`）。「全部」段保留为显式选项——SegmentedButton 点击已选段
   不回调，选中后只能靠「全部」段回到全量视图。服务端偏好回灌到具体值时
   视为已选（如 `production_report_page`）。
3. **级联解锁**：小类行传 `enabled: 大类已选`；未选大类时整行置灰不可点，
   回调里同样防御性兜底。
4. **视图切换例外**：切换内容区的工具条（应付工作区、报表变体、待确认/已驳回、
   检验域等）必须始终有选中项，不适用「默认不选」，也不参与层级解锁。

## 三、徽章口径

`count` 只挂在**看页面的用户需要下一步操作**的分段：

- 「全部」类分段不挂徽章（含「全部待审/全部待检单/全部待到货」）；
- 终态分段不挂（已完结/终态/已决定/已取消）；
- **草稿分段不挂**（2026-09-01 定稿：所有草稿不计入数量徽章——单据草稿
  尚未进入待办流，「其它出库/领料单」等只有草稿与历史的分类整体不挂）；
- 下一步是别人操作的状态不挂（如 IQC 拒收页的「已退回待财务」「财务异常」
  ——那是财务的待办，本页是采购/委外用户）；
- 例外：品质检查结果页「等待结果」保留数量——与该页统一「未完结」口径
  （等待+待入库+需退回），卡片/工作台角标同口径。

**父分类徽章 = 其子类待办之和**（2026-09-01 补充）：任务中心页的大类分段
（如入库任务中心「采购入库」）右侧徽章 = 该分类下各小类真实待办数的总和，
与 hub 卡角标、工作台模块卡同源同口径（如 采购入库 = 采购预计到货 + 到货异常）。

## 四、用法

```dart
UtenFilterToolbar<String>(
  segmentsKey: const Key('iqc-type-segments'),   // 透传测试/语义锚点
  searchKey: const Key('iqc-search'),
  segments: [
    const UtenFilterSegment(value: 'all', label: '全部待检单'),  // 全部段不挂徽章
    UtenFilterSegment(value: 'purchase', label: '采购收货', count: purchaseCount),
  ],
  selected: _typeSelected ? {selected} : const {},  // 空集=进页不选
  onSelectionChanged: (value) => _selectType(value),
  searchHint: '搜索单号 / 供应商',
  initialSearchValue: _keyword,
  onSearchChanged: _applySearch,        // 300ms 防抖（异步检索）
  // onSearchInputChanged: _onInput,    // 同步（本地即时过滤）
  trailing: Text('共 ${items.length} 条'), // 宽屏行尾
)
```

范本实现：`warehouse_quality_results_page.dart`（双维度：大类+搜索上、小类
解锁下）与 `production_fqc_inspections_page.dart`（单维度 + 仅待处理挂徽章）。

## 五、约定

- 回调语义由调用方负责：`onSelectionChanged` 单选（首个选中值，恒非空——
  空集只能出现在初始态）；
  搜索本地即时过滤用 `onSearchInputChanged`，异步检索用 `onChanged`。
- 泛型 `T` 直接用业务枚举，避免页面再维护 String 映射；「全部」段常用
  nullable 枚举的 null 值或哨兵字符串。
- 表单内的分段选择（弹窗里的 合格/不合格 等）不是分类筛选，不用本组件。
