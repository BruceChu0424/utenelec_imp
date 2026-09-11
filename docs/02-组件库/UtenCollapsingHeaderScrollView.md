# UtenCollapsingHeaderScrollView（顶部可折叠 + 表格吸顶内滚 联动容器）

> 文件：`lib/components/layout/uten_collapsing_header_scroll_view.dart`
> 分类：Layout
> 关联：[MasterDataTableView](MasterDataTableView.md)（`primary` 模式）、[UtenSplitView](UtenSplitView.md)（主档页右详情面板）

---

## 一、用途

大屏主档/列表页**顶部固定区**（分类详情卡、统计卡等）会挤压下方表格的纵向空间。本组件把「会滚走的顶部」放进 `collapsingHeader`，用一个 `NestedScrollView` 把外层（顶部）与内层（表格）的滚动**联动**起来：

- **向上滚**（鼠标滚轮 / 触屏上滑）：先把 `collapsingHeader` 收完，再滚 `body` 内部；
- **向下滚**：先把 `body` 回顶，再把 `collapsingHeader` 拉回原位；
- 手感**默认平滑跟手**（`floatHeaderSlivers: false`，不吸附）。

> **关键**：`body` 里「想吸顶保留」的内容（如「标题 + 搜索 + 添加」一行）放在可滚动件（表格）之上的同一个 `Column` 兄弟位即可——它不随表格内滚而滚（表格是 `Column` 里的 `Expanded`），卡片收起后它自然顶到屏幕顶。

**何时用**：页面是「上方有一块固定顶部（卡 / 统计 / 工具条）+ 下方 `Expanded(MasterDataTableView)`」的结构，顶部又较高、挤压了表格。已接入：

- **主档 / 列表 / 报表**：货品 / 模具 / 客户 / 供应商 分类详情页；任务工作台（采购 / 委外 / 仓库，expanded 断点）；订单进度查询；采购 / 仓库 / 销售（订货单）单据列表页（2026-08-17）；生产物料分析准备页（2026-09-04——分析头/横幅/生产准备任务入口条收起，BOM 工具条+表格吸顶内滚）。
- **单据详情页**（头部=表头卡/横幅/附件等，body=「明细 (N)」标题行 + `Expanded(MasterDataTableView(primary:true))`）：
  - 采购单据详情（2026-09-09，参考实现）；
  - 销售 / 委外 / 钱流 / 仓库单据详情、生产日报详情、仓库实物单据历史详情、仓库销售出库作业详情（2026-09-11）。
  - 口径：底部操作栏留在 `Scaffold.bottomNavigationBar`（不进滚动区）；附件等「备注类小卡」并入折叠头尾部随头部一起收起；明细下的合计条（`UtenTotalsSummaryBar`）留在表格下方常驻可见——**合计条从此一直可见，页面若原先靠「滚不到就看不见」隐藏某项，必须改成显式门控**（2026-09-11 销售订单「合计(本币)」按单据类型显式隐藏即此类）。
  - 无明细表的详情（如钱流客户预收）**不接**：没有可内滚的表格，保持整页 `ListView`。

**何时不用**：
- 顶部只有一行搜索条、没有可收起的大块（如颜色 / 单位等扁平主档页）——本来就已「搜索条吸顶 + 表格内滚」，套本组件是空操作，不必包。
- `embedded:true`（picker / 滑窗内明细表 / 单据明细行）——它们在他人滚动视图内，没有「自己的顶部」可收。

---

## 二、API（参数表）

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `body` | `Widget` | 必填 | 滚动主体。**须含一个拾取 `PrimaryScrollController` 的竖向可滚动件**：`MasterDataTableView(primary: true)` 或 `ListView(primary: true)` |
| `collapsingHeader` | `Widget?` | `null` | 随滚动收起 / 拉回的顶部内容（分类信息卡等）。为空则只有 `body` |
| `controller` | `ScrollController?` | `null` | 可选外层 `ScrollController`（一般无需传） |
| `floatHeaderSlivers` | `bool` | `false` | 是否在向下滚时优先让顶部浮回（floating）。`false` = 平滑跟手：先把 `body` 回顶，再把顶部拉回（非吸附） |
| `compactBreakpoint` | `double` | `UtenBreakpoints.mediumStart`(600) | 视口**宽**小于该值时走**紧凑回退**（整页滚动 + body 定高内滚），见 §四 |
| `compactHeightBreakpoint` | `double` | `UtenBreakpoints.mediumStart`(600) | 视口**高**小于该值时同样走紧凑回退（2026-09-11 手机横屏 844x390） |
| `compactBodyMinHeight` | `double` | `360` | 紧凑回退时 body 的最小高度；同时是「body 被头部挤扁」的判定线（body 实得高 < 该值 → 下一帧切紧凑回退） |

