part of 'production_material_analysis_page.dart';

/// 父件 + 下层一起下单**整页**（2026-09-14 用户口径「不要弹窗了直接去新的页面，
/// 弹窗看的东西太少」）：与物料分析准备页同款的树表格（展开 / 收缩 + 层级连线，
/// UtenTreeTableCell）+ 一个「一键下单」。[parentAction] 非空 = 前置模式（父件
/// 还没提交，一键下单先提交父件再办下层）；null = 重试模式（父件已提交过）。
class _ChildCascadePage extends StatefulWidget {
  const _ChildCascadePage({
    required this.host,
    required this.seeds,
    required this.initialRows,
    this.parentAction,
  });

  final _MaterialAnalysisChildCascadeState host;
  final List<_ChildCascadeSeed> seeds;
  final List<_ChildCascadeRow> initialRows;
  final Future<bool> Function()? parentAction;

  @override
  State<_ChildCascadePage> createState() => _ChildCascadePageState();
}

class _ChildCascadePageState extends State<_ChildCascadePage> {
  final UtenEditableGridController<_ChildCascadeRow> _grid =
      UtenEditableGridController<_ChildCascadeRow>();

  /// 全量行（含被折叠隐藏的）：行对象与输入控制器归本页所有，折叠只换
  /// 可见子集（swapRows 不 dispose），展开原样放回，已填内容不丢。
  List<_ChildCascadeRow> _allRows = const [];
  static const _pageSize = 50;
  int _page = 1;
  final ScrollController _pageScroll = ScrollController();

  // The grid owns only this page's widgets. Selection and validation cover the
  // complete operation, including rows on other pages.
  List<_ChildCascadeRow> get _selectedRows =>
      _allRows.where(_grid.isSelected).toList(growable: false);
  Map<_ChildCascadeRow, UtenTreeRowProjection> _treeInfo = const {};
  final Set<String> _collapsedBranches = {};

  /// 折叠时记下被撤勾的行，展开时原样放回——原来折叠一撤就再也回不来，
  /// 数量还填着却没勾上，一键下单静默少下单（2026-09-14）。
  final Set<String> _collapsedSelection = {};

  /// 用户**手工**取消勾选的提交单元：重算与重建都不得替他重新勾上。
  final Set<String> _userDeselected = {};

  /// 正在程序性写入数量框（预填 / 重算），此时的控制器变更不算「用户改过」。
  bool _programmaticQty = false;

  /// 正在程序性改勾选（预勾、重算同步、折叠恢复），不算「用户手工取消」。
  bool _programmaticSelection = false;

  /// 当前被表头筛选藏起来的行。
  Set<_ChildCascadeRow> _hiddenByFilter = const {};

  /// 数量框只收数字与一个小数点：原来什么都能敲，`1e400` 会被 double.parse
  /// 解析成 Infinity 一路送进 JSON（服务端收到的是非法数）。
  static final List<TextInputFormatter> _qtyInputFormatters = [
    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
  ];

  /// 这一行现在能不能指派车间 / 负责人。
  ///
  /// 原来用的是 `row.selectable`——合并行、已下过单的行、被阻断的行全部命中，
  /// 界面上写着「点击选择」却点不动，就是用户说的「icon 按钮按了没反应」。
  /// 真正的条件只有三条：本行确实要下车间（[_ChildCascadeRow.needsWorkshop]，
  /// 已含「是提交单元代表 / 是树顶父件」的判定）、未被阻断、本页不在提交中。
  ///
  /// 树顶父件额外一条：父件段一旦提交成功就不能再改——车间/负责人算进
  /// issue-plans 的幂等键，改了就是换键，等于制造重复下单风险（与数量框同口径）。
  bool _canAssignWorkshop(_ChildCascadeRow row) =>
      row.needsWorkshop &&
      row.blockedReason == null &&
      !_running &&
      !(row.isSeed && _parentSubmitted);

  /// 车间 / 负责人选择格。不可点时**不装成可点**：不显示「点击选择」，
  /// 改为灰底 '—' 并用 tooltip 说明为什么（死寂的「点了没反应」是用户
  /// 亲口提的问题）。
  Widget _pickerCell(
    ThemeData theme, {
    required _ChildCascadeRow row,
    required String cellKey,
    required Listenable listenable,
    required String? Function() valueText,
    required bool Function() autofilled,
    required VoidCallback onPick,
  }) {
    if (!row.needsWorkshop) {
      return Tooltip(
        message: row.isSeed
            ? '本行直接外发给委外商，不需要我方车间与负责人'
            : (row.ownsInput
                  ? '本行走${row.kind.label}，不需要车间与负责人'
                  : '本行只作层级上下文，数量与车间都并入上面那一行'),
        child: const Text('—'),
      );
    }
    final enabled = _canAssignWorkshop(row);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final value = valueText();
        final field = InputDecorator(
          decoration: applyAutofillHint(
            const InputDecoration(isDense: true),
            theme,
            autofilled: autofilled() && value != null,
          ),
          child: Text(
            value ?? (enabled ? '点击选择' : '—'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: enabled || value != null
                  ? null
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
        if (!enabled) {
          return Tooltip(
            message: _running
                ? '正在下达，暂时不能改'
                : (row.blockedReason ?? '本行当前不可下达，改了也提交不了'),
            child: field,
          );
        }
        return InkWell(key: ValueKey(cellKey), onTap: onPick, child: field);
      },
    );
  }

  /// 所属仓库格 (V587)。外形照抄 [_pickerCell] (同表的生产车间 / 负责人两列),
  /// 但取值与写回一律走宿主的共享助手: 主表、分桶详情、本页三处改的是同一个
  /// 货品级事实, 各写一套取值就会出现「在这改完, 回去还是旧值」。
  ///
  /// 与车间 / 负责人不同的是这一列**与本行下不下得了单无关** (它是货品主档归属,
  /// 不是本次下达的参数), 所以合并行、被阻断的行照样能改; 只有认不出货品
  /// (无 goodsId) 的行才退成只读 '—', 不装成可点。
  Widget _owningWarehouseCell(ThemeData theme, _ChildCascadeRow row) {
    final goodsId = row.goodsId;
    if (goodsId == null || goodsId.isEmpty) {
      return const Tooltip(message: '这一行没有对应的货品主档, 改不了所属仓库', child: Text('—'));
    }
    final value = _host.owningWarehouseNameOf(
      goodsId,
      row.owningWarehouseNameSnapshot,
    );
    final field = InputDecorator(
      decoration: const InputDecoration(isDense: true),
      child: Text(
        value ?? '点击选择',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: value == null ? theme.colorScheme.onSurfaceVariant : null,
        ),
      ),
    );
    return InkWell(
      key: ValueKey(
        'material-analysis-child-cascade-owning-warehouse-${row.id}',
      ),
      onTap: () => _pickOwningWarehouse(row),
      child: field,
    );
  }

  Future<void> _pickOwningWarehouse(_ChildCascadeRow row) async {
    final goodsId = row.goodsId;
    if (goodsId == null || goodsId.isEmpty) return;
    final changed = await _host.pickOwningWarehouse(
      context,
      goodsId: goodsId,
      currentWarehouseId: _host.owningWarehouseIdOf(
        goodsId,
        row.owningWarehouseIdSnapshot,
      ),
    );
    // 宿主那边的 setState 刷不到本页: 本页是弹窗里独立的 StatefulWidget,
    // 不在宿主的 build 子树里, 改完必须自己重建才看得见新值。
    if (changed && mounted) setState(() {});
  }

  bool _running = false;

  /// 顶部说明默认收起：细则用得着时再展开，不常年占掉小半屏。
  bool _hintExpanded = false;

  /// 默认车间/负责人与下游申请联动都是进页面后异步补上的。加载期间必须
  /// 有明确指示并挡住提交：否则用户抢在默认车间填进来之前点一键下单，
  /// 只会拿到一句「尚未选择生产车间」，而那本来是系统该替他填好的。
  int _loading = 0;
  bool get _busy => _loading > 0;

  Future<void> _withLoading(Future<void> Function() body) async {
    if (mounted) setState(() => _loading++);
    try {
      await body();
    } finally {
      if (mounted) setState(() => _loading--);
    }
  }

  List<_CascadeStepResult> _lastRun = const [];

  /// 前置模式下父件是否已提交成功：失败重试时不再重发父件段——
  /// 首次提交后分析快照已换版本，重发会生成新幂等键，等于真实重复下单。
  bool _parentSubmitted = false;

  Map<
    String,
    ({
      String departmentId,
      String? departmentName,
      String? workerId,
      String? workerName,
    })
  >
  _workshopDefaults = const {};
  Map<String, ({String? id, String? name})> _workshopManagers = const {};

  _MaterialAnalysisChildCascadeState get _host => widget.host;

  /// 本页只有一张表，列设置只有一个桶。
  static const String _columnPrefsBucket = 'cascade';

  EditableGridColumnsPrefs? get _columnPrefs => _host.ref.read(
    materialAnalysisCascadeGridColumnPrefsProvider,
  )[_columnPrefsBucket];

  @override
  void initState() {
    super.initState();
    _grid.addListener(_trackManualDeselection);
    // 进页时各种子的数量：用来区分「上一页填的数」与「在本页被改过的数」，
    // 只有后者才需要在本页再问一次超量确认（上一页已经问过一次了）。
    _initialSeedQty = {for (final seed in widget.seeds) seed: seed.batchQty};
    _installRows(widget.initialRows);
    unawaited(_withLoading(_loadWorkshopDefaults));
    unawaited(_withLoading(_loadSupplyLinks));
  }

  Map<_ChildCascadeSeed, double> _initialSeedQty = const {};

  /// 树顶种子：没被祖先吸收的那些才进父件段、才算「本次将下达」。
  List<_ChildCascadeSeed> get _topSeeds => [
    for (final seed in widget.seeds)
      if (seed.isTop) seed,
  ];

  /// 被祖先吸收的勾选行名单 (2026-09-16)：顶部提示要点名说清「这几行已并进
  /// 上层树，数量随上层一起变」，否则用户会以为勾了的行被弄丢了。
  ///
  /// 每次读都按种子当前状态算：`absorbedBy` 在每次重建行集 (含父件提交后的
  /// `_rebuildAfterParent`) 时会重新判定，缓存成字段会说出过期的话。
  List<String> get _absorbedSeedNames => [
    for (final seed in widget.seeds)
      if (!seed.isTop) seed.label,
  ];

  /// 记住用户**手工**取消过勾选的提交单元：重算、重试、折叠展开都不得替他
  /// 重新勾上（否则重试会下掉他明确排除的单）。程序性改动不计入。
  void _trackManualDeselection() {
    if (_programmaticSelection) return;
    final selected = {for (final row in _selectedRows) row.submitKey};
    for (final row in _allRows) {
      if (row.isSeed || !row.ownsInput || !row.selectable) continue;
      if (selected.contains(row.submitKey)) {
        _userDeselected.remove(row.submitKey);
      } else {
        _userDeselected.add(row.submitKey);
      }
    }
  }

