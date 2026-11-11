# UtenCollapsingHeaderScrollView（顶部可折叠 + 表格吸顶内滚 联动容器）

> 文件：`lib/components/layout/uten_collapsing_header_scroll_view.dart`
> 分类：Layout
> 关联：[MasterDataTableView](MasterDataTableView.md)（`primary` 模式）、[UtenSplitView](UtenSplitView.md)（主档页右详情面板）

> 当前契约（2026-11-11）：全部适用调用方共用一个保留的外层 `CustomScrollView` 与内层 primary 控制器，宽窄/高度只改变正文 extent，不再迁移头部或正文的祖先视口。`stableBodyViewport` 只选择层级面板的高度策略。外层回顶使用 `UtenCollapsingHeaderScrollView.outerControllerOf(context)`；独立的外部 `NestedScrollView` 调用方可保留原兼容兜底。原 600/360 高度、50 交接距离、350ms/250 停顿窗、pinned/独立滚动/Shift/缩放换算边界保留。

> 历史实现 2026-10-13：紧凑与Nested布局向正文提供同一个primary代理，位置创建委托当前布局的真实控制器，detach始终归创建该位置的原控制器。保留同一正文/表格/行/输入State时，不能把旧普通位置直接挂到Nested控制器。既有到点截停、交接门和唯一滚轮换算保持；回归覆盖多轮窗口切换、非线性字号、Semantics、焦点/IME/选区/组合文本、偏移与真实连续滚轮。代理不释放由Nested协调器拥有的控制器。

> 生命周期补充（2026-11-03 修订）：组件持有头部和正文的保留根，调用方使用普通Key也能在紧凑/Nested/挤扁回退之间保留Element、输入控制器、焦点和组合文本。保留根使用稳定、显式的semantics boundary，隔离不同viewport的兄弟语义合并；detach后重新attach时，在整个子树拥有有效owner后递归调用公开`markNeedsSemanticsUpdate()`，由渲染生命周期更新完整语义拓扑和geometry，保留EditableText及父语义ID。不能在重挂时调用`clearSemantics()`销毁输入语义ID：Web会替换对应输入DOM，破坏仍保留的输入连接。不能禁用Semantics或略过渲染异常。`collapsingHeader`与`pinnedHeader`使用`PrimaryScrollController.none`隔离，头部独立滚动件不会借用正文或外层控制器。正文仍按API拾取primary代理。

相关回归：[窗口切换/全屏/滚轮与IME](../../test/uten_collapsing_header_mode_transition_test.dart)、[普通Key与挤扁模式的语义切换](../../test/uten_collapsing_header_semantics_transition_test.dart)、[头部primary隔离](../../test/uten_collapsing_header_primary_isolation_test.dart)、[FQC原子报告与恢复](../../test/features/quality/production_fqc_submission_recovery_test.dart)。新增语义压力与最终稳定源码的通过记录按对应验证批次记录，不用旧批次替代。

---

## 一、用途

大屏主档/列表页**顶部固定区**（分类详情卡、统计卡等）会挤压下方表格的纵向空间。本组件把「会滚走的顶部」放进 `collapsingHeader`，用同一组保留的外层（顶部）与内层（表格）视口把滚动**联动**起来：

- **向上滚**（鼠标滚轮 / 触屏上滑）：先把 `collapsingHeader` 收完，再滚 `body` 内部；
- **向下滚**：先把 `body` 回顶，再把 `collapsingHeader` 拉回原位；
- 手感**平滑跟手**（不吸附），且鼠标滚轮在两段之间有**交接门**（§八）：一格滚到「刚好置顶 / 刚好回顶」即止，再滚一小段空行程才开始动另一段。

> **关键**：`body` 里「想吸顶保留」的内容（如「标题 + 搜索 + 添加」一行）放在可滚动件（表格）之上的同一个 `Column` 兄弟位即可——它不随表格内滚而滚（表格是 `Column` 里的 `Expanded`），卡片收起后它自然顶到屏幕顶。

