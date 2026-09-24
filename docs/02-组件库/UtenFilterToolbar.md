# UtenFilterToolbar

> 源码：`lib/components/layout/uten_filter_toolbar.dart`
> 创建：2026-09-01（全平台「分类筛选 + 搜索」统一范式；同日引入层级/默认不选/徽章口径）
> 更新：2026-09-03（分类行去「全部」段 + 末尾「历史记录/历史单据」时间门控段 +
> 未选引导占位 UtenFilterPlaceholder；单据列表页待处理段徽章口径修订）
> 更新：2026-09-21(分段计数扩成**三种形态**：默认中性括号 `(N)`，红徽章「待办」与
> 黄徽章「进行中」由 `UtenFilterSegment.countForm` 显式挑；见 §三。
> 2026-09-11 立的两形态口径由 [ADR-100](../99-决策记录-ADR/ADR-100-进行中黄色数量徽章与三形态计数口径.md) 扩充;
> 同日补记 `UtenFilterSegment.inProgressCount`: 双维度页大类行并排两枚、黄左红右)
> 相关：[UtenSearchBar](UtenSearchBar.md) · [UtenHistoryTimeFilter](UtenHistoryTimeFilter.md) · UtenSegmentBadgeLabel（`components/feedback/`）

## 一、定位

页面上凡有「分类/状态筛选」的地方一律用本组件，不再手写筛选按钮、Chip 行或
自成一套的分段样式：

- **分段导航**：M3 胶囊 StadiumBorder、**选中只变背景色不出 ✓ 图标**，
  与搜索框**结构化严格同高**（宽屏字段组内 `IntrinsicHeight + stretch`，两者按内容高度拉齐；
  密度/字号档变化下恒成立——visualDensity 对两侧折减不一致，不能靠各自设高度）；
- **分段计数**：分段可挂数量(`count`)，呈现有**三种形态**
  （`UtenFilterSegment.countForm` → `UtenSegmentBadgeLabel`，见 §三）：
  **默认中性括号 `(N)`**（浏览型，0 显示 `(0)` 保持队形，`> 999` 显 `999+`）；
  显式挑 `actionable` 才是红色圆数字徽章(待办型)，挑 `inProgress` 是黄色圆数字徽章
  (在办型)；两种徽章的 0 与 null 都不渲染，`> 99` 显 `99+`。
  三种形态下 `count == null`(加载中/未知)都不渲染——不把「未知」伪装成 0。
  计数须取该分段**全量口径**（非当前页推算）；
- **大类行的第二枚计数**(`UtenFilterSegment.inProgressCount`，2026-09-21)：双维度页的
  大类行可以并排挂两枚——主枚 `count` 按 `countForm` 着色(大类行一律 `actionable` 红)，
  第二枚 `inProgressCount` 颜色写死为黄、画在红那枚的**左边**(黄左红右，与 hub 卡同序)。
  只在一个大类里**同时**装着「等我动手」和「在办中」两批活时才传；该传不传的后果是大类行
  只显红数、点进去的小类行却有黄数，「大类 = 各小类之和」当场对不上(见 §三)。两枚各自
  遵守 0 与 null 不渲染；小屏收成「分类」下拉时两枚的总量也已自动合并，不必另行接线；
- **搜索框**：全平台唯一组件 `UtenSearchBar`（胶囊 + 清除 + 300ms 防抖），
  `searchHint` 不传且无 controller 时不渲染（纯分类工具条）；
- **响应式**：宽屏一行 `分段 | 搜索 | 弹性 | trailing`；窄屏（默认 < 840）分段
  **放得下照常显示、放不下自动收成一颗「分类」下拉按钮**（2026-09-14 起小屏不再
  左右拖分类）+ 搜索换行。
- **分段条恒有界可滚**（2026-09-11）：宽屏分支下分段条都包在 `Flexible` + 横向
  `SingleChildScrollView` + 常驻细滚动条里。此前宽屏分支把 `SegmentedButton` 直接放进 `Row`，
  它拿到的是**无界宽**——分类一多（仓库「其他入库明细表」十几个分类）就直接顶出黄黑溢出条，
  窄屏虽能滚但没有任何「右边还有」的提示（用户反馈「分类内容多的时候小屏会显示不全」）。
  `Flexible(loose)` 保证分类少时仍按自然宽度贴着搜索框；滚动条是覆盖层，不占布局高度，
  分段与搜索框的同高结构不受影响。
- **小屏「分类」下拉按钮**（2026-09-14）：窄屏分支按 TextPainter 估算分段条自然宽度，
  放不下时收成一颗下拉按钮——文案显示当前选中的分类（未选显示「分类」），右侧带
  黄徽章**进行中总量**与红徽章**待办总量**(各自同形态分段计数之和，黄左红右，无则不渲染)；点开下拉逐项展示
  分类与计数（复用 `UtenSegmentBadgeLabel`，计数口径不变），选中项打勾。
  估算刻意偏高：宁可早一步收下拉，不让分段条溢出。