  /// 包住所有程序性勾选改动，避免被 [_trackManualDeselection] 误记成手工操作。
  void _programmaticSelect(void Function() body) {
    _programmaticSelection = true;
    try {
      body();
    } finally {
      _programmaticSelection = false;
    }
  }

  @override
  void dispose() {
    // _grid.dispose 会销毁它手里的可见行；被折叠隐藏的行不在其中，这里补上
    // （同一行对象不能重复 dispose）。
    _grid.removeListener(_trackManualDeselection);
    final visible = _grid.rows.toSet();
    for (final row in _allRows) {
      if (!visible.contains(row)) row.dispose();
    }
    _grid.dispose();
    _pageScroll.dispose();
    super.dispose();
  }

  /// 只为「基础需求已覆盖、本批超产又有新量」的行拉一次下游申请联动：
  /// 申请未分解 → 并入申请调量；已分解 → 追加另立。加载失败不阻断（按无
  /// 联动的普通超量口径展示，用户仍可回对应桶处理）。
  Future<void> _loadSupplyLinks() async {
    final analysis = _host._analysis;
    final lineIds = <String>{
      for (final row in _allRows)
        if (row.ownsInput &&
            !row.isSeed &&
            (row.kind == _CascadeKind.buy ||
                row.kind == _CascadeKind.subcontractLeaf) &&
            row.residual <= 0.0001 &&
            row.overspill > 0.0001)
          row.id,
    };
    if (analysis == null || lineIds.isEmpty) return;
    final links = await _host.ref
        .read(productionPlanRepositoryProvider)
        .materialAnalysisSupplyLinks(analysis.analysisId, lineIds)
        .catchError((_) => const <MaterialAnalysisSupplyLink>[]);
    if (!mounted) return;
    final byLine = {for (final link in links) link.materialLineId: link};
    setState(() {
      for (final row in _allRows) {
        final link = byLine[row.id];
        if (link == null) continue;
        row.supplyLink = link;
        // 无超量权限时建议量为 0，但并入申请走采购侧端点，照填追加量。
        // 必须走 [_setQtyText]：这里原来是裸写 `row.qty.text`，控制器监听
        // 立刻把它记成「用户手工改过」，此后这行不再跟随任何父层数量重算，
        // 状态列却仍然宣称会「并入原申请 X → Y」（2026-09-15）。
        if (row.adjustIntoRequest &&
            !row.qtyTouched &&
            (double.tryParse(row.qty.text.trim()) ?? 0) <= 0) {
          _setQtyText(row, _bucketQtyText(row.overspill));
        }
      }
    });
  }

  /// [selectedKeys] 非空 = 只勾选这些提交单元（父件提交后重建：继承用户原来
  /// 勾的行，新出现的行不自动勾）；空 = 全部可选行勾上（页面首次打开）。
  /// 重建才走 dispose（旧行作废）；折叠 / 展开只换可见子集（swapRows）。
  void _installRows(List<_ChildCascadeRow> rows, {Set<String>? selectedKeys}) =>
      // 整段都是程序性改动：swapRows / setSelected 都会通知 _grid，
      // 不隔离的话 [_trackManualDeselection] 会把「还没来得及勾上」误记成
      // 用户手工取消，之后再也不给这些行补勾（提交数直接变 0）。
      _programmaticSelect(
        () => _installRowsInner(rows, selectedKeys: selectedKeys),
      );

  void _installRowsInner(
    List<_ChildCascadeRow> rows, {
    Set<String>? selectedKeys,
  }) {
    _grid.clearSelection();
    for (final row in _allRows) {
      row.dispose();
    }
    _allRows = List.unmodifiable(rows);
    _computeTreeInfo();
    _syncPageRows();
    // 「能不能并入采购申请」是账号级事实，每次重建都要重新盖上——
    // 父件提交后的重建会换一批新行对象，漏了它「并入」通道会凭空消失。
    final canAdjustRequest =
        _host._permissions.contains(Perm.purchaseRequestView) &&
        _host._permissions.contains(Perm.purchaseOrderDecompose);
    for (final row in _allRows) {
      row.canAdjustPurchaseRequest = canAdjustRequest;
      // 树顶 = 父件本身：数量预填种子的本批数量，改动回写种子并驱动全部
      // 下层重算（2026-09-14 用户口径「父类也能改数量，一改其他一起变动」）；
      // 车间 / 负责人同样从种子带出来——上一页填过的照原样显示，没填过的
      // 由 _loadWorkshopDefaults 补学习默认值（2026-09-15）。
      if (row.isSeed && row.seed != null) {
        final seed = row.seed!;
        _setQtyText(row, _bucketQtyText(seed.batchQty));
        row.qty.addListener(() => _onSeedQtyChanged(row));
        row.departmentId.value = seed.departmentId;
        row.departmentName = seed.departmentName;
        row.workerId.value = seed.workerId;
        row.workerName = seed.workerName;
        // 「默认值」这个来历跟着一起带过来：上一页是系统替他填的，这里照样
        // 标黄提醒核对；上一页手选过的保持素底(2026-09-15 用户口径)。
        row.workshopAutofilled = seed.workshopAutofilled;
        row.workerAutofilled = seed.workerAutofilled;
        continue;
      }
      if (!row.ownsInput) continue;
      // 「用户手工改过」由**控制器监听**标记，不再靠 TextField.onChanged：
      // EditableText 先通知控制器监听者、后调 onChanged，靠 onChanged 置位时
      // 第一次按键必然被吞掉（改了上层数量下层纹丝不动，第二次按键才生效）。
      row.qty.addListener(() {
        if (!_programmaticQty) {
          row.qtyTouched = true;
          // 手工填的量单独记一份：重算一趟自顶向下时读它，而不是读还没刷新
          // 的输入框文本。
          row.manualDriverQty = row.enteredQty;
        }
        _onQtyChanged(row);
      });
      if (row.selectable &&
          (selectedKeys == null || selectedKeys.contains(row.submitKey)) &&
          !_userDeselected.contains(row.submitKey)) {
        _programmaticSelect(() => _grid.setSelected([row], true));
      }
    }
    // 折叠状态按行身份继承：重建后已不存在的分支 id 要清掉，否则会把一个
    // 不存在的分支记成折叠（新行集里同 id 的行会莫名其妙收起来）。
    final liveIds = {for (final row in _allRows) row.id};
    _collapsedBranches.removeWhere((id) => !liveIds.contains(id));
    _collapsedSelection.removeWhere((id) => !liveIds.contains(id));
    _recomputeCascadeQuantities();
  }

  /// 某一行的下单量改了：只有「有子层」的行会影响下层，其余行改量不牵连别人。
  /// 重算整表比逐层递归稳妥（合并路径、孙层超产都要跟着走）。
  void _onQtyChanged(_ChildCascadeRow row) {
    if (!row.needsWorkshop) return;
    _recomputeCascadeQuantities();
  }

  /// 父件数量改动：回写种子 batchQty（父件段提交按它）、刷新本行毛需求，
  /// 并驱动整棵下层按新数量重算（手工改过的下层不动）。
  ///
  /// 2026-09-14：清空 / 填 0 / 填非法字符时**必须**把种子归零，不能保留旧值。
  /// 原来 `if (value <= 0) return;` 直接跳过，界面上是个空的红框，
  /// `_submit` 的守卫读到的却还是上一次的合法值，于是「按一个界面上根本
  /// 不存在的数量」把父件提交了。
  void _onSeedQtyChanged(_ChildCascadeRow row) {
    final seed = row.seed;
    if (seed == null) return;
    final value = row.enteredQty;
    seed.batchQty = value > 0 ? value : 0;
    row.pathGrossNeed = seed.batchQty;
    row.grossNeed = seed.batchQty;
    _recomputeCascadeQuantities();
  }

  /// 由扁平 DFS 行序推导每行的树结构投影（子树范围 / 连线 / 末位标记）。
  ///
  /// 推导本身走全站共享的 `utenTreeProjection`——本页与物料分析准备页主表、
  /// 货品 BOM 用的是同一个函数、同一套索引口径，这也是用户要求的「两处树形
  /// 显示要一样」的根上收敛（2026-09-15）。`treeKeyOf` 传 treeIndex：一次勾多
  /// 行下达时多棵树平铺在同一张表，不同树的树顶不互为兄弟。
  void _computeTreeInfo() {
    _treeInfo = utenTreeProjectionByRow<_ChildCascadeRow>(
      _allRows,
      depthOf: (row) => row.depth,
      treeKeyOf: (row) => row.treeIndex,
    );
  }

  /// 折叠状态下的可见子集：被折叠行后面的更深行整段隐藏（多级嵌套折叠天然
  /// 成立——外层先截断，内层自然不可见）。
  List<_ChildCascadeRow> _visibleRows() {
    if (_collapsedBranches.isEmpty) return _allRows;
    final visible = <_ChildCascadeRow>[];
    var hideDepth = -1;
    for (final row in _allRows) {
      if (hideDepth >= 0) {
        if (row.depth > hideDepth) continue;
        hideDepth = -1;
      }
      visible.add(row);
      if (_collapsedBranches.contains(row.id)) hideDepth = row.depth;
    }
    return visible;
  }

  void _syncPageRows() {
    final visible = _visibleRows();
    final pages = ((visible.length + _pageSize - 1) ~/ _pageSize).clamp(
      1,
      1000000,
    );
    _page = _page.clamp(1, pages);
    _grid.swapRows(
      visible.skip((_page - 1) * _pageSize).take(_pageSize).toList(),
    );
  }

  void _goToPage(int page, {bool revealError = false}) {
    if (!revealError && _hiddenByFilter.isNotEmpty) {
      context.appInfo('请先清除当前页的表头筛选，再翻页核对其他物料');
      return;
    }
    setState(
      () => _programmaticSelect(() {
        _page = page;
        _syncPageRows();
      }),
    );
    if (_pageScroll.hasClients) _pageScroll.jumpTo(0);
  }

  Widget _pager() {
    final total = _visibleRows().length;
    final pages = (total + _pageSize - 1) ~/ _pageSize;
    if (pages <= 1) return const SizedBox.shrink();
    return UtenGridPager(
      currentPage: _page,
      totalPages: pages,
      totalItems: total,
      onPrev: _running || _page <= 1 ? null : () => _goToPage(_page - 1),
      onNext: _running || _page >= pages ? null : () => _goToPage(_page + 1),
    );
  }

