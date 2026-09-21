part of 'production_material_analysis_page.dart';

/// 父件 + 下层一起下单**整页**：与物料分析准备页同款的树表格（展开 / 收缩 +
/// 层级连线，UtenTreeTableCell）+ 一个「一键下单」。[parentAction] 非空 =
/// 前置模式（父件还没提交，一键下单先提交父件再办下层）；null = 重试模式
/// （父件已提交过）。
///
/// 2026-09-21（ADR-099）：下层数字全部来自服务端——[previewView] 是服务端
/// 「下达预览」返回的「下达之后」快照；树顶数量改了就再要一份预览，浏览器
/// 不再自己按单耗相乘。
class _ChildCascadePage extends StatefulWidget {
  const _ChildCascadePage({
    required this.host,
    required this.seeds,
    required this.initialRows,
    this.previewView,
    this.parentAction,
  });

  final _MaterialAnalysisChildCascadeState host;
  final List<_ChildCascadeSeed> seeds;
  final List<_ChildCascadeRow> initialRows;

  /// 初始行集来自哪份快照（null = 当前真实快照）。
  final ProductionMaterialAnalysisView? previewView;
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

  List<_ChildCascadeRow> get _selectedRows =>
      _allRows.where(_grid.isSelected).toList(growable: false);
  Map<_ChildCascadeRow, UtenTreeRowProjection> _treeInfo = const {};
  final Set<String> _collapsedBranches = {};

  /// 折叠时记下被撤勾的行，展开时原样放回。
  final Set<String> _collapsedSelection = {};

  /// 用户**手工**取消勾选的提交单元：重算与重建都不得替他重新勾上。
  final Set<String> _userDeselected = {};

  /// 正在程序性写入数量框（预填 / 重建），此时的控制器变更不算「用户改过」。
  bool _programmaticQty = false;

  /// 正在程序性改勾选（预勾、重建同步、折叠恢复），不算「用户手工取消」。
  bool _programmaticSelection = false;

  /// 当前被表头筛选藏起来的行。
  Set<_ChildCascadeRow> _hiddenByFilter = const {};

  /// 数量框只收数字与一个小数点。
  static final List<TextInputFormatter> _qtyInputFormatters = [
    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
  ];

  /// 树顶数量改动后向服务端再要一份预览：去抖，最后一次输入停下 600ms 才发。
  Timer? _previewDebounce;
  int _previewGeneration = 0;
  bool _previewing = false;

  bool _running = false;

  /// 顶部说明默认收起。
  bool _hintExpanded = false;

  /// 默认车间/负责人与预览都是进页面后异步补上的。加载期间挡住提交。
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

  /// 前置模式下父件是否已提交成功：失败重试时不再重发父件段。
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

  static const String _columnPrefsBucket = 'cascade';

  EditableGridColumnsPrefs? get _columnPrefs => _host.ref.read(
    materialAnalysisCascadeGridColumnPrefsProvider,
  )[_columnPrefsBucket];

  @override
  void initState() {
    super.initState();
    _grid.addListener(_trackManualDeselection);
    _initialSeedQty = {for (final seed in widget.seeds) seed: seed.batchQty};
    _installRows(widget.initialRows);
    unawaited(_withLoading(_loadWorkshopDefaults));
  }

  Map<_ChildCascadeSeed, double> _initialSeedQty = const {};

  List<_ChildCascadeSeed> get _topSeeds => widget.seeds;