## 二、层级与选中规则（2026-09-01 统一；2026-09-03 收紧）

1. **大类在上、小类在下**：双维度页（来源/方向=大类，状态=小类）大类行
   （含搜索框）在上，小类行在下。范本：`warehouse_quality_results_page.dart`
   （来源类型+搜索在上，作业状态在下）。
2. **进页面默认不选，未选不发请求**：`selected` 传**空集**（`const {}`），
   内容区显示引导占位 `UtenFilterPlaceholder`（本组件文件内提供）——
   **点击分段后才构建/加载内容**（2026-09-03 起从「空集=不过滤照样加载」收紧为
   「空集=不加载」；工作台类页面仅允许进页面拉一次 size=1 概览取徽章计数）。
3. **分类行不放「全部」段（2026-09-03）**：只放真实阶段/分类段；「回到全量
   翻旧账」的诉求由**末尾「历史记录/历史单据」段**承担——该段选中后渲染
   [UtenHistoryTimeFilter](UtenHistoryTimeFilter.md) 时间行（时间段/全部），
   未选时间同样不发请求（时间门控），选定后才按日期范围加载（不限状态）。
   有子类别的页面，历史段放在**小类行末尾**（如品质检查结果的状态行、
   任务工作台的异常行之前的主行末尾）。
4. **级联解锁**：小类行传 `enabled: 大类已选`（或结构上仅随选中大类出现）；
   未选大类时整行置灰不可点，回调里同样防御性兜底。
5. **视图切换例外**：切换内容区的工具条（应付工作区、报表变体、检验域等）
   必须始终有选中项，不适用「默认不选」，也不参与层级解锁。

## 三、计数口径（2026-09-11 两形态）

权威口径见 [`docs/00-项目准则/14-徽章与计数口径.md`](../00-项目准则/14-徽章与计数口径.md)。

### 先决定「传不传 count」

- 「全部」类分段不传（2026-09-03 起多数页面已无「全部」段）；
- 终态分段不传（已完结/终态/已决定/已取消/红冲/历史记录段）。

### 再决定形态（逐段回答两个问题）

1. **这个数字变大时，是「有人在等我干活」吗？** 是 → `actionable`(红)。
   不是 → 再问「这一段的东西还在流程里没结束吗？」是 → `inProgress`(黄)；
   已经结束的(已完成/已审/已出库/红冲/历史/全部)→ `browsing`(默认，中性括号)。
2. **是 → 同一条工具条里已有一段红徽章覆盖了这批活的总量吗？**
   是 → 细分切片仍走 `browsing`（同一批活不在一行里红两遍），只有总量段挂红。

| 形态 | 什么时候用 | 0 的表现 |
|---|---|---|
| `UtenSegmentCountForm.browsing`(默认) | 已完成 / 已审 / 已出库 / 红冲 / 历史记录 / 全部 / 来源细分等浏览型集合 | `(0)` 保持队形 |
| `UtenSegmentCountForm.actionable` | 待审 / 待确认 / 待收货 / 待出库 / 待检 / 被驳回 / 超期 / 异常 / 等待物料 / 本人草稿，**且这段确实在等本页用户动手** | 整个不渲染 |
| `UtenSegmentCountForm.inProgress`(2026-09-21) | 生产中 / 加工中 / 执行中 / 在途 / 等待财务审核 / 财务已通过待执行 / 等待检查结果，即「已在办、还没完、**现在不用我动手**」 | 整个不渲染 |

默认是括号：新调用方忘了传 `countForm` 也不会凭空造出一个假警报。

### 大类行两枚并排(2026-09-21)

双维度页(大类在上、小类在下)的大类行, 只要它下面的小类既有红段又有黄段, 大类行就得两枚
都挂: `count` + `countForm: actionable` 是红那枚, `inProgressCount` 是黄那枚, 每枚都等于
本大类下同色小类之和。范本 `sales_order_progress_page.dart`(进行中 / 可发货两个大类)与
`warehouse_quality_results_page.dart`(采购收货 / 委外回厂两个来源)。

来由见准则 §四之七 第 1 条: 大类行漏掉黄那枚时, hub 卡上的黄数字一进页面就在大类行上
凭空消失, 点到当下没有在办单的那个大类只剩一张空表, 用户会以为徽章在骗人。两枚的数最好
同出一次服务端聚合(品质部检查结果的 `/type-counts` 一个响应带回红黄两组数), 别一枚一支
端点 —— 那样恒等式只能靠人守。

### 硬约束