  /// 展开 / 收起一个分支：只换可见子集，行对象与已填内容不动。
  ///
  /// 折叠时把隐藏行的勾选撤掉（「看到的勾选 = 提交的内容」），但要**记住**
  /// 撤了谁——展开时原样放回。原来撤了就没了：折叠一个分支看一眼再展开，
  /// 之前勾好、数量也填好的下层全部掉勾，一键下单静默少下单，计数掉到 0 时
  /// 按钮还会变灰，用户以为按钮坏了（2026-09-14）。
  void _toggleBranch(_ChildCascadeRow row) {
    final index = _allRows.indexOf(row);
    if (index < 0) return;
    final subtree = <_ChildCascadeRow>[];
    for (var i = index + 1; i < _allRows.length; i++) {
      if (_allRows[i].depth <= row.depth) break;
      subtree.add(_allRows[i]);
    }
    setState(
      () => _programmaticSelect(() {
        if (_collapsedBranches.add(row.id)) {
          final selected = _selectedRows.toSet();
          for (final hidden in subtree) {
            if (selected.contains(hidden)) _collapsedSelection.add(hidden.id);
          }
          if (subtree.isNotEmpty) {
            _programmaticSelect(() => _grid.setSelected(subtree, false));
          }
        } else {
          _collapsedBranches.remove(row.id);
          final restore = [
            for (final shown in subtree)
              if (_collapsedSelection.remove(shown.id) && shown.selectable)
                shown,
          ];
          if (restore.isNotEmpty) {
            _programmaticSelect(() => _grid.setSelected(restore, true));
          }
        }
        _syncPageRows();
      }),
    );
  }

  /// 全部展开 / 全部收起：300 行的树没有这个入口没法用。
  void _setAllCollapsed(bool collapsed) {
    setState(
      () => _programmaticSelect(() {
        if (!collapsed) {
          final restore = [
            for (final row in _allRows)
              if (_collapsedSelection.remove(row.id) && row.selectable) row,
          ];
          _collapsedBranches.clear();
          if (restore.isNotEmpty) {
            _programmaticSelect(() => _grid.setSelected(restore, true));
          }
        } else {
          final selected = _selectedRows.toSet();
          for (final row in _allRows) {
            if ((_treeInfo[row]?.hasChildren ?? false)) {
              _collapsedBranches.add(row.id);
            }
          }
          final hidden = _allRows.toSet().difference(_visibleRows().toSet());
          for (final row in hidden) {
            if (selected.contains(row)) _collapsedSelection.add(row.id);
          }
          if (hidden.isNotEmpty) {
            _programmaticSelect(
              () => _grid.setSelected(hidden.toList(), false),
            );
          }
        }
        _syncPageRows();
      }),
    );
  }

  /// 父件提交成功后按最新快照重建行，并继承用户已填的数量 / 车间 / 负责人 /
  /// 勾选与申请联动。重建会 dispose 旧行，旧控制器的值必须先抓下来。
  /// 返回重建后仍可下达且原本勾选的行（被父件顺带办妥的行自然退出）。
  List<_ChildCascadeRow> _rebuildAfterParent(Set<String> selectedKeys) {
    final carried =
        <
          String,
          ({
            String? qtyText,
            String? departmentId,
            String? departmentName,
            String? workerId,
            String? workerName,
            MaterialAnalysisSupplyLink? supplyLink,
          })
        >{};
    for (final row in _allRows) {
      carried[row.submitKey] = (
        qtyText: row.qtyTouched ? row.qty.text : null,
        departmentId: row.departmentId.value,
        departmentName: row.departmentName,
        workerId: row.workerId.value,
        workerName: row.workerName,
        supplyLink: row.supplyLink,
      );
    }
    final fresh = _host._buildChildCascadeRows(widget.seeds);
    for (final row in fresh) {
      final old = carried[row.submitKey];
      if (old == null) continue;
      row.supplyLink = old.supplyLink;
      // 「用户手工改过」三种意图都要原样继承，包括**改成 0 / 清空**——那是
      // 「这行本次不下」的明确表达。原来加了一道 `> 0` 的门，重建后这些行会
      // 拿回构造函数预填的建议量并被重新勾上，等于替用户把他刚划掉的行又下了
      // 一遍（2026-09-15）。
      if (old.qtyText != null) {
        row.qty.text = old.qtyText!.trim();
        row.qtyTouched = true;
        row.manualDriverQty = row.enteredQty;
      }
      if (old.departmentId != null) {
        row.departmentId.value = old.departmentId;
        row.departmentName = old.departmentName;
        row.workerId.value = old.workerId;
        row.workerName = old.workerName;
      }
    }
    _installRows(fresh, selectedKeys: selectedKeys);
    unawaited(_withLoading(_loadWorkshopDefaults));
    unawaited(_withLoading(_loadSupplyLinks));
    return [
      for (final row in fresh)
        if (selectedKeys.contains(row.submitKey) && row.selectable) row,
    ];
  }

  /// 任一行数量改动后整表重算（不再是逐层递归的增量刷新）。
  ///
  /// 自顶向下逐边算量，按提交单元汇总并扣已覆盖量，然后刷新建议与输入框。
  /// 用户输入单独保留，不能读取尚未刷新的旧文本作为下一层驱动量。
  void _recomputeCascadeQuantities() {
    if (_allRows.isEmpty) return;
    // 重入保护：本函数末尾会写数量框，而「有子层」行的控制器监听又会回调
    // _onQtyChanged → 本函数。虽然文本相等时 _setQtyText 会提前返回、递归最终
    // 收敛，但 300 行的树足以叠出很深的调用栈，也白跑好几轮 O(n) 重算。
    if (_recomputing) return;
    _recomputing = true;
    try {
      _recomputeCascadeQuantitiesInner();
    } finally {
      _recomputing = false;
    }
  }

  bool _recomputing = false;

  void _recomputeCascadeQuantitiesInner() {
    final driverByRowId = <String, double>{};
    final grossBySubmitKey = <String, double>{};
    // 一趟自顶向下即可：行序就是 DFS，父行必然先于子行被处理。
    //
    // 2026-09-15 去掉了原来的「两趟」：第二趟用 `row.enteredQty` 当驱动量，
    // 读的却是**本次重算还没写入**的旧输入框文本（新值到函数末尾才写）。
    // 数量往大改时毛需求更大、旧值被 max 吞掉，恰好掩盖了问题；往小改时旧
    // 文本更大，孙层就继续按上一次的父层数量算——界面上「子件要 10、孙件要
    // 60」自相矛盾，按 60 下出去就是多下。用户手工超产的那份量改存在
    // [_ChildCascadeRow.manualDriverQty] 上（只在真的手工改过时写），
    // 驱动量取 max(待制造产出, 手工量)，一趟就收敛。
    for (final row in _allRows) {
      if (row.isSeed) {
        final qty = row.seed?.batchQty ?? row.pathGrossNeed;
        row.pathGrossNeed = qty;
        row.grossNeed = qty;
        driverByRowId[row.id] = materialCascadeBaseOutputQty(
          qty,
          row.seed?.outputUnitRate ?? 1,
        );
        continue;
      }
      final parentId = row.parentMaterialLineId;
      final driver = parentId == null ? null : driverByRowId[parentId];
      // 缺单位耗用的历史行（scaled=false）不硬凑比例：保持快照需求不动。
      if (driver != null && row.scaled && row.material != null) {
        row.pathGrossNeed =
            _host._cascadeRequiredQty(
              row.material!,
              driver,
              row.parentPerProduct,
            ) ??
            row.pathGrossNeed;
      }
      grossBySubmitKey[row.submitKey] =
          (grossBySubmitKey[row.submitKey] ?? 0) + row.pathGrossNeed;
      // 已有现货与外部最终件不用再生产；内部制造承诺仍需其下层材料。
      // 明确手工加做的数量继续向下传递，不能被默认净需覆盖。
      final manual = row.manualDriverQty;
      final manufacturing = row.material == null
          ? row.pathGrossNeed
          : _host._cascadeManufacturingQty(row.material!, row.pathGrossNeed);
      driverByRowId[row.id] = manual > manufacturing ? manual : manufacturing;
    }
    // 汇总回各提交单元的持有行（同一物料多条 BOM 路径只有第一处能填数）。
    for (final row in _allRows) {
      if (row.isSeed) continue;
      row.grossNeed = row.ownsInput
          ? (grossBySubmitKey[row.submitKey] ?? row.pathGrossNeed)
          : row.pathGrossNeed;
      if (!row.ownsInput) continue;
      row.overspill = row.grossNeed - row.snapshotNeed > 0.0001
          ? row.grossNeed - row.snapshotNeed
          : 0;
      // 与建表时逐字同一口径（见 _materializeCascadeRows）：车间去向按 V577
      // 可超量；采购 / 无子层委外要 over_supply 权限。原来这里漏了 kind 分支，
      // 无权限的人也能把委外行的超产量算进建议量，提交必被服务端拒。
      final allowOver =
          row.kind == _CascadeKind.workshop ||
          (_host._canOverSupply &&
              (row.kind == _CascadeKind.buy ||
                  row.kind == _CascadeKind.subcontractLeaf));
      row.overCapped = row.overspill > 0.0001 && !allowOver;
      row.minQty = materialCascadeNetQty(
        grossNeed: row.grossNeed,
        snapshotNeed: row.snapshotNeed,
        residual: row.residual,
        allowOver: allowOver,
      );
      var suggested = row.minQty;
      // 与建表时同源：采购行套最小起订量 / 订货倍数（软约束，不进下限）。
      if (row.kind == _CascadeKind.buy && suggested > 0) {
        final group = _host._analysisGroupOf(row.groupKey);
        if (group != null) {
          suggested = _host._submitQtyWithOrderPolicy(
            group,
            row.route,
            suggested,
          );
        }
      }
      row.suggested = suggested;
    }
    for (final row in _allRows) {
      if (row.isSeed || !row.ownsInput || row.qtyTouched) continue;
      _setQtyText(row, row.suggested > 0 ? _bucketQtyText(row.suggested) : '');
    }
    _syncSelectionWithSelectable();
    if (mounted) setState(() {});
  }

  /// 程序性写入数量框：不能被当成「用户手工改过」（否则上层数量再变时
  /// 这行就不跟着重算了）。
  void _setQtyText(_ChildCascadeRow row, String text) {
    if (row.qty.text == text) return;
    _programmaticQty = true;
    row.qty.text = text;
    _programmaticQty = false;
  }