---

## 三、与 MasterDataTableView 的 `primary` 缝

`MasterDataTableView` 默认自管竖向 `ScrollController`（私有的 `_bodyV`），不参与外层联动。包进本组件的 `body` 时需传 **`primary: true`**：

- 表体竖向 `ListView` 改用 `primary:true`（拾取 `NestedScrollView` 注入的 inner controller，参与联动）；
- `shrinkWrap` 关、physics 改 `AlwaysScrollableScrollPhysics`（否则短表 `maxScrollExtent=0`，顶部收完后滚动「卡死」）；
- 翻页回顶经 `PrimaryScrollController.maybeOf` + post-frame；
- 不能与 `embedded:true` 同用（断言拦截）。

详见 [MasterDataTableView §七 避坑](MasterDataTableView.md)。

---

## 四、响应式 / 性能档 / 主题

- **响应式（2026-09-11 矮视口 / 挤扁回退）**：另有两条回退触发线，与下面的窄视口回退走同一分支：
  - **矮视口**：视口高 < `compactHeightBreakpoint`（默认 600，手机横屏 844x390）。NestedScrollView
    的 body 只剩 ~250px，头部收完后表格固定件（工具条/表头/分页）仍溢出 19px。
  - **被头部挤扁**：`NestedScrollView` 的 body 高 = 视口高 − **头部滚动高度**，头部一高
    （信息卡 + 附件区 + 放大字号）body 就只剩几十像素甚至 0（表格整块不可达）。组件在 body 外
    包了一层挤扁哨兵：实得高 < `compactBodyMinHeight` 时先按最小高布局 + `ClipRect`（当帧不溢出），
    并在帧末把本视口尺寸标记为「挤扁」→ 下一帧切整页滚动回退；视口尺寸变化（缩放/转屏）后重试联动模式。
    2026-09-11 钱流/销售单据详情 1280x900 + 字号 1.5 复现。
- **响应式（2026-09-10 紧凑回退）**：视口宽 < `compactBreakpoint`（默认 600，手机竖屏）时
  不再用 `NestedScrollView`——它的 body 高度 = 视口高 − 顶部内容高，手机上单列拉长的
  表头信息卡会把 body 压到几十像素，表格固定件（工具条/表头/分页）直接纵向溢出
  （采购单据详情 375 宽复现）。回退为「整页 `CustomScrollView` 滚动 + body 定高盒」：
  顶部随页滚走、吸顶头照常钉住，body 高 = max(`compactBodyMinHeight`, 视口高 − 吸顶头高 − 48)，
  body 内的 `primary:true` 可滚动件拾取组件注入的独立 `PrimaryScrollController` 在盒内滚。
  ≥ 600 宽、或传了 `pinnedHeader` 的三段式页面（横幅短、Tab 吸顶时序依赖外内协调）仍是原联动行为。
- **响应式（宽屏）**：不限屏宽，任何比例都生效。主档页通常包在 `UtenSplitView` 的右详情面板（`Expanded`，有界高度）里；窄屏（compact）分类树折成 `endDrawer`，右侧详情同样有界，联动照常。
- **性能档**：无自定义动画（滚动协调由 Flutter `NestedScrollView` 原生完成），lite / standard / rich 三档一致。
- **主题**：本组件是布局壳，不取色；顶部 / 表格各自的配色仍由它们自己负责。

---

## 五、示例代码

**主档详情面板（对齐货品 / 模具 / 客户 / 供应商 分类页）：**