- **分段计数永不登记进服务端徽章目录的入口**(`WorkbenchBadgeCatalog`, ADR-108)：
  累加只认注册表里的「入口」，分段是页面内的切片。
- **父分类徽章 = 其子类待办之和**（2026-09-01）：任务中心页的大类分段
  （如入库任务中心「采购入库」）右侧徽章 = 该分类下各小类真实待办数的总和，
  与 hub 卡角标、工作台模块卡同源同口径（如 采购入库 = 采购预计到货 + 到货异常）。
  这类大类分段与 hub 卡角标数字相同是**故意的**（只有 hub 入口进累加，分段不进）。
- **中性括号的颜色不写死**：取分段自身前景色的半透明值——选中段背景是
  M3 `secondaryContainer`，固定 `onSurfaceVariant` 在上面读不清。

## 四、用法

```dart
UtenFilterToolbar<StageSeg>(
  segmentsKey: const Key('purchase-doc-segments-orders'),   // 透传测试/语义锚点
  searchKey: const Key('purchase-doc-search'),
  segments: [
    // 草稿没人在等 → 中性括号（默认，不用写 countForm）
    UtenFilterSegment(value: const StageSeg.stage(0), label: '草稿', count: draftCount),
    // 等我审的队列 → 显式挑红徽章
    UtenFilterSegment(
      value: const StageSeg.stage(1),
      label: '待我审',
      count: pendingReviewCount,
      countForm: UtenSegmentCountForm.actionable,
    ),
    const UtenFilterSegment(value: StageSeg.stage(-1), label: '红冲'),
    const UtenFilterSegment(value: StageSeg.history(), label: '历史记录'),  // 末尾
  ],
  selected: _seg == null ? const {} : {_seg},  // 空集=进页不选、不加载
  onSelectionChanged: _selectSeg,
  searchHint: '搜索单据号',
  onSearchChanged: _applySearch,               // 300ms 防抖（异步检索）
)
// 内容区：未选 → UtenFilterPlaceholder；历史段未选时间 → UtenHistoryTimePlaceholder；
// 否则列表/表格。
```

双维度页的大类行并排两枚(2026-09-21):

```dart
UtenFilterSegment(
  value: _Seg.type(type),
  label: type.label,
  count: typeCounts?.actionable[type],            // 红: 本类里等仓库动手的
  countForm: UtenSegmentCountForm.actionable,
  inProgressCount: typeCounts?.inProgress[type],  // 黄: 本类里还在别人手上跑的, 画在红左边
)
// typeCounts 为 null(加载中)时两枚都传 null → 都不渲染, 不写 `?? 0`。
```

范本实现：`purchase_doc_list_page.dart`（阶段+末尾历史记录+草稿括号计数）、
`warehouse_quality_results_page.dart`（双维度：大类+搜索上、小类解锁下、
小类末尾历史记录段）、`operations_workbench_page.dart`（阶段行+异常小类行）。

## 五、约定

- 回调语义由调用方负责：`onSelectionChanged` 单选（首个选中值，恒非空——
  空集只能出现在初始态）；
  搜索本地即时过滤用 `onSearchInputChanged`，异步检索用 `onChanged`。
- 泛型 `T` 直接用业务枚举或私有哨兵类（`stage(x)` / `history()`），避免页面
  再维护 String 映射。
- 表单内的分段选择（弹窗里的 合格/不合格 等）不是分类筛选，不用本组件。

## 六、纯「搜索 + 行尾」模式（2026-09-10）

筛选已下沉到列头 autofilter 或行尾筛选字段的页面（范本：即时库存的货品分类/仓库改
`UtenFilterPickerField` + 侧滑面板，2026-09-11），不传 `segments`（`segments`/`selected`/`onSelectionChanged` 均已可省略）即得到「搜索框 + 行尾控件」
工具条，不渲染空分段条。宽屏行尾放在有界的独立宽度槽中，居中且贴右；超宽的 `Wrap` 自动换行。
先扣除搜索宽度与分类间距，再把剩余宽度分给分类和行尾；没有分类时行尾使用全部剩余宽度。
分类较短时，空白留在搜索和行尾之间，动作仍贴页面右侧（此前裸 `trailing` 会让 `Wrap` 拿到
无界宽度，840~1000px 宽度带出现溢出）。

`UtenSearchBar` 高度由内容与主题密度决定；分类和搜索作为独立字段组，通过
`IntrinsicHeight + stretch` 同高。**行尾不参与字段组的高度计算**：44px 动作按钮或多行
`Wrap` 只增加工具条整体高度，不能把分类描边撑厚，分类和搜索在整条工具条内垂直居中。
行尾筛选字段（`UtenFilterPickerField`）按同一口径算内边距，表单下拉传紧凑
`contentPadding`（2026-09-10 回退过「搜索框强拉 48」；2026-09-23 修复行尾撑高分类）。