  /// 重算后勾选集要跟着走：变得不可下达的行撤勾（否则界面打着勾却被静默
  /// 跳过），新变得可下达的行自动补勾（用户手工取消过的除外）。
  void _syncSelectionWithSelectable() {
    final drop = <_ChildCascadeRow>[];
    final add = <_ChildCascadeRow>[];
    final selected = _selectedRows.toSet();
    for (final row in _allRows) {
      if (row.isSeed || !row.ownsInput) continue;
      if (!row.selectable) {
        if (selected.contains(row)) drop.add(row);
        continue;
      }
      if (!selected.contains(row) && !_userDeselected.contains(row.submitKey)) {
        add.add(row);
      }
    }
    _programmaticSelect(() {
      if (drop.isNotEmpty) _grid.setSelected(drop, false);
      if (add.isNotEmpty) _grid.setSelected(add, true);
    });
  }

  Future<void> _loadWorkshopDefaults() async {
    final goodsIds = <String>{
      for (final row in _allRows)
        if (row.needsWorkshop && (row.goodsId?.isNotEmpty ?? false))
          row.goodsId!,
    };
    if (goodsIds.isEmpty) return;
    final results = await Future.wait([
      _host.ref
          .read(productionPlanRepositoryProvider)
          .defaultWorkshops(goodsIds)
          .catchError(
            (_) =>
                const <
                  String,
                  ({
                    String departmentId,
                    String? departmentName,
                    String? workerId,
                    String? workerName,
                  })
                >{},
          ),
      _workshopTreeOrNull(),
    ]);
    if (!mounted) return;
    _workshopDefaults =
        results[0]
            as Map<
              String,
              ({
                String departmentId,
                String? departmentName,
                String? workerId,
                String? workerName,
              })
            >;
    final tree = results[1] as List<DepartmentNode>;
    _workshopManagers = {
      for (final node in tree)
        if (node.managerId?.isNotEmpty == true)
          node.id: (id: node.managerId, name: node.managerName),
    };
    for (final row in _allRows) {
      if (!row.needsWorkshop || row.departmentId.value != null) continue;
      final learned = _workshopDefaults[row.goodsId];
      if (learned == null) continue;
      row.departmentId.value = learned.departmentId;
      row.departmentName = learned.departmentName;
      row.workshopAutofilled = true;
      final manager = _workshopManagers[learned.departmentId];
      row.workerId.value = learned.workerId ?? manager?.id;
      row.workerName = learned.workerName ?? manager?.name;
      row.workerAutofilled = row.workerId.value != null;
      // 树顶行补出来的默认值同样要回写种子，否则「界面显示 A 车间、提交的
      // 却是空」——父件段读的是种子，不是行对象。`departmentId.value != null`
      // 那道门保证了上一页已选的值不会被学习默认覆盖。
      _syncSeedAssignment(row);
    }
    setState(() {});
  }