**何时用**：页面是「上方有一块固定顶部（卡 / 统计 / 工具条）+ 下方 `Expanded(MasterDataTableView)`」的结构，顶部又较高、挤压了表格。已接入：

- **主档 / 列表 / 报表**：货品 / 模具 / 客户 / 供应商 分类详情页；任务工作台（采购 / 委外 / 仓库，expanded 断点）；订单进度查询；采购 / 仓库 / 销售（订货单）单据列表页（2026-08-17）；生产物料分析准备页（2026-09-04——分析头/横幅/生产准备任务入口条收起，BOM 工具条+表格吸顶内滚）。
- **单据详情页**（头部=表头卡/横幅/附件等，body=`Expanded(MasterDataTableView(primary:true))`；2026-09-25 起纯计数「明细 (N)」标题随全站退役，body 只剩表格）：
  - 采购单据详情（2026-09-09，参考实现）；
  - 销售 / 委外 / 钱流 / 仓库单据详情、生产日报详情、仓库实物单据历史详情、仓库销售出库作业详情（2026-09-11）。
  - 口径：底部操作栏留在 `Scaffold.bottomNavigationBar`（不进滚动区）；附件等「备注类小卡」并入折叠头尾部随头部一起收起；明细下的合计条（`UtenTotalsSummaryBar`）留在表格下方常驻可见——**合计条从此一直可见，页面若原先靠「滚不到就看不见」隐藏某项，必须改成显式门控**（2026-09-11 销售订单「合计(本币)」按单据类型显式隐藏即此类）。
  - 无明细表的详情（如钱流客户预收）**不接**：没有可内滚的表格，保持整页 `ListView`。
- **人事域（2026-10-09）**：员工详情页（顶部折叠 + Tab 吸顶 + Tab 内滚）与工资条审核页
  （摘要/驳回卡折叠 + 明细表内滚）此前已接；本批补齐——人事花名册核对更正页（摘要区折叠 +
  表格内滚）、部门管理右详情面板（详情卡/人员总览折叠 + 在册员工工具条吸顶 + 表格内滚；无
  `employee:view` 时无表格可联动、不接）、HR 任务子页（生日/周年的「自动发送祝福」开关卡折叠，
  其余类型无折叠头即纯表内滚）、HR 信息变更审核队列（分段工具条折叠 + 表格内滚，对齐报销审批
  队列）。员工列表页 / 工资条列表页顶部无固定区（表格即整页 body）、表单与向导页无表格，按
  「何时不用」不接。

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
| `wheelGateDistance` | `double` | `50` | 滚轮交接空行程（逻辑像素，§八）：表格刚置顶 / 表内刚回顶之后，同方向再滚这么多才开始动另一段；`0` = 只丢弃交接那一格的余量。默认 50 ≈ 网页端半格滚轮（Chrome 一格 100） |
| `wheelHoldWindow` | `Duration` | `350ms` | 滚轮停顿窗（§八）：截停在交接点后，距上一格不超过该窗口的同方向格视为同一滚势，整格吞掉并续窗（2026-09-25）。 |
| `wheelHoldDistance` | `double` | `250` | 停顿窗的距离放行线（逻辑像素，§八）：没停但同方向累计推过量达到该值即放行——滚不停的用户不卡死在置顶点（2026-09-25）。 |
| `compactBreakpoint` | `double` | `UtenBreakpoints.mediumStart`(600) | 视口**宽**小于该值时走**紧凑回退**（整页滚动 + body 定高内滚），见 §四 |
| `compactHeightBreakpoint` | `double` | `UtenBreakpoints.mediumStart`(600) | 视口**高**小于该值时同样走紧凑回退（2026-09-11 手机横屏 844x390） |
| `compactBodyMinHeight` | `double` | `360` | 紧凑正文的最小高度；低视口保留可用表体，不在帧末切换祖先视口 |
| `stableBodyViewport` | `bool` | `false` | 层级面板高度策略：高视口填剩余区域，低视口保留正文最小高；不改变视口拓扑 |