  /// 这一行现在能不能指派车间 / 负责人。树顶父件段一旦提交成功就不能再改——
  /// 车间/负责人算进 issue-plans 的幂等键。
  bool _canAssignWorkshop(_ChildCascadeRow row) =>
      row.needsWorkshop &&
      row.blockedReason == null &&
      !_running &&
      !(row.isSeed && _parentSubmitted);

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
    _previewDebounce?.cancel();
    _grid.removeListener(_trackManualDeselection);
    final visible = _grid.rows.toSet();
    for (final row in _allRows) {
      if (!visible.contains(row)) row.dispose();
    }
    _grid.dispose();
    _pageScroll.dispose();
    super.dispose();
  }

  /// [selectedKeys] 非空 = 只勾选这些提交单元（重建：继承用户原来勾的行，
  /// 新出现的行不自动勾）；空 = 全部可选行勾上（页面首次打开）。
  void _installRows(List<_ChildCascadeRow> rows, {Set<String>? selectedKeys}) =>
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
    for (final row in _allRows) {
      // 树顶 = 父件本身：数量预填种子的本批数量，改动回写种子并重新预览；
      // 车间 / 负责人同样从种子带出来。
      if (row.isSeed && row.seed != null) {
        final seed = row.seed!;
        _setQtyText(row, _bucketQtyText(seed.batchQty));
        row.qty.addListener(() => _onSeedQtyChanged(row));
        row.departmentId.value = seed.departmentId;
        row.departmentName = seed.departmentName;
        row.workerId.value = seed.workerId;
        row.workerName = seed.workerName;
        row.workshopAutofilled = seed.workshopAutofilled;
        row.workerAutofilled = seed.workerAutofilled;
        continue;
      }
      if (!row.ownsInput) continue;
      // 「用户手工改过」由**控制器监听**标记，不靠 TextField.onChanged。
      row.qty.addListener(() {
        if (!_programmaticQty) row.qtyTouched = true;
      });
      // 默认只勾还有缺口的行；已覆盖的行（填了就是追加，属公共备货）由用户
      // 自己勾。重建行集时沿用用户此前的勾选。
      final preselect = selectedKeys == null
          ? row.suggested > 0.0001
          : selectedKeys.contains(row.submitKey);
      if (row.selectable &&
          preselect &&
          !_userDeselected.contains(row.submitKey)) {
        _programmaticSelect(() => _grid.setSelected([row], true));
      }
    }
    final liveIds = {for (final row in _allRows) row.id};
    _collapsedBranches.removeWhere((id) => !liveIds.contains(id));
    _collapsedSelection.removeWhere((id) => !liveIds.contains(id));
    if (mounted) setState(() {});
  }

  /// 父件数量改动：回写种子 batchQty（父件段提交按它），并重新向服务端要一份
  /// 「下达之后」的预览，下层按新数量重算（手工改过的下层数量保留）。
  ///
  /// 清空 / 填 0 / 填非法字符时**必须**把种子归零，不能保留旧值。
  void _onSeedQtyChanged(_ChildCascadeRow row) {
    final seed = row.seed;
    if (seed == null) return;
    final value = row.enteredQty;
    seed.batchQty = value > 0 && value.isFinite ? value : 0;
    if (mounted) setState(() {});
    _schedulePreviewRefresh();
  }

  /// 要不要（还能不能）向服务端要预览：父件还没提交、有车间通道的种子、
  /// 数量与车间都齐了。
  bool get _needsPreview =>
      widget.parentAction != null &&
      !_parentSubmitted &&
      widget.seeds.any(
        (seed) =>
            seed.needsWorkshop &&
            seed.batchQty > 0 &&
            seed.batchQty.isFinite &&
            seed.departmentId?.isNotEmpty == true,
      );

  void _schedulePreviewRefresh() {
    if (!_needsPreview) return;
    _previewDebounce?.cancel();
    _previewDebounce = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_refreshPreview()),
    );
  }

  Future<void> _refreshPreview() async {
    if (!mounted || !_needsPreview || _running) return;
    final generation = ++_previewGeneration;
    _previewing = true;
    await _withLoading(() async {
      try {
        final view = await _host._previewCascadeView(widget.seeds);
        if (!mounted || generation != _previewGeneration || view == null) {
          return;
        }
        _rebuildRowsFrom(
          view,
          selectedKeys: {for (final row in _selectedRows) row.submitKey},
        );
      } catch (error) {
        if (!mounted || generation != _previewGeneration) return;
        context.appError(
          productionErrorMessage(error, fallback: '下层需求重算失败，请稍后重试'),
        );
      } finally {
        if (generation == _previewGeneration) _previewing = false;
      }
    });
  }

  /// 按 [view] 重建行集，并继承用户已填的数量 / 车间 / 负责人 / 勾选。
  /// 返回重建后仍可下达且原本勾选的行。
  List<_ChildCascadeRow> _rebuildRowsFrom(
    ProductionMaterialAnalysisView view, {
    required Set<String> selectedKeys,
  }) {
    final carried =
        <
          String,
          ({
            String? qtyText,
            String? departmentId,
            String? departmentName,
            String? workerId,
            String? workerName,
            bool workshopAutofilled,
            bool workerAutofilled,
          })
        >{};
    for (final row in _allRows) {
      carried[row.submitKey] = (
        qtyText: row.qtyTouched ? row.qty.text : null,
        departmentId: row.departmentId.value,
        departmentName: row.departmentName,
        workerId: row.workerId.value,
        workerName: row.workerName,
        workshopAutofilled: row.workshopAutofilled,
        workerAutofilled: row.workerAutofilled,
      );
    }
    final fresh = _host._buildChildCascadeRows(widget.seeds, view);
    for (final row in fresh) {
      if (row.isSeed) continue;
      final old = carried[row.submitKey];
      if (old == null) continue;
      // 「用户手工改过」原样继承，包括改成 0 / 清空——那是「这行本次不下」。
      if (old.qtyText != null) {
        row.qty.text = old.qtyText!.trim();
        row.qtyTouched = true;
      }
      if (old.departmentId != null) {
        row.departmentId.value = old.departmentId;
        row.departmentName = old.departmentName;
        row.workerId.value = old.workerId;
        row.workerName = old.workerName;
        row.workshopAutofilled = old.workshopAutofilled;
        row.workerAutofilled = old.workerAutofilled;
      }
    }
    _installRows(fresh, selectedKeys: selectedKeys);
    unawaited(_withLoading(_loadWorkshopDefaults));
    return [
      for (final row in fresh)
        if (selectedKeys.contains(row.submitKey) && row.selectable) row,
    ];
  }

  /// 父件提交成功后按最新**真实**快照重建：预览快照此时作废。
  List<_ChildCascadeRow> _rebuildAfterParent(Set<String> selectedKeys) {
    final analysis = _host._analysis;
    if (analysis == null) return const [];
    return _rebuildRowsFrom(analysis, selectedKeys: selectedKeys);
  }

  void _computeTreeInfo() {
    _treeInfo = utenTreeProjectionByRow<_ChildCascadeRow>(
      _allRows,
      depthOf: (row) => row.depth,
      treeKeyOf: (row) => row.treeIndex,
    );
  }

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

  /// 展开 / 收起一个分支：只换可见子集，行对象与已填内容不动。折叠时把隐藏
  /// 行的勾选撤掉（「看到的勾选 = 提交的内容」）并记住，展开时原样放回。
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

  /// 程序性写入数量框：不能被当成「用户手工改过」。
  void _setQtyText(_ChildCascadeRow row, String text) {
    if (row.qty.text == text) return;
    _programmaticQty = true;
    row.qty.text = text;
    _programmaticQty = false;
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
    var seedFilled = false;
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
      if (row.isSeed) seedFilled = true;
      _syncSeedAssignment(row);
    }
    setState(() {});
    // 树顶刚补上车间：现在才有条件向服务端要预览（分桶页没有车间列的入口）。
    if (seedFilled && widget.previewView == null) _schedulePreviewRefresh();
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
    final hadWorkshop = row.departmentId.value?.isNotEmpty == true;
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
    if (row.isSeed && !hadWorkshop) _schedulePreviewRefresh();
  }

  /// 树顶行的车间/负责人回写种子：父件段读种子，而快照一换行对象就作废。
  void _syncSeedAssignment(_ChildCascadeRow row) {
    final seed = row.seed;
    if (!row.isSeed || seed == null) return;
    seed.departmentId = row.departmentId.value;
    seed.departmentName = row.departmentName;
    seed.workerId = row.workerId.value;
    seed.workerName = row.workerName;
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
      if (qty == null || !qty.isFinite || qty <= 0) {
        badQty.add('「$name」');
        continue;
      }
      if (!row.selectable) {
        stale.add('「$name」${row.blockedReason ?? '已不可下达，请刷新后重试'}');
        continue;
      }
      // 采购/直接外发委外超过「还需安排」的部分是主动公共备货：没有超量下达
      // 权限时服务端会拒，这里先点名，不静默改小。
      if (row.kind != _CascadeKind.workshop &&
          !_host._canOverSupply &&
          qty > row.residual + 0.0001) {
        overQty.add(
          '「$name」本次 ${_host._qty(qty)} / 还需安排 ${_host._qty(row.residual)}',
        );
        continue;
      }
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
        _issueLine(belowMin, '低于服务端按父件本批数量算出的还需安排量，父件会缺料——可以多下，不能少下'),
      if (overQty.isNotEmpty)
        _issueLine(overQty, '超过还需安排量的部分属主动追加（公共备货），需要超量下达权限，请改小或找有权限的人'),
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
      // 「确认超量下达」；没问过的（委外桶改走 issue-plans 的行）必须补问。
      final raisedHere =
          (seed.batchQty - (_initialSeedQty[seed] ?? seed.batchQty)).abs() >
          0.0001;
      // 上限为 0（需求已全部转入计划，本批全是追加的公共备货产出）同样要确认。
      if ((raisedHere || !seed.overQtyConfirmed) &&
          cap != null &&
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
      title: '确认超量下达车间',
      content: Text(
        '以下 ${over.length} 行填写的本批数量超出当前需求：\n'
        '${over.join('\n')}\n\n'
        '超出部分按公共备货产出记账：完工入库后进公共库存，其他计划可以直接用，'
        '不占本次需求的精确账；同一张计划分别记录需求份与公共备货份，'
        '订单侧数量不受影响。\n'
        '本页下面的下层物料已经由服务端按这个数量算好了，一起下单即可配套。',
      ),
      confirmLabel: '确认超量下达',
    );
    return ok == true;
  }

  String _names(Iterable<String> labels) {
    const maxShown = 8;
    final all = labels.toList(growable: false);
    final shown = all.take(maxShown).join('、');
    return '$shown${all.length > maxShown ? ' 等 ${all.length} 行' : ''}';
  }

  Future<void> _submit() async {
    if (_running) return;
    if (widget.parentAction != null && !_parentSubmitted) {
      final parentOk = await _validateAndConfirmSeeds();
      if (!parentOk || !mounted) return;
    }
    final selected = _selectedRows
        .where((row) => row.selectable)
        .toList(growable: false);
    if (selected.isEmpty) {
      if (widget.parentAction == null || _parentSubmitted) {
        context.appInfo('请先勾选要下单的下层物料');
        return;
      }
      // 下层都已下过单（没有一行还有缺口）：不用再问，直接只下达父件。
      final anyPending = _allRows.any(
        (row) => !row.isSeed && row.ownsInput && row.residual > 0.0001,
      );
      if (!anyPending) {
        await _runSegments(
          const [],
          parentOnly: true,
          parentOnlyNote: '下层都已下过单，本次只下达父件（要追加时在本页勾选并填追加量）',
        );
        return;
      }
      final onlyParent = await UtenDialog.show(
        context,
        title: '只下达父件？',
        content: const Text(
          '当前一行下层都没有勾选。继续将**只提交父件**，下层物料保持原样——'
          '它们的还需安排量会留在各自的桶里，可稍后再办；否则车间领料时才会发现缺料。',
        ),
        confirmLabel: '只下达父件',
      );
      if (onlyParent != true || !mounted) return;
      await _runSegments(const [], parentOnly: true);
      return;
    }
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
    final claiming = selected
        .where((row) => row.claimableQty > 0.0001)
        .toList(growable: false);
    final extra = selected
        .where((row) => row.extraQty > 0.0001)
        .toList(growable: false);
    final ok = await UtenDialog.show(
      context,
      title: '确认一键下单下层物料',
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
              if (claiming.isNotEmpty)
                '其中 ${claiming.length} 行有可认领的同主仓公共在途，下达时服务端先自动认领、只为余下部分新下单：'
                    '${_names(claiming.map((row) => '${_rowName(row)} ${_host._qty(row.claimableQty)}'))}',
              if (extra.isNotEmpty)
                '其中 ${extra.length} 行填的数量超出还需安排量，超出部分属主动追加（公共备货）：'
                    '${_names(extra.map((row) => '${_rowName(row)} 多 ${_host._qty(row.extraQty)}'))}',
              '采购 / 委外：原申请还没被采购、委外部门动过（明细未订货）的，追加量直接改到那张申请上；已订货的另立新申请。',
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
    String? parentOnlyNote,
  }) async {
    _previewDebounce?.cancel();
    _previewGeneration++;
    setState(() {
      _running = true;
      _lastRun = const [];
    });
    List<_CascadeStepResult> results = const [];
    final selectedKeys = {for (final row in selected) row.submitKey};
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
                ? (parentOnlyNote ?? '下层未办理：本次一行都没有勾选，下层的还需安排量留在各自的桶里')
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
    // 失败留在本页：按最新真实快照重算（已成功的行会变成「已下达」），可直接重试。
    setState(() {
      _lastRun = results;
      _rebuildAfterParent(selectedKeys);
    });
  }

  // ===== 退出 =====

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
        '打开了本页（服务端预览不落库），真正的提交在「一键下单」里。\n\n'
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
                    child: SingleChildScrollView(
                      controller: _pageScroll,
                      padding: const EdgeInsets.only(
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
                        child: Text(_exitNeedsConfirm ? '放弃本次下达' : '稍后再办'),
                      ),
                      UtenButton(
                        key: const Key(
                          'material-analysis-child-cascade-submit',
                        ),
                        type: UtenButtonType.danger,
                        size: UtenButtonSize.large,
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
                              ? (_previewing ? '正在按本批数量重算下层…' : '正在载入默认车间…')
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
            AnimatedBuilder(
              animation: Listenable.merge([
                _host.bucketActionBusyMessage,
                _host.planSubmissionProgress,
              ]),
              builder: (context, _) {
                if (!_running) return const SizedBox.shrink();
                final segment = _host.bucketActionBusyMessage.value;
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

  Widget _hintCard(ThemeData theme) {
    final seedText = _topSeeds
        .map(
          (seed) =>
              '${seed.label} ${_host._qty(seed.batchQty)}'
              '${seed.unitName?.trim().isNotEmpty == true ? ' ${seed.unitName!.trim()}' : ''}',
        )
        .join('、');
    final submitted = widget.parentAction == null || _parentSubmitted;
    final headline = submitted
        ? '已下达：$seedText。下面是它按 BOM 展开的下层，数量由服务端按本批数量算好，可以改。'
        : '本次将下达：$seedText，以及下面按 BOM 展开的下层（数量由服务端按本批数量算好）。点「一键下单」才会真正提交。';
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
                    '· 树最上面一行就是本次下达的件。改它的数量，服务端会重新算一遍「下达之后」的下层需求，没手工改过的下层跟着变。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '· 一键下单按各行「下达去向」分流：采购 → 下达采购；直接外发的委外 → 下达委外；自制与需先自制的委外 → 下达车间出计划。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '· 采购 / 委外下达时，服务端先自动认领同主仓的公共在途，再把追加量改到还没订货的原申请上，其余才新下单。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '· 数量可以填得比还需安排量大，不能少：车间超出部分记公共备货产出；采购 / 直接外发委外超出部分需要超量下达权限。',
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
    // 树顶与只作层级上下文的合并行整格不画方框。
    showRowSelection: (row) => !row.isSeed && row.ownsInput,
    onRowsHiddenByFilter: (hidden) {
      if (!mounted) return;
      setState(() => _hiddenByFilter = hidden);
    },
    showAddRow: false,
    showRowDelete: false,
    showSelectAllToggle: false,
    showColumnSettings: true,
    initialColumnOrder: _columnPrefs?.order,
    initialHiddenColumnKeys: _columnPrefs?.hidden,
    onColumnSettingsChanged: (order, hidden) => _host.ref
        .read(materialAnalysisCascadeGridColumnPrefsProvider.notifier)
        .updateFor(_columnPrefsBucket, order, hidden),
    emptyMessage: '下层没有需要下单的物料',
    columns: [
      EditableGridColumn<_ChildCascadeRow>(
        key: 'goods',
        label: '物料名称',
        width: 360,
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
        headerInfo: '服务端按本批数量算出的这行本批需求（父件超量下达时已按计划产出量放大）。树顶显示本次可下达上限。',
        cellBuilder: (context, row) => Align(
          alignment: Alignment.centerRight,
          child: Text(
            row.isSeed
                ? (row.seed?.maxQty == null
                      ? '—'
                      : _qtyWithUnit(row, row.seed!.maxQty!))
                : _qtyWithUnit(row, row.requiredQty),
          ),
        ),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'residual',
        label: '还需安排',
        width: 108,
        numeric: true,
        headerInfo:
            '服务端口径：本批需求扣掉现货、在途与已下达后还要安排的量（与主表「下单数量」同源）。'
            '为 0 表示这行已经下过单了。',
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
        headerInfo:
            '默认 = 服务端算出的还需安排量（采购行再按起订量 / 整包装上抬）。可以填得比它大：'
            '车间超出部分记公共备货产出（有下达车间权限即可）；'
            '采购 / 直接外发委外超出部分需要超量下达权限。不能填得比还需安排量小。'
            '已下过单的行（还需安排 0）也能填：填的就是追加量，属公共备货——'
            '原申请还没被采购 / 委外处理的直接改到那张申请上，已处理的另立新单。',
        textOf: (row) => row.qty.text,
        listenableOf: (row) => row.qty,
        chromeWidth: UtenEditableGridCellSpec.hintIconWidth,
        cellBuilder: (context, row) {
          if (row.isSeed) {
            final seed = row.seed;
            return RequiredCellFrame(
              listenable: row.qty,
              isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
              child: TextField(
                key: ValueKey('material-analysis-child-cascade-qty-${row.id}'),
                controller: row.qty,
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
            return Align(
              alignment: Alignment.centerRight,
              child: Text(
                '并入上方 ${_host._qty(row.requiredQty)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          if (row.blockedReason != null || !row.selectable) {
            return const Align(
              alignment: Alignment.centerRight,
              child: Text('—'),
            );
          }
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
                      hintText: row.minRequiredQty > 0.0001
                          ? '不能少于 ${_host._qty(row.minRequiredQty)}'
                          : '追加量（属公共备货）',
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
        filterValueOf: _statusBucket,
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

  /// 车间 / 负责人选择格。不可点时**不装成可点**。
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

  /// 所属仓库格 (V587)：与本行下不下得了单无关，合并行、被阻断的行照样能改。
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
    if (changed && mounted) setState(() {});
  }

  /// 状态列的筛选桶：只保留可归类的阶段词，数量不进筛选值。
  String _statusBucket(_ChildCascadeRow row) {
    if (row.isSeed) return '本次下达的件';
    if (!row.ownsInput) return '同物料的另一条路径';
    if (row.blockedReason != null) return '不可下达';
    if (row.residual <= 0.0001) {
      return row.allowsExtra ? '已覆盖 · 可追加' : '已下达 / 无需再下单';
    }
    return row.kind.pendingStage;
  }

  String _qtyWithUnit(_ChildCascadeRow row, double value) {
    if (row.isSeed) return _host._qty(value);
    final unit = row.unitName?.trim();
    return unit == null || unit.isEmpty
        ? _host._qty(value)
        : '${_host._qty(value)} $unit';
  }

  String _statusLabel(_ChildCascadeRow row) {
    if (row.isSeed) {
      return widget.parentAction == null
          ? '刚下达 ${_qtyWithUnit(row, row.seed?.batchQty ?? 0)}，下层按这个数量算'
          : '本次将下达 ${_qtyWithUnit(row, row.seed?.batchQty ?? 0)}，下层按这个数量算';
    }
    if (!row.ownsInput) {
      return '同一物料的另一条路径：本支要用 ${_host._qty(row.requiredQty)}，'
          '已并入上面那一行统一下单（本行只作层级上下文）';
    }
    final blocked = row.blockedReason;
    if (blocked != null) return blocked;
    final parts = <String>[];
    final documentNo = row.orderedDocumentNo;
    final docLabel = switch (row.kind) {
      _CascadeKind.buy => '采购申请',
      _CascadeKind.subcontractLeaf => '委外申请',
      _CascadeKind.workshop => '生产计划',
    };
    if (row.growableLineQty != null) {
      parts.add(
        '已下$docLabel${documentNo == null ? '' : ' $documentNo'} '
        '${_host._qty(row.growableLineQty)}（采购 / 委外还没处理：追加会直接改到该申请）',
      );
    } else if (row.orderedQty > 0.0001) {
      parts.add(
        '已下$docLabel${documentNo == null ? '' : ' $documentNo'} '
        '${_host._qty(row.orderedQty)}'
        '${row.kind == _CascadeKind.workshop ? '（追加 = 再下一批公共备货产出）' : '（已在处理：追加另立新申请，属公共备货）'}',
      );
    }
    if (row.residual <= 0.0001) {
      parts.add(row.allowsExtra ? '本批需求已覆盖，填的数量即额外追加（属公共备货）' : '已下达 / 无需再下单');
    } else {
      parts.add(row.kind.pendingStage);
      if (row.claimableQty > 0.0001) {
        parts.add('其中 ${_host._qty(row.claimableQty)} 可自动认领公共在途');
      }
    }
    if (row.mergedPathCount > 1) parts.add('合并 ${row.mergedPathCount} 条路径');
    return parts.join(' · ');
  }
}