  Future<List<DepartmentNode>> _workshopTreeOrNull() async {
    try {
      final tree = await _host.ref.read(departmentRepositoryProvider).tree();
      return findDepartmentByCode(tree, kDeptCodeProduction)?.children ??
          const [];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _pickWorkshop(_ChildCascadeRow row) async {
    final tree = await _workshopTreeOrNull();
    if (!mounted) return;
    final workshopIds = {for (final node in tree) node.id};
    final picked = await showUtenDepartmentPickerPanel(
      context,
      tree: tree,
      selectablePredicate: (node) => workshopIds.contains(node.id),
      initialSelection: row.departmentId.value == null
          ? const []
          : [
              DeptSelection(
                id: row.departmentId.value!,
                name: row.departmentName ?? '',
                fullPath: '',
                level: '',
              ),
            ],
    );
    final selection = picked == null || picked.isEmpty ? null : picked.first;
    if (selection == null || !mounted) return;
    setState(() {
      if (row.departmentId.value != selection.id) {
        final learned = _workshopDefaults[row.goodsId];
        final remembered =
            learned != null &&
                learned.departmentId == selection.id &&
                learned.workerId != null
            ? (id: learned.workerId, name: learned.workerName)
            : null;
        final manager = remembered ?? _workshopManagers[selection.id];
        row.workerId.value = manager?.id;
        row.workerName = manager?.name;
        row.workerAutofilled = manager != null;
      }
      row.departmentId.value = selection.id;
      row.departmentName = selection.name;
      row.workshopAutofilled = false;
      _syncSeedAssignment(row);
    });
  }

  /// 树顶行的车间/负责人回写种子：父件段与「前置自制下达车间」段都读种子，
  /// 而快照一换行对象就作废——种子是这份用户输入唯一不失效的落点
  /// （与 `_onSeedQtyChanged` 回写 batchQty 同款）。
  void _syncSeedAssignment(_ChildCascadeRow row) {
    final seed = row.seed;
    if (!row.isSeed || seed == null) return;
    seed.departmentId = row.departmentId.value;
    seed.departmentName = row.departmentName;
    seed.workerId = row.workerId.value;
    seed.workerName = row.workerName;
    // 来历一起回写：父件提交后整棵树重建时读的是种子，漏了它「手选过」会
    // 退回标黄，「学习默认补上的」又会变成素底。
    seed.workshopAutofilled = row.workshopAutofilled;
    seed.workerAutofilled = row.workerAutofilled;
  }

  Future<void> _pickWorker(_ChildCascadeRow row) async {
    final picked = await showUtenEmployeePickerPanel(
      context,
      title: '选择生产负责人',
      selectedId: row.workerId.value,
      departmentName: row.departmentName,
      loader: (keyword) async {
        final result = await _host.ref
            .read(employeeRepositoryProvider)
            .list(
              size: 30,
              search: keyword,
              departmentId: (keyword?.trim().isEmpty ?? true)
                  ? row.departmentId.value
                  : null,
              includeSubtree: true,
            );
        return [
          for (final employee in result.items)
            UtenEmployeePickerItem(
              id: employee.id,
              name: employee.fullName,
              employeeCode: employee.code,
              departmentName: employee.departmentName,
            ),
        ];
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      row.workerId.value = picked.id;
      row.workerName = picked.name;
      row.workerAutofilled = false;
      _syncSeedAssignment(row);
    });
  }

  // ===== 提交 =====

  String? _validate(List<_ChildCascadeRow> rows) {
    final badQty = <String>[];
    final overQty = <String>[];
    final noWorkshop = <String>[];
    final noWorker = <String>[];
    final stale = <String>[];
    final belowMin = <String>[];
    for (final row in rows) {
      final name = _rowName(row);
      final qty = double.tryParse(row.qty.text.trim());
      // isFinite 挡住 1e400（double.parse 会给出 Infinity，一路送进 JSON
      // 就是个非法数）；inputFormatters 已经限制了字符，这里是最后一道。
      if (qty == null || !qty.isFinite || qty <= 0) {
        badQty.add('「$name」');
        continue;
      }
      // 提交前按当前行状态再核一次资格：页面开着的这段时间里数量改动 /
      // 申请联动到货都可能让某行变成不可下达，勾着的行会在服务端整段被挡。
      if (!row.selectable) {
        stale.add('「$name」${row.blockedReason ?? '已不可下达，请刷新后重试'}');
        continue;
      }
      // 并入已有申请：追加量 > 0 即可，权限与守卫由采购侧 V477 端点自裁。
      if (row.adjustIntoRequest) continue;
      // 采购/无子层委外超过「本批缺口 − 已在途」要走公共超量通道；没有
      // 超量下达权限时服务端会拒，这里先点名，不静默改小。
      if (row.kind != _CascadeKind.workshop &&
          !_host._canOverSupply &&
          qty > row.residual + 0.0001) {
        overQty.add(
          row.appendToOrdered
              ? '「$name」已下过单，追加 ${_host._qty(qty)} 需要超量下达权限'
              : '「$name」本次 ${_host._qty(qty)} / 可下达 ${_host._qty(row.residual)}',
        );
        continue;
      }
      // 低于按父层算出来的下限：父件会缺料，不放行（用户口径「不能填小于」）。
      if (row.belowMinimum) {
        belowMin.add(
          '「$name」至少 ${_host._qty(row.minRequiredQty)}，现填 ${_host._qty(qty)}',
        );
        continue;
      }
      if (!row.needsWorkshop) continue;
      if (row.departmentId.value?.isNotEmpty != true) {
        noWorkshop.add('「$name」');
        continue;
      }
      if (row.workerId.value?.isNotEmpty != true) noWorker.add('「$name」');
    }
    final problems = <String>[
      if (badQty.isNotEmpty) _issueLine(badQty, '下单数量必须填一个大于 0 的数字'),
      if (stale.isNotEmpty) _issueLine(stale, '在最新快照里已不可下达'),
      if (belowMin.isNotEmpty)
        _issueLine(belowMin, '低于按父件本批数量算出来的下限，父件会缺料——可以多下，不能少下'),
      if (overQty.isNotEmpty) _issueLine(overQty, '超过可下达量，需要超量下达权限，请改小或找有权限的人'),
      if (noWorkshop.isNotEmpty) _issueLine(noWorkshop, '尚未选择生产车间'),
      if (noWorker.isNotEmpty) _issueLine(noWorker, '尚未选择负责人'),
    ];
    return problems.isEmpty ? null : problems.join('\n');
  }

  String _issueLine(List<String> labels, String issue) {
    const maxShown = 8;
    final shown = labels.take(maxShown).join('、');
    final rest = labels.length - maxShown;
    return '以下 ${labels.length} 行$issue：$shown${rest > 0 ? ' 等 $rest 行' : ''}';
  }

  String _rowName(_ChildCascadeRow row) => row.displayName;

  /// 父件（树顶）一级的校验 + 超量二次确认。返回 false = 不要提交。
  ///
  /// 三件事，缺一不可：
  /// 1. 数量必须是大于 0 的有限数（清空 / 填 0 时种子已归零，不能按界面上
  ///    根本不存在的数量提交）；
  /// 2. 要下车间的父件必须有生产车间与负责人——这正是用户说的「限制都没有」；
  /// 3. 超过本次可下达上限的，复用分桶页那句「超出部分按公共备货产出记账」，
  ///    把去向讲清楚再放行（不是静默改小，也不是静默放行）。
  Future<bool> _validateAndConfirmSeeds() async {
    final badQty = <String>[];
    final noWorkshop = <String>[];
    final noWorker = <String>[];
    final over = <String>[];
    for (final seed in _topSeeds) {
      if (seed.batchQty <= 0 || !seed.batchQty.isFinite) {
        badQty.add('「${seed.label}」');
        continue;
      }
      final cap = seed.maxQty;
      // 只对**在本页被改大**的数量再确认一次：进页前那个数已经在分桶页过过
      // 「确认超量下达车间」了（bucket_detail 的 `_overQtyRows`），同一个数字
      // 连问两遍是噪音。
      final raisedHere =
          (seed.batchQty - (_initialSeedQty[seed] ?? seed.batchQty)).abs() >
          0.0001;
      // 委外桶改走 issue-plans 的行上一页没问过超量 (overQtyConfirmed=false)，
      // 这里必须补问一次，不能静默放行。
      if ((raisedHere || !seed.overQtyConfirmed) &&
          cap != null &&
          cap > 0 &&
          seed.batchQty > cap + 0.0001) {
        over.add(
          '· 「${seed.label}」需求 ${_host._qty(cap)} → 本批 '
          '${_host._qty(seed.batchQty)}（超出 ${_host._qty(seed.batchQty - cap)}）',
        );
      }
      if (!seed.needsWorkshop) continue;
      if (seed.departmentId?.isNotEmpty != true) {
        noWorkshop.add('「${seed.label}」');
        continue;
      }
      if (seed.workerId?.isNotEmpty != true) noWorker.add('「${seed.label}」');
    }
    final problems = <String>[
      if (badQty.isNotEmpty) _issueLine(badQty, '本批数量必须填一个大于 0 的数字'),
      if (noWorkshop.isNotEmpty) _issueLine(noWorkshop, '尚未选择生产车间'),
      if (noWorker.isNotEmpty) _issueLine(noWorker, '尚未选择负责人'),
    ];
    if (problems.isNotEmpty) {
      context.appError(problems.join('\n'));
      return false;
    }
    if (over.isEmpty) return true;
    final ok = await UtenDialog.show(
      context,
      title: '确认超量下达',
      content: Text(
        '以下 ${over.length} 行填写的本批数量超出当前需求：\n'
        '${over.join('\n')}\n\n'
        '超出部分按公共备货产出记账：完工入库后进公共库存，其他计划可以直接用，'
        '不占本次需求的精确账；同一张计划分别记录需求份与公共备货份，'
        '订单侧数量不受影响。\n'
        '本页下面列出的下层物料已经按这个数量算好了，一起下单即可配套。',
      ),
      confirmLabel: '确认超量下达',
    );
    return ok == true;
  }

  /// 名单统一封顶 8 条，其余折成「等 N 行」——与 [_issueLine] 同一口径，
  /// 免得同一页出现两套「最多列多少条」的规矩。
  String _names(Iterable<String> labels) {
    const maxShown = 8;
    final all = labels.toList(growable: false);
    final shown = all.take(maxShown).join('、');
    return '$shown${all.length > maxShown ? ' 等 ${all.length} 行' : ''}';
  }

  Future<void> _submit() async {
    if (_running) return;
    // 父件（树顶）一级的校验必须挂在这里：`_validate` 只遍历勾选行，而树顶
    // 永不可勾选（`selectable` 第一条就是 `!isSeed`），塞进去也跑不到。
    // 2026-09-15 起除数量外还校验车间 / 负责人，并对超上限的数量走与分桶页
    // 同一句超量二次确认——原先级联页改树顶数量是**整页绕过**分桶页那两道闸的。
    if (widget.parentAction != null && !_parentSubmitted) {
      final parentOk = await _validateAndConfirmSeeds();
      if (!parentOk || !mounted) return;
    }
    final selected = _selectedRows
        .where((row) => row.selectable)
        .toList(growable: false);
    // 一行下层都没勾：本页仍然是**父件的唯一提交出口**（前置模式下父件还没
    // 落库），不能就这么把按钮变灰把人堵死——把树顶折叠一下就会踩到。
    // 问清楚「只下父件、下层稍后自己办」，确认了就只跑父件段。
    if (selected.isEmpty) {
      if (widget.parentAction == null || _parentSubmitted) {
        context.appInfo('请先勾选要下单的下层物料');
        return;
      }
      final onlyParent = await UtenDialog.show(
        context,
        title: '只下达父件？',
        content: const Text(
          '当前一行下层都没有勾选。继续将**只提交父件**，下层物料保持原样——'
          '多做出来的那部分料要你自己回物料分析主表另行安排，否则车间领料时才会发现缺料。',
        ),
        confirmLabel: '只下达父件',
      );
      if (onlyParent != true || !mounted) return;
      await _runSegments(const [], parentOnly: true);
      return;
    }
    // 勾着但被表头筛选藏起来的行：不静默提交，也不静默丢掉，直接请用户
    // 先清掉筛选——「看到的勾选 = 提交的内容」这条口径不能有例外。
    final hiddenSelected = selected
        .where(_hiddenByFilter.contains)
        .toList(growable: false);
    if (hiddenSelected.isNotEmpty) {
      context.appError(
        '有 ${hiddenSelected.length} 行已勾选但被表头筛选隐藏'
        '（${_names(hiddenSelected.map(_rowName))}）：请先清除表头筛选再提交，'
        '避免下单了屏幕上看不见的行',
      );
      return;
    }
    final error = _validate(selected);
    if (error != null) {
      final invalid = selected
          .where((row) => _validate([row]) != null)
          .firstOrNull;
      final index = invalid == null ? -1 : _visibleRows().indexOf(invalid);
      if (index >= 0) _goToPage(index ~/ _pageSize + 1, revealError: true);
      context.appError(error);
      return;
    }
    final byKind = <_CascadeKind, int>{};
    for (final row in selected) {
      byKind[row.kind] = (byKind[row.kind] ?? 0) + 1;
    }
    final needRoute = selected
        .where((row) => row.confirmedRoute != row.route)
        .length;
    // 已下过单的两类要当面说清去向（用户口径「问是不是追加」）：
    // 并入申请 = 把原申请明细数量改大；追加 = 另立一张申请加量。
    final adjusting = selected
        .where((row) => row.adjustIntoRequest)
        .toList(growable: false);
    // 「已下过单且已分解」的行本页不下单（不可勾选），所以要从**全表**里找，
    // 而不是从勾选集里找——它们正是用户最容易以为「一起办掉了」的那几行，
    // 必须在确认弹窗里点名说清本次不含它们。
    final appending = _allRows
        .where((row) => row.appendToOrdered)
        .toList(growable: false);
    // 超产行要当面点清：多做的那批料就是靠本页补出来的，用户必须看到
    // 「哪几行超了、超多少」，而不是提交完才发现。
    final over = selected
        .where((row) => row.overspill > 0.0001)
        .toList(growable: false);
    final ok = await UtenDialog.show(
      context,
      title: '确认一键下单下层物料',
      // 逐行名单可能有几十条，套一层滚动并统一封顶 8 条，别把确认按钮顶出屏幕。
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: SingleChildScrollView(
          child: Text(
            [
              if (widget.parentAction != null && !_parentSubmitted)
                '第一步先提交本次下达的父件（${_topSeeds.length} 行），成功后自动接着办下层。',
              if (_parentSubmitted) '父件已在上一次执行中提交成功，本次只办下层。',
              '将按各自路线依次下达 ${selected.length} 行：',
              for (final entry in byKind.entries)
                '· ${entry.key.label}：${entry.value} 行',
              if (over.isNotEmpty)
                '其中 ${over.length} 行含超产多需（本批数量高于需求带出来的量）：'
                    '${_names(over.map((row) => '${_rowName(row)} +${_host._qty(row.overspill)}'))}',
              if (adjusting.isNotEmpty)
                '其中 ${adjusting.length} 行基础需求已生成采购申请且尚未分解，'
                    '追加量将并入原申请（明细数量直接改大）：'
                    '${_names(adjusting.map((row) => '${_rowName(row)} ${_host._qty(row.supplyLink!.itemQty)}→${_host._qty(row.supplyLink!.itemQty + row.enteredQty)}'))}',
              if (appending.isNotEmpty)
                '其中 ${appending.length} 行已下过单且已分解，本页不下单，请到下游模块追加：'
                    '${_names(appending.map(_rowName))}',
              if (needRoute > 0) '其中 $needRoute 行会先按表内显示的路线确认路线。',
              '',
              '各下达路径各自提交（不是同一个事务）：任一段失败会立即停下并'
                  '如实告诉你停在哪一步，已成功的段保留在服务端，重试不会重复建单。',
            ].join('\n'),
          ),
        ),
      ),
      confirmLabel: '一键下单',
    );
    if (ok != true || !mounted) return;
    await _runSegments(selected);
  }

  /// 执行编排（父件段 + 下层各段）。[parentOnly] = 一行下层都没勾，只跑父件段。
  Future<void> _runSegments(
    List<_ChildCascadeRow> selected, {
    bool parentOnly = false,
  }) async {
    setState(() {
      _running = true;
      _lastRun = const [];
    });
    List<_CascadeStepResult> results = const [];
    final selectedKeys = {for (final row in selected) row.submitKey};
    // 父件段只在前置模式且**尚未提交成功**时执行：失败重试不重发父件
    // （首次提交后快照已换版本，重发=新幂等键=真实重复下单）。
    Future<bool> parentSegment() async {
      final ok = await widget.parentAction!();
      if (ok) _parentSubmitted = true;
      return ok;
    }

    final parentPending = widget.parentAction != null && !_parentSubmitted;
    try {
      if (parentOnly) {
        final ok = parentPending ? await parentSegment() : true;
        results = [
          (
            label: '父件下达',
            count: ok ? _topSeeds.length : 0,
            ok: ok,
            note: ok
                ? '下层未办理：本次一行都没有勾选，多做部分的料请回物料分析主表安排'
                : '父件未提交成功，下层未动，可直接重试',
          ),
        ];
      } else {
        results = await _host._executeChildCascade(
          selected,
          seeds: widget.seeds,
          parentAction: parentPending ? parentSegment : null,
          rebuildAfterParent: parentPending
              ? () => _rebuildAfterParent(selectedKeys)
              : null,
          parentCount: _topSeeds.length,
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
    if (!mounted) return;
    final allOk = results.isNotEmpty && results.every((step) => step.ok);
    if (allOk) {
      Navigator.of(context).pop(true);
      context.appSuccess(
        '已一起下单：${results.map((step) => '${step.label} ${step.count} 行').join('、')}',
      );
      return;
    }
    // 失败留在本页：按最新快照重算（已成功的行会变成「已下达」），可直接重试。
    //
    // 2026-09-14：重建必须**继承**用户填的数量 / 车间 / 负责人 / 申请联动与
    // 勾选。原来直接丢一份全新行集进去，提示写着「可直接重试」，实际却把
    // 车间和负责人清空了——第二次提交必然报「尚未选择生产车间」；而且把用户
    // 手工取消过的行重新全部勾上，重试会下掉他明确不想下的单。
    setState(() {
      _lastRun = results;
      _rebuildAfterParent(selectedKeys);
    });
  }

  // ===== 退出 =====

  /// 退出会不会丢掉一次还没提交的下达（前置模式 + 父件段尚未成功）。
  bool get _exitNeedsConfirm =>
      widget.parentAction != null && !_parentSubmitted;

  void _exitPage() {
    if (_running) return;
    if (!_exitNeedsConfirm) {
      Navigator.of(context).pop(false);
      return;
    }
    unawaited(_confirmDiscard());
  }

  Future<void> _confirmDiscard() async {
    final seedNames = _topSeeds.map((seed) => seed.label).toList();
    final ok = await UtenDialog.show(
      context,
      title: '放弃本次下达？',
      content: Text(
        '「${_names(seedNames)}」这次下达**还没有提交**：上一页点的那一下只是'
        '打开了本页，真正的提交在「一键下单」里。\n\n'
        '现在离开，父件与下层都不会下达，页面上填好的数量、车间与负责人也会丢失。',
      ),
      confirmLabel: '放弃本次下达',
      danger: true,
    );
    if (ok != true || !mounted) return;
    Navigator.of(context).pop(false);
  }

  // ===== 页面 =====

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      // 提交途中不许离开：编排是多段的，页面一销毁后面几段就没人回报结果，
      // 用户以为全下完了。系统返回键 / 手势同样拦住（原来只把左上角返回按钮
      // 置灰，而 UtenBackButton 的 onPressed:null 反而会走默认返回，真能退出）。
      // 前置模式下父件**还没提交**：退出等于把这次下达整个作废。原来返回键与
      // 「稍后再办」都直接 pop(false)，零提示——用户在分桶页点的是一个叫
      // 「下达委外(N)」的红按钮，退出后自然以为已经下达了，回头看那行还在
      // 「未下达」，正是用户反馈 2 的最直接来源（2026-09-15）。
      canPop: !_running && !_exitNeedsConfirm,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !mounted) return;
        if (_running) {
          context.appInfo('正在下达，请等本次执行结束');
          return;
        }
        unawaited(_confirmDiscard());
      },
      child: Scaffold(
        key: const Key('material-analysis-child-cascade-dialog'),
        appBar: UtenAppBar(
          title: widget.parentAction == null || _parentSubmitted
              ? '继续办齐下层物料'
              : '父件 + 下层一起下单',
          // 与分桶详情同款：宿主页的命令式子弹层，无独立路由 scope，权限入口
          // 由宿主页承载（非 go_router 页路由不得解析 scope，fail-closed 契约）。
          showPagePermissionAction: false,
          leading: UtenBackButton(onPressed: _running ? null : _exitPage),
          actions: [
            IconButton(
              tooltip: '全部展开',
              icon: const Icon(Icons.unfold_more_rounded),
              onPressed: _running ? null : () => _setAllCollapsed(false),
            ),
            IconButton(
              tooltip: '全部收起',
              icon: const Icon(Icons.unfold_less_rounded),
              onPressed: _running ? null : () => _setAllCollapsed(true),
            ),
          ],
        ),
        body: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                UtenSpacing.s8,
                UtenSpacing.s16,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _hintCard(theme),
                  if (_truncationNote != null) _truncationCard(theme),
                  if (_lastRun.isNotEmpty) _resultCard(theme),
                  const SizedBox(height: UtenSpacing.s8),
                  _pager(),
                  Expanded(
                    // 网格按内容收缩 + 外层滚动（网格表体 NeverScrollable，与
                    // 分桶详情/编辑页同款结构）——2026-09-14 用户口径「不能鼠标
                    // 上下滚动」即缺这层包裹。
                    child: SingleChildScrollView(
                      controller: _pageScroll,
                      padding: const EdgeInsets.only(
                        // 给右下角悬浮动作组让位（全站统一口径）。
                        bottom: UtenFloatingActionGroup.scrollClearance,
                      ),
                      child: _table(theme),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              right: UtenSpacing.s16,
              bottom: UtenSpacing.s16,
              child: AnimatedBuilder(
                animation: _grid,
                builder: (context, _) {
                  final count = _selectedRows
                      .where((row) => row.selectable)
                      .length;
                  return UtenFloatingActionGroup(
                    children: [
                      UtenSelectionSummaryPill(
                        count: count,
                        clearKey: const Key(
                          'material-analysis-child-cascade-selected-count',
                        ),
                        onClear: count == 0 || _running
                            ? null
                            : _grid.clearSelection,
                      ),
                      UtenButton(
                        key: const Key(
                          'material-analysis-child-cascade-discard',
                        ),
                        type: UtenButtonType.ghost,
                        size: UtenButtonSize.large,
                        onPressed: _running ? null : _exitPage,
                        // 文案必须说实话：前置模式下退出不是「下层稍后再办」，
                        // 而是父件也一并作废。
                        child: Text(_exitNeedsConfirm ? '放弃本次下达' : '稍后再办'),
                      ),
                      UtenButton(
                        key: const Key(
                          'material-analysis-child-cascade-submit',
                        ),
                        type: UtenButtonType.danger,
                        size: UtenButtonSize.large,
                        // count==0 时按钮**不能**变灰：前置模式下本页是父件的
                        // 唯一提交出口，堵死了用户只能退出重来（把树顶折叠一下
                        // 就会踩到）。改为进去问「只下达父件？」。
                        onPressed:
                            _running ||
                                _busy ||
                                (count == 0 &&
                                    (widget.parentAction == null ||
                                        _parentSubmitted))
                            ? null
                            : _submit,
                        child: Text(
                          _running
                              ? '正在下达…'
                              : _busy
                              ? '正在载入默认车间…'
                              : count == 0
                              ? '只下达父件'
                              : '一键下单($count)',
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            // 一键下单跑批期间的全屏加载遮罩（2026-09-15 用户口径「点了下达
            // 没反馈像卡住」）：本页是 opaque 整页压在宿主页/分桶页上，它们
            // Stack 里那两份遮罩（bucketActionBusyMessage /
            // planSubmissionProgress）被盖住根本不会 build——段内标题必须
            // 本页自己接住。段间隙（重建行集、组幂等键等纯本地段）用通用
            // 文案兜底；确认弹窗都在跑批前收口，遮罩只盖网络段（全站口径）。
            AnimatedBuilder(
              animation: Listenable.merge([
                _host.bucketActionBusyMessage,
                _host.planSubmissionProgress,
              ]),
              builder: (context, _) {
                if (!_running) return const SizedBox.shrink();
                final segment = _host.bucketActionBusyMessage.value;
                // 车间段标题与宿主页 _planSubmissionOverlay 同一逻辑（有审核
                // 权限时是「生成并审核下达」），避免两级文案漂移。
                final generatingTitle = _host._planSubmissionApproveNow
                    ? '正在生成并审核下达'
                    : '正在生成生产计划';
                return UtenBusyOverlay(
                  semanticsKey: const Key(
                    'material-analysis-child-cascade-busy',
                  ),
                  title:
                      segment ??
                      (_host.planSubmissionProgress.value
                          ? generatingTitle
                          : '正在按批次下达所选行'),
                  description: '父件与下层逐段提交：任一段失败会停下提示，已成功的段不会重复下单。',
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部提示：一句结论常驻，细则折叠。原来 8-10 行大段文字常驻顶部、
  /// 又在不可滚动的 Column 里，窄高窗口会把表格挤没甚至溢出。
  Widget _hintCard(ThemeData theme) {
    final seedText = _topSeeds
        .map(
          (seed) =>
              '${seed.label} ${_host._qty(seed.batchQty)}'
              '${seed.unitName?.trim().isNotEmpty == true ? ' ${seed.unitName!.trim()}' : ''}',
        )
        .join('、');
    final submitted = widget.parentAction == null || _parentSubmitted;
    // 被祖先吸收的勾选行要点名：用户勾了它，却在树顶名单里看不到，必须说清
    // 它去了哪里、数量为什么会跟着上层变 (2026-09-16)。
    final absorbedText = _absorbedSeedNames.isEmpty
        ? ''
        : '你同时勾选的 ${_absorbedSeedNames.length} 行'
              '（${_names(_absorbedSeedNames)}）是上面这些件的下层，已并进对应的树里：'
              '数量随上层本批数量一起算，车间/负责人沿用你在上一页填的。';
    final headline = submitted
        ? '已下达：$seedText。下面是它按 BOM 展开的下层，数量已按本批数量算好，可以改。$absorbedText'
        : '本次将下达：$seedText，以及下面按 BOM 展开的下层。点「一键下单」才会真正提交。$absorbedText';
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  headline,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_hintExpanded) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '· 树最上面一行就是本次下达的件，改它的数量，没手工改过的下层会跟着重算。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '· 一键下单按各行「下达去向」分流：采购 → 下达采购；无子层委外 → 下达委外；自制与有子层委外 → 下达车间出计划。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '· 数量可以填得比需求大：车间超出部分记公共备货产出；采购 / 无子层委外超出部分需要超量下达权限。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '· 已下过单且申请尚未分解的行，追加量并入原申请（明细数量改大）；已分解出订货单的行请到采购 / 委外模块追加，本页不下单。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '· 各下达路径各自提交（不是同一个事务）：任一段失败会立即停下并如实告诉你停在哪一步，已成功的段保留在服务端。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _hintExpanded = !_hintExpanded),
            child: Text(_hintExpanded ? '收起说明' : '查看说明'),
          ),
        ],
      ),
    );
  }

  /// BOM 被截断时**必须**明说：否则用户以为「下层就这些」，漏掉的料要到车间
  /// 领料时才发现（对应用户「很多数据都没有显示」）。
  String? get _truncationNote {
    final parts = <String>[
      if (_host._cascadeRowLimitHit)
        '下层超过 ${_MaterialAnalysisChildCascadeState._cascadeRowLimit} 行，'
            '本页只展开了前 ${_allRows.length} 行',
      if (_host._cascadeDepthLimitHit)
        '有分支深于 ${_MaterialAnalysisChildCascadeState._cascadeDepthLimit} 层，'
            '更深的下层没有列出',
    ];
    return parts.isEmpty ? null : parts.join('；');
  }

  Widget _truncationCard(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(top: UtenSpacing.s8),
    child: Container(
      key: const Key('material-analysis-child-cascade-truncated'),
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.35),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.tertiary),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: theme.colorScheme.tertiary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '${_truncationNote!}。没列出来的下层本次不会被下单，请到物料分析主表逐层办理。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    ),
  );

  /// 上次执行结果：逐段一行（成功打勾 / 失败打叉 + 原因），不再把成功段和
  /// 失败段拼成一句长文本。
  Widget _resultCard(ThemeData theme) {
    final failed = _lastRun.any((step) => !step.ok);
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Container(
        key: const Key('material-analysis-child-cascade-result'),
        padding: const EdgeInsets.all(UtenSpacing.s8),
        decoration: BoxDecoration(
          color:
              (failed
                      ? theme.colorScheme.errorContainer
                      : theme.colorScheme.primaryContainer)
                  .withValues(alpha: 0.35),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(
            color: failed ? theme.colorScheme.error : theme.colorScheme.primary,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '上次执行结果',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            for (final step in _lastRun)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      step.ok
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 16,
                      color: step.ok
                          ? (theme.brightness == Brightness.dark
                                ? UtenColors.successOnDark
                                : UtenColors.successText)
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Expanded(
                      child: Text(
                        '${step.label}：'
                        '${step.ok ? '成功 ${step.count} 行' : '未完成'}'
                        '${step.note == null ? '' : ' · ${step.note}'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '表内数量与勾选已按最新快照重算，已成功的行会自动退出，可直接重试未完成的部分。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _table(ThemeData theme) => UtenEditableGrid<_ChildCascadeRow>(
    controller: _grid,
    selectable: true,
    canSelectRow: (row) => row.selectable,
    // 树顶（被下达件本身）与只作层级上下文的合并行**整格不画方框**
    // ——2026-09-14 用户口径「父类应该默认没有多选框」。它们不是待办项，
    // 画一个点不动的灰方框只会被读成权限不足或数据有问题。
    showRowSelection: (row) => !row.isSeed && row.ownsInput,
    // 表头筛选藏起来的行仍在勾选集里（组件的筛选是纯视图级）：本页是
    // 「勾选即提交」的任务表，必须拦住「提交了屏幕上看不见的行」。
    onRowsHiddenByFilter: (hidden) {
      if (!mounted) return;
      setState(() => _hiddenByFilter = hidden);
    },
    showAddRow: false,
    showRowDelete: false,
    showSelectAllToggle: false,
    showColumnSettings: true,
    // 列显隐/顺序按账号持久化：原来每次进页面都回到默认，用户调好的列白调
    // （与销售/采购/委外编辑页同一套 provider 口径）。
    initialColumnOrder: _columnPrefs?.order,
    initialHiddenColumnKeys: _columnPrefs?.hidden,
    onColumnSettingsChanged: (order, hidden) => _host.ref
        .read(materialAnalysisCascadeGridColumnPrefsProvider.notifier)
        .updateFor(_columnPrefsBucket, order, hidden),
    emptyMessage: '下层没有需要下单的物料',
    columns: [
      // 身份列与主表、三个分桶详情完全一致（2026-09-14 全站统一口径）：
      // UtenTreeTableCell——缩进 + 层级连线 + 展开/收缩箭头 + 未展开子数徽章，
      // 与物料分析准备页同一组件同一读法，树顶是被下达件本身。
      // 宽度与准备页主表对齐（360）：深层行缩进最多吃掉 160px，原来的 260
      // 只剩几十像素显示货品名。
      EditableGridColumn<_ChildCascadeRow>(
        key: 'goods',
        label: '物料名称',
        width: 360,
        // 树列吃满整行高度：同一行里数量框/状态文案比树格高时，这一格若被
        // 竖向居中收缩，层级竖线就接不到上下行（与主表同一处理）。
        fillsCellHeight: true,
        filterValueOf: (row) => row.goodsName ?? row.goodsCode,
        cellBuilder: (context, row) {
          final info = _treeInfo[row];
          final spec = row.spec?.trim();
          return UtenTreeTableCell(
            key: ValueKey('cascade-tree-${row.id}'),
            toggleKey: ValueKey('cascade-toggle-${row.id}'),
            depth: row.depth,
            sequence: '',
            sequenceInline: true,
            showLeafMarker: false,
            // 连线要跨过表格单元格的纵向内边距才连得成一条（用户口径
            // 「表示层级的竖线不对」）。数值取自表格组件公开的常量，不抄魔数。
            // 视觉缩进上限用组件默认值（10，与本页展开上限同源），不再逐处传。
            guideBleed: UtenEditableGrid.cellVerticalPadding,
            title: row.displayName,
            subtitle: spec == null || spec.isEmpty ? null : spec,
            hasChildren: info?.hasChildren ?? false,
            childCount: info?.childCount,
            expanded: !_collapsedBranches.contains(row.id),
            onToggle: (info?.hasChildren ?? false)
                ? () => _toggleBranch(row)
                : null,
            ancestorContinuations: info?.ancestorContinuations ?? const [],
            isLastChild: info?.isLastChild ?? true,
          );
        },
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        filterValueOf: (row) => row.goodsCode,
        cellBuilder: (context, row) => Text(row.goodsCode ?? '—'),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'colorName',
        label: '颜色',
        width: 96,
        filterValueOf: (row) => row.colorName,
        cellBuilder: (context, row) => Text(row.colorName ?? '—'),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'unitName',
        label: '单位',
        width: 76,
        filterValueOf: (row) => row.unitName,
        cellBuilder: (context, row) => Text(row.unitName ?? '—'),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'route',
        label: '供料路线',
        width: 108,
        filterValueOf: (row) => row.route.label,
        cellBuilder: (context, row) => Text(
          row.confirmedRoute == null
              ? '${row.route.label}（待确认）'
              : row.route.label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: row.confirmedRoute == null
                ? theme.colorScheme.tertiary
                : theme.colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      // 所属仓库 (V587): 货品平时归哪个仓管, 计划员在本页就能当场补登,
      // 不必为了一个归属跑一趟货品主档 (取值/写回与主表、分桶详情同一份真相)。
      EditableGridColumn<_ChildCascadeRow>(
        key: 'owningWarehouse',
        label: '所属仓库',
        width: 150,
        headerInfo: '货品平时归哪个仓管的主档归属, 不是本次下达的落点仓, 也不是分析范围仓。点格子可直接改。',
        filterValueOf: (row) => _host.owningWarehouseFilterValue(
          row.goodsId,
          row.owningWarehouseNameSnapshot,
        ),
        cellBuilder: (context, row) => _owningWarehouseCell(theme, row),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'channel',
        label: '下达去向',
        width: 110,
        filterValueOf: (row) => switch (row.kind) {
          _CascadeKind.buy => '下达采购',
          _CascadeKind.subcontractLeaf => '下达委外',
          _CascadeKind.workshop => '下达车间',
        },
        cellBuilder: (context, row) => Text(
          // 树顶是「本次正在下达的那件」，它自己的去向就是用户点的那个按钮，
          // 如实写出来比一个 '—' 有用（筛选值也与显示一致，不再打架）。
          row.isSeed
              ? (widget.parentAction == null ? '已下达' : '本次下达')
              : switch (row.kind) {
                  _CascadeKind.buy => '下达采购',
                  _CascadeKind.subcontractLeaf => '下达委外',
                  _CascadeKind.workshop => '下达车间',
                },
          style: theme.textTheme.bodySmall,
        ),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'snapshotNeed',
        label: '需求数量',
        width: 110,
        numeric: true,
        headerInfo: '服务端快照里这行的本批需求量。填进「下单数量」的量高过它，多出来的那部分就是超产。',
        cellBuilder: (context, row) => Align(
          alignment: Alignment.centerRight,
          child: Text(
            // 树顶行也有真值：分桶页算给它的本次可下达上限（产品剩余需求 /
            // 委外剩余需求）。原来一律 '—'，用户既看不出自己填的数是不是超量，
            // 也无从判断「还缺数量」那一列为什么是空的。
            row.isSeed
                ? (row.seed?.maxQty == null
                      ? '—'
                      : _qtyWithUnit(row, row.seed!.maxQty!))
                : _qtyWithUnit(row, row.snapshotNeed),
          ),
        ),
      ),
      // 2026-09-15 用户口径：「本批要用」列删除。它是「本批数量 × BOM 单位耗用」
      // 的中间量，与「需求数量」只差一个超产量，摆在表上反而要用户自己做减法；
      // 真正要看的差额已经在状态列写成整句(含超产多需多少)。字段本身照常参与
      // 计算([_ChildCascadeRow.grossNeed] 是下层展开的驱动量)，只是不出列。
      EditableGridColumn<_ChildCascadeRow>(
        key: 'residual',
        label: '还缺数量',
        width: 108,
        numeric: true,
        headerInfo:
            '服务端口径：本批缺口 − 已在途（按整个提交单元汇总，与主表「建议下达」同源）。'
            '为 0 表示这行已经下过单了；这时如果本批配套要的量比「需求数量」大，'
            '多出来的那部分仍可在本页下单。',
        filterValueOf: (row) =>
            _host._qty(row.isSeed ? (row.seed?.maxQty ?? 0) : row.residual),
        cellBuilder: (context, row) {
          final value = row.isSeed ? row.seed?.maxQty : row.residual;
          if (value == null) {
            return const Align(
              alignment: Alignment.centerRight,
              child: Text('—'),
            );
          }
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              _host._qty(value),
              style: TextStyle(
                color: value > 0
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: value > 0 ? FontWeight.w700 : null,
              ),
            ),
          );
        },
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'qty',
        label: '下单数量',
        width: 128,
        numeric: true,
        required: true,
        // 2026-09-14：原文案写「可以改小分批」，与用户诉求 2（下达车间/委外
        // 要能填**超过**需求的量）正面矛盾，改成如实说明两个方向都行。
        headerInfo:
            '默认 = 还缺数量 + 超产多出来的部分。可以改小分批，也可以填得比需求大：'
            '车间超出部分记公共备货产出（有下达车间权限即可）；'
            '采购 / 无子层委外超出部分需要超量下达权限。',
        textOf: (row) => row.qty.text,
        listenableOf: (row) => row.qty,
        // 数量格下限监控的格内 ⓘ(44)计入量宽（2026-09-16）。
        chromeWidth: UtenEditableGridCellSpec.hintIconWidth,
        cellBuilder: (context, row) {
          // 树顶 = 父件本身：可改（改完驱动全部下层重算 + 作为父件段提交量）。
          if (row.isSeed) {
            final seed = row.seed;
            // 要先自制目标件的委外件不可改量：服务端 `createsChildOwnership`
            // 要求提交量**逐字等于**剩余需求，改了会 422 整批回滚。原来这里
            // 给了个可编辑的框，提交时又被 `entry.maxQty` 静默换掉，下层却按
            // 用户填的数展开——父子数量当场分叉（2026-09-15 收口）。
            if (seed != null && !seed.quantityEditable) {
              // 2026-09-15 用户反馈「下达委外进来这个数量改不了，下达车间进来
              // 却能改」：置灰本身是对的(服务端硬约束)，但原来只挂了一个
              // Tooltip——桌面要悬停、触屏要长按才看得到，等于没有说明。改成
              // 数字旁边常驻一枚可点的问号，把「为什么不能改 / 要多做的量去哪
              // 里填」当场说清(与「下单数量低于下限」那枚感叹号同款交互)。
              return Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _host._qty(seed.batchQty),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Tooltip(
                      key: ValueKey(
                        'material-analysis-child-cascade-locked-qty-${row.id}',
                      ),
                      message: _host._canGenerate
                          ? '这是**顶层**委外件：服务端不接受顶层行直接排产，只能先'
                                '「把它整件接管过来自己先做」，要求按剩余需求一次接满 '
                                '${_host._qty(seed.batchQty)}，所以这里数量不可改。\n'
                                '想多做 / 想分批，请在下面「前置自制任务下达车间」那一步填'
                                '——那一步才是真正安排生产的地方，也可以超量。\n'
                                '下层物料按这里的 ${_host._qty(seed.batchQty)} 配套算量。'
                          : '当前账号没有生成生产计划权限，这一步只能走「把目标件整件'
                                '接管过来自己先做」的通知通道：服务端要求按剩余需求一次'
                                '接满 ${_host._qty(seed.batchQty)}，所以数量不可改。\n'
                                '想多做 / 想分批，请让有生成生产计划权限的人从「下达委外」'
                                '进来：非顶层的委外件那时数量可改、超量会跟到委外台账，'
                                '前置自制任务也会同一步下达车间。\n'
                                '下层物料按这里的 ${_host._qty(seed.batchQty)} 配套算量。',
                      triggerMode: TooltipTriggerMode.tap,
                      child: Icon(
                        Icons.help_outline_rounded,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }
            return RequiredCellFrame(
              listenable: row.qty,
              isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
              child: TextField(
                key: ValueKey('material-analysis-child-cascade-qty-${row.id}'),
                controller: row.qty,
                // 父件段一旦提交成功就不能再改：快照已换版本，改了也只会让
                // 界面数字和已落库的计划对不上。
                enabled: !_parentSubmitted && !_running,
                textAlign: TextAlign.right,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: _qtyInputFormatters,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    isDense: true,
                    hintText: seed?.maxQty == null
                        ? '本批数量'
                        : '需求 ${_host._qty(seed!.maxQty)}',
                  ),
                ),
              ),
            );
          }
          if (!row.ownsInput) {
            // 合并行不重复收数，但要如实写出它自己这条路径贡献了多少，
            // 否则整行只剩一句「与上面合并」，用户不知道这支到底要用多少。
            return Align(
              alignment: Alignment.centerRight,
              child: Text(
                '并入上方 ${_host._qty(row.pathGrossNeed)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          if (row.blockedReason != null ||
              (row.suggested <= 0.0001 && !row.adjustIntoRequest)) {
            return const Align(
              alignment: Alignment.centerRight,
              child: Text('—'),
            );
          }
          // 下限实时监控（2026-09-14 用户口径「根据父层算出来需要 5 个，
          // 可以填大于 5，不能填小于 5；填了就要边框冒红 + 提示 icon，
          // 鼠标移上去显示提示弹窗」）：红框复用 RequiredCellFrame 的谓词
          // （空 **或** 低于下限都算不合格），格内右侧再挂一个带 Tooltip 的
          // 感叹号，说清差多少、为什么不能少。
          return RequiredCellFrame(
            listenable: row.qty,
            isEmpty: () => row.enteredQty <= 0 || row.belowMinimum,
            child: ListenableBuilder(
              listenable: row.qty,
              builder: (context, _) {
                final below = row.belowMinimum;
                return TextField(
                  key: ValueKey(
                    'material-analysis-child-cascade-qty-${row.id}',
                  ),
                  controller: row.qty,
                  textAlign: TextAlign.right,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: _qtyInputFormatters,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      isDense: true,
                      hintText: '不能少于 ${_host._qty(row.minRequiredQty)}',
                      suffixIcon: below
                          ? Tooltip(
                              key: ValueKey(
                                'material-analysis-child-cascade-shortfall-'
                                '${row.id}',
                              ),
                              message: row.shortfallHint(_host._qty),
                              triggerMode: TooltipTriggerMode.tap,
                              child: Icon(
                                Icons.error_outline_rounded,
                                size: 18,
                                color: theme.colorScheme.error,
                              ),
                            )
                          : null,
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'workshop',
        label: '生产车间',
        width: 150,
        required: true,
        filterValueOf: (row) =>
            row.needsWorkshop ? (row.departmentName ?? '未选择') : null,
        cellBuilder: (context, row) => _pickerCell(
          theme,
          row: row,
          cellKey: 'material-analysis-child-cascade-workshop-${row.id}',
          listenable: row.departmentId,
          valueText: () => row.departmentName ?? row.departmentId.value,
          autofilled: () => row.workshopAutofilled,
          onPick: () => _pickWorkshop(row),
        ),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'worker',
        label: '负责人',
        width: 150,
        required: true,
        filterValueOf: (row) =>
            row.needsWorkshop ? (row.workerName ?? '未选择') : null,
        cellBuilder: (context, row) => _pickerCell(
          theme,
          row: row,
          cellKey: 'material-analysis-child-cascade-worker-${row.id}',
          listenable: row.workerId,
          valueText: () => row.workerName ?? row.workerId.value,
          autofilled: () => row.workerAutofilled,
          onPick: () => _pickWorker(row),
        ),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'status',
        label: '状态',
        width: 260,
        // 筛选值只给「阶段」这一段，不带数量：原来整句长文案当筛选值，
        // 每行自成一桶，表头筛选等于不可用。
        filterValueOf: _statusBucket,
        // 单行省略号（2026-09-16 全站口径）+ 随整段文案自动加宽（封顶后
        // 悬停 Tooltip 看全文——状态列是本页最关键的解释位，为什么被砍量、
        // 并入哪张申请、为什么下不了）。
        textOf: _statusLabel,
        cellBuilder: (context, row) => Tooltip(
          message: _statusLabel(row),
          child: Text(
            _statusLabel(row),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: row.blockedReason != null
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: row.blockedReason != null ? FontWeight.w700 : null,
            ),
          ),
        ),
      ),
    ],
    // 合计：纯内存表，本地一算就有。计划员核对「这一批一共要下多少」时
    // 不必再自己按计算器。
    footer: ListenableBuilder(
      listenable: _grid,
      builder: (context, _) {
        final selected = _selectedRows
            .where((row) => row.selectable)
            .toList(growable: false);
        final byKind = <_CascadeKind, double>{};
        for (final row in selected) {
          byKind[row.kind] = (byKind[row.kind] ?? 0) + row.enteredQty;
        }
        return Wrap(
          alignment: WrapAlignment.end,
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s4,
          children: [
            Text('已勾选 ${selected.length} 行'),
            for (final kind in _CascadeKind.values)
              if ((byKind[kind] ?? 0) > 0)
                Text('${kind.label}合计 ${_host._qty(byKind[kind])}'),
          ],
        );
      },
    ),
  );

  /// 状态列的筛选桶：只保留可归类的阶段词，数量不进筛选值。
  String _statusBucket(_ChildCascadeRow row) {
    if (row.isSeed) return '本次下达的件';
    if (!row.ownsInput) return '同物料的另一条路径';
    if (row.blockedReason != null) return '不可下达';
    if (row.adjustIntoRequest) return '并入已有申请';
    if (row.appendToOrdered) return '已下单，需到下游追加';
    if (row.adjustNeedsPurchasePermission) return '可并入申请，缺采购权限';
    if (row.workshopFullyConverted) return '需求已转计划，需单独下计划';
    if (row.residual <= 0.0001 && row.overspill <= 0.0001) return '已下达 / 无需再下单';
    return row.kind.pendingStage;
  }

  String _qtyWithUnit(_ChildCascadeRow row, double value) {
    // 树顶那行的数量是**来源单位**的本批数量（需求 10 箱就是 10），而它挂的
    // 根供给行记的是基本单位（200 件）——两者不能拼在一起，否则会出现
    //「刚下达 10 件」这种错标。带单位的完整说明在顶部提示卡里。
    if (row.isSeed) return _host._qty(value);
    final unit = row.unitName?.trim();
    return unit == null || unit.isEmpty
        ? _host._qty(value)
        : '${_host._qty(value)} $unit';
  }

  String _statusLabel(_ChildCascadeRow row) {
    if (row.isSeed) {
      return widget.parentAction == null
          ? '刚下达 ${_qtyWithUnit(row, row.grossNeed)}，下层按这个数量算'
          : '本次将下达 ${_qtyWithUnit(row, row.grossNeed)}，下层按这个数量算';
    }
    if (!row.ownsInput) {
      return '同一物料的另一条路径：本支要用 ${_host._qty(row.pathGrossNeed)}，'
          '已并入上面那一行统一下单（本行只作层级上下文）';
    }
    final blocked = row.blockedReason;
    if (blocked != null) return blocked;
    final parts = <String>[];
    if (row.residual <= 0.0001) {
      if (row.overspill > 0.0001) {
        final link = row.supplyLink;
        if (row.adjustIntoRequest) {
          parts.add(
            '已下采购申请 ${link!.documentNo}（未分解）· 并入 '
            '${_host._qty(link.itemQty)} → ${_host._qty(link.itemQty + row.enteredQty)}',
          );
        } else if (row.adjustNeedsPurchasePermission) {
          parts.add(
            '已下采购申请 ${link!.documentNo}（未分解）· 多做的 '
            '${_host._qty(row.overspill)} 可以并入这张申请，但需要采购申请查看 + '
            '订货分解权限，请联系采购办理，本页不下单',
          );
        } else if (row.appendToOrdered) {
          // 本页不下这一单：分析侧的提交单元已不可执行，勾了也只会在采购段
          // 被整段挡住。如实指到能办的地方去。
          parts.add(
            '已下单 ${link!.documentNo} 且已分解出下游单据 · '
            '多做的 ${_host._qty(row.overspill)} 请到${row.kind == _CascadeKind.buy ? '采购' : '委外'}'
            '模块对该单追加，本页不下单',
          );
        } else if (row.workshopFullyConverted) {
          parts.add(
            '本批需求已全部转成生产计划 · 多做的 ${_host._qty(row.overspill)} '
            '请回「下达车间」桶对这件单独下一张计划，本页不下单',
          );
        } else {
          parts.add(
            row.overCapped
                ? '已下达；多做的 ${_host._qty(row.overspill)} 需超量下达权限'
                : '已覆盖；多做的 ${_host._qty(row.overspill)} 可在此下单',
          );
        }
      } else {
        parts.add('已下达 / 无需再下单');
      }
    } else {
      parts.add(row.kind.pendingStage);
      if (row.overspill > 0.0001) {
        parts.add(
          row.overCapped
              ? '超产多需 ${_host._qty(row.overspill)}，无超量下达权限未计入'
              : '含超产多需 ${_host._qty(row.overspill)}',
        );
      }
    }
    // 缺单位耗用的历史行：数量没按本批放大过，必须明说，否则用户以为
    // 这行也跟着树顶数量算好了。
    if (!row.scaled) parts.add('缺 BOM 单位耗用，数量未按本批数量放大，请自行核对');
    if (row.mergedPathCount > 1) parts.add('合并 ${row.mergedPathCount} 条路径');
    return parts.join(' · ');
  }
}