---

## 三、与 MasterDataTableView 的 `primary` 缝

`MasterDataTableView` 默认自管竖向 `ScrollController`（私有的 `_bodyV`），不参与外层联动。包进本组件的 `body` 时需传 **`primary: true`**：

- 表体竖向 `ListView` 改用 `primary:true`（拾取本组件注入的保留 inner controller，参与联动）；
- `shrinkWrap` 关、physics 改 `AlwaysScrollableScrollPhysics`（否则短表 `maxScrollExtent=0`，顶部收完后滚动「卡死」）；
- 翻页回顶经 `PrimaryScrollController.maybeOf` + post-frame；
- 不能与 `embedded:true` 同用（断言拦截）。

详见 [MasterDataTableView §七 避坑](MasterDataTableView.md)。

---

## 四、响应式 / 性能档 / 主题

- **响应式**：宽或高小于原 `compactBreakpoint` / `compactHeightBreakpoint`（默认 600）时，正文高度保持 max(`compactBodyMinHeight`, 视口高 − 吸顶头高 − 48)，顶部随整页滚走；普通高视口正文填满视口，`pinnedHeader` 保留原三段吸顶顺序。层级面板的 `stableBodyViewport:true` 在高视口填余高、低视口保留最小正文高度。
- **保留生命周期**：全部尺寸共用一个外层 `CustomScrollView` 和同一个内层 primary 控制器，头部/正文不在 `NestedScrollView`、紧凑分支或挤扁回退之间搬移。长头部也由整页滚走，不再通过 `_SqueezeGuard` 帧末换祖先。活 Tooltip、焦点、IME、选区、输入 Element 与语义 ID 必须连续。
- **响应式（宽屏）**：不限屏宽，任何比例都生效。主档页通常包在 `UtenSplitView` 的右详情面板（`Expanded`，有界高度）里；窄屏（compact）分类树折成 `endDrawer`，右侧详情同样有界，联动照常。
- **性能档**：无自定义动画（滚轮、触摸与保留位置共用公共外层/内层协调入口），lite / standard / rich 三档一致。
- **主题**：本组件是布局壳，不取色；顶部 / 表格各自的配色仍由它们自己负责。

---

## 五、滚动条口径 (2026-10-25)

页面与表体内容超出各自视口即显示对应竖向滚动条，可直接拖动。全局 UtenScrollBehavior 负责普通页面和外层视口；MasterDataTableView 保留自己的内容滚动条，不再按头部置顶阶段隐藏。

UtenInnerScrollActiveScope 继续提供滚动阶段信号供联动逻辑兼容，不能据此隐藏可滚动区域的滚动条。紧凑回退的整页与表格分别绑定各自的位置；共享 PrimaryScrollController 的自动滚动条按具体 ScrollPosition 独立控制，避免拖动一个区域影响另一个区域。

---

## 六、示例代码

**主档详情面板（对齐货品 / 模具 / 客户 / 供应商 分类页）：**