```dart
return Padding(
  padding: EdgeInsets.symmetric(horizontal: hPad),
  child: UtenCollapsingHeaderScrollView(
    // 滚走区：分类信息卡（编辑 / 导入 / 导出 / 打印）。上滑即收起、腾出表格空间。
    collapsingHeader: Padding(
      padding: const EdgeInsets.fromLTRB(0, UtenSpacing.s16, 0, UtenSpacing.s12),
      child: MasterDetailCard(
        title: d.name,
        icon: Icons.inventory_2_outlined,
        subtitle: '编码 ${d.code} · 层级 L${d.level}',
        // ... 编辑 / 加子级 / 删除 / 导入 / 导出 / 打印
      ),
    ),
    // body：搜索 + 添加（卡片收起后吸顶）+ 表格（内滚）。
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Row(
            children: [
              Icon(Icons.inventory_2_outlined, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Text('货品 ($total)', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(child: UtenSearchBar(onChanged: _onKeywordChanged)), // 搜索
              UtenButton(type: UtenButtonType.tonal, icon: Icons.add_rounded, onPressed: _showCreate, child: const Text('添加货品')), // 添加在搜索右
            ],
          ),
        ),
        Expanded(
          child: MasterDataTableView<GoodsListItem>(
            primary: true, // ← 关键：参与联动
            columns: _columns,
            items: _items,
            // ... 其余表格参数
          ),
        ),
      ],
    ),
  ),
);
```

> 布局要点：**分类卡在最上面、搜索 + 添加行紧跟其后、表格在最下**——与原 `Column[ 卡, 搜索行, Expanded(表格) ]` 视觉一致，只是把卡挪到 `collapsingHeader`、搜索行 + 表格挪进 `body`。搜索框（及其 `key`）只保留一个，从原行迁到 `body` 里，状态连续。

---

## 六、实现要点 / 避坑

- **为什么用 `NestedScrollView`**：它是 Flutter 原生的「外层先收、内层后滚，反向内层先回顶、外层再展开」协调机制，与诉求逐条吻合；`floatHeaderSlivers:false` = 平滑跟手。**不要**改用 `SliverFillRemaining`（它不会做这种「先收后滚」的交接）或 `UtenEditableGrid` 的 rect 量测浮层（那是单视图内吸顶，不跨两个滚动视图）。
- **`body` 必须用注入的 `PrimaryScrollController`**：`NestedScrollView` 给 `body` 注入 inner controller，`body` 的可滚动件必须用 `primary:true`（不传自己的 controller）才能被协调。`MasterDataTableView` 传 `primary:true` 即满足。
- **`collapsingHeader` 整块随滚动消失 / 重现**：它放在 `SliverToBoxAdapter` 里，滚出视口后会被释放（widget 不在树里）——这是预期行为，不是泄漏。
- **短表也要能收**：联动模式下表格 `shrinkWrap` 必须关、physics 必须 `AlwaysScrollable`，否则行少时表格不滚 → 顶部收不动（`MasterDataTableView.primary:true` 已自动处理）。
- **有界高度前提**：`NestedScrollView` 需要父级给有界高度。主档页的 `UtenSplitView` 右面板 / `UtenContentContainer` 都在 `Scaffold` body 有界区内，满足。

---

**最后更新**：2026-09-11 · 接入范围扩大到单据详情页（销售 / 委外 / 钱流 / 仓库单据、生产日报、仓库实物历史、仓库销售出库作业）；组件新增「矮视口」与「被头部挤扁」两条紧凑回退触发线 + body 挤扁哨兵（`compactHeightBreakpoint`）。回归测试夹具见 `test/support/collapsing_header_harness.dart`（折叠断言 + 1280x900 / 390x844 / 844x390 三视口 × textScale 1.5 不溢出）。
此前：2026-08-17 · 接入范围扩大到任务/单据页：任务工作台（采购 / 委外 / 仓库，expanded 断点——概览卡收起、筛选行 + 选中操作条吸顶）、订单进度查询（指标卡收起、`ListView(primary: true)` 内滚、分页条常驻底部）、采购 / 仓库 / 销售（订货单）单据列表页（KPI / 统计卡条收起，标题行吸顶，表格 `primary: true` 经 `UtenListTwoPane` 内滚）。
此前：2026-08-14 · 新增组件。货品 / 模具 / 客户 / 供应商 四个分类详情页接入（卡片折叠 + 搜索行吸顶 + 表格内滚）。扁平主档页（颜色 / 单位 / 仓库 / 币种 / 账户）顶部仅一行搜索条、本就吸顶，不接入。