```dart
return Padding(
  padding: EdgeInsets.symmetric(horizontal: hPad),
  child: UtenCollapsingHeaderScrollView(
    // 滚走区：分类信息卡（标题/前缀/层级；分类动作在左树行内）。上滑即收起、腾出表格空间。
    collapsingHeader: Padding(
      padding: const EdgeInsets.fromLTRB(0, UtenSpacing.s16, 0, UtenSpacing.s12),
      child: MasterDetailCard(
        title: d.name,
        icon: Icons.inventory_2_outlined,
        subtitle: '编码 ${d.code} · 层级 L${d.level}',
        // ... 系统根锁定说明（secondaryActions）；导入/导出/打印在表格工具条
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

## 七、实现要点 / 避坑

- **稳定视口**：外层/内层固定拓扑完成「先收头部、再滚正文，反向先正文回顶、再展开头部」。不能在 `LayoutBuilder` 的布局期搬移带活 Tooltip/OverlayPortal 的保留子树，也不能以隐藏 Tooltip、固定等待或清除输入语义节点代替生命周期修复。
- **保留表体优化**：正文高度不随每格外层滚动缩放；表格仍保留按宽度缓存舞台、有效约束/行身份与最新回调的既有优化。新 body 不能因可用高度变化重建整张表。
- **`body` 必须用注入的 `PrimaryScrollController`**：可滚动件用 `primary:true`（不传自己的 controller）才能被协调。外层命令从 `outerControllerOf(context)` 取得本组件的实际控制器，不依赖祖先的具体 widget 类型。
- **`collapsingHeader` 整块随滚动消失 / 重现**：它保留在同一 `SliverToBoxAdapter` 中；离开可见区域不代表释放输入 State，不通过换视口重建头部。
- **短表也要能收**：联动模式下表格 `shrinkWrap` 必须关、physics 必须 `AlwaysScrollable`，否则行少时表格不滚 → 顶部收不动（`MasterDataTableView.primary:true` 已自动处理）。
- **有界高度前提**：保留的外层/内层视口需要父级给有界高度。主档页的 `UtenSplitView` 右面板 / `UtenContentContainer` 都在 `Scaffold` body 有界区内，满足。

---

## 八、滚轮交接门与卡顿根治（2026-09-22）

用户口径：「所有页面鼠标上下滚动都一卡一卡的，表格里面滚动还好，就是表格一步一步往置顶移动的时候」；「表格置顶后得再滑一点点距离才开始动表内，往下也一样——之前一置顶瞬间就滚表内，看不到最前面的内容」；「不管在表格内还是表格外滚，都先把表格置顶」。

**历史卡顿根因**（探针 `test/uten_collapsing_header_scroll_relayout_test.dart`）：`NestedScrollView` 的 body 高 = 视口剩余高，头部每收一格 body 就变一次高；`MasterDataTableView` 表体的 `LayoutBuilder` 每次约束变化都整树重建——一格滚轮 25-31 个可见单元格从头建一遍再布局，而表内滚动高度不变、只动偏移，所以「表内滚还好、往上移就卡」。根治在表格侧：表体子树只按**宽度**重建，高度只经约束传给 `ListView` 视口，高度只变时原样交回同一 widget 实例（框架看到同一实例跳过重建，行按原约束缓存）。修后收头部每格 0-3 个单元格重建、耗时与表内滚动同级；放头部每格 0 个。

**滚轮交接门**（本组件）：在保留的联动视口上盖一层透明 `Listener`，命中序先于内外 `Scrollable` 拿到滚轮，自己决定怎么给：

- 一格滚到「刚好置顶」/「刚好回顶」即止，余量丢弃（原生会把余量当场滚进另一段）；
- **停顿窗（2026-09-25）**：截停在交接点后，`wheelHoldWindow`（默认 350ms，滑动续窗）内同方向的后续格属**同一滚势**，整格吞掉——连续快滚一口气冲过置顶点后不再「马上继续往下滑」。两条放行线**先到先放**：①滚势停住（窗口内无新格）；②没停但同方向累计推过量达到 `wheelHoldDistance`（默认 250 逻辑像素 ≈ 两格半滚轮）——滚不停的人 = 明确要继续，放行那格走正常门逻辑。掉头 / `PointerScrollInertiaCancelEvent`（用户重新触碰滚轮）立即关窗；
- 越过交接点之后，同方向还要再滚 `wheelGateDistance`（默认 50）的空行程才开始动另一段；
- 掉头即撤门：反向是明确意图，不吃空行程；触屏拖过 / 拖过滚动条离开交接点后门自动失效；
- 头部没收完之前的上滚一律归联动（鼠标在表格内 / 表格外 / 页内侧栏上都先把表格置顶）；置顶之后沿命中路径由内向外找竖向滚动件——先碰到联动的（外层 / inner）就接管，先碰到**独立**的（`primary:false` / 自带 controller 的侧栏、嵌套面板、多行文本框）且它还能往这个方向滚，就让给框架原样处理；
- shift+滚轮（`ScrollBehavior.pointerAxisModifiers`）是横滚，不接管；触屏拖动由同一保留位置按外层/内层顺序协调。

> 注意：body 的联动竖向可滚动件显式传 `primary:true`，拾取本组件注入的 inner controller；要独立就显式传 `primary:false` + 自己的 controller。不能依赖默认平台的自动继承差异。

---

**最后更新**：2026-10-09 · 人事域批量接入（§一「人事域」）：花名册核对更正页 / 部门管理右详情面板 / HR 任务子页 / HR 信息变更审核队列四页补齐「折叠头 + 表格吸顶内滚」，文档同步修正工资条审核页与员工详情页两处陈旧滚动描述（定高钳制 / 无吸顶描述已退役）。回归：四页既有测试（hr_reconcile / hr_task_list / hr_profile_changes / department_overview_pane）在 HEAD 基线全绿。
此前：2026-09-25（二）· 停顿窗加**距离放行线**（`wheelHoldDistance` 默认 250）：滚不停的用户同方向累计推够距离即放行，不卡死在置顶点——与时间放行线（350ms 停顿）先到先放；此前同日：§八新增停顿窗（`wheelHoldWindow`），截停后同一滚势的连续快滚整格吞掉，「滚一下没停就置顶了 → 停住，重新开始滚才继续」；同批在 `uten_sticky_header.dart` 落地单滚动页（embedded 表/编辑网格）共用的 `UtenStickyWheelGate`（截停 + 停顿窗双放行线 + 短表按需撑高）。回归：`test/uten_collapsing_header_scroll_relayout_test.dart` + `test/uten_sticky_wheel_gate_test.dart`。
此前：2026-09-22 · 新增 §八：滚轮交接门（`wheelGateDistance`，到点即止 + 空行程 + 掉头撤门 + 先置顶再表内 + 不抢独立滚动件）；卡顿根因定位到 body 每格变高 + 表格整树重建，表格侧只按宽度重建；`floatHeaderSlivers` 参数删除（无调用方，且门依赖非 floating 顺序）。回归：`test/uten_collapsing_header_scroll_relayout_test.dart`（6 例）。
此前：2026-09-14 · 新增滚动条口径（§五）：外层收头部阶段不显示上下滚动条，进入表体内滚后再显示表内滚动条（`UtenInnerScrollActiveScope` 注入 + `MasterDataTableView` 门控）。
此前：2026-09-11 · 接入范围扩大到单据详情页（销售 / 委外 / 钱流 / 仓库单据、生产日报、仓库实物历史、仓库销售出库作业）；组件新增「矮视口」与「被头部挤扁」两条紧凑回退触发线 + body 挤扁哨兵（`compactHeightBreakpoint`）。回归测试夹具见 `test/support/collapsing_header_harness.dart`（折叠断言 + 1280x900 / 390x844 / 844x390 三视口 × textScale 1.5 不溢出）。
此前：2026-08-17 · 接入范围扩大到任务/单据页：任务工作台（采购 / 委外 / 仓库，expanded 断点——概览卡收起、筛选行 + 选中操作条吸顶）、订单进度查询（指标卡收起、`ListView(primary: true)` 内滚、分页条常驻底部）、采购 / 仓库 / 销售（订货单）单据列表页（KPI / 统计卡条收起，标题行吸顶，表格 `primary: true` 经 `UtenListTwoPane` 内滚）。
此前：2026-08-14 · 新增组件。货品 / 模具 / 客户 / 供应商 四个分类详情页接入（卡片折叠 + 搜索行吸顶 + 表格内滚）。扁平主档页（颜色 / 单位 / 仓库 / 币种 / 账户）顶部仅一行搜索条、本就吸顶，不接入。
