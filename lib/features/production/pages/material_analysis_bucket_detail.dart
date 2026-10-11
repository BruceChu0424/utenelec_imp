part of 'production_material_analysis_page.dart';

/// Preparation is organized by route; issue state remains inside each list.
/// Commands continue to use the host's permission, version and idempotency flow.
enum _AnalysisBucket { buy, subcontract, workshop }

enum _PreparationTaskFilter { pending, inProgress, blocked }

extension _AnalysisBucketX on _AnalysisBucket {
  String countLabel(AppLocalizations l10n) => switch (this) {
    _AnalysisBucket.buy => l10n.materialTaskBuy,
    _AnalysisBucket.subcontract => l10n.materialTaskSubcontract,
    _AnalysisBucket.workshop => l10n.materialTaskWorkshop,
  };

  String semanticHint(AppLocalizations l10n) => switch (this) {
    _AnalysisBucket.buy => l10n.materialTaskBuyHint,
    _AnalysisBucket.subcontract => l10n.materialTaskSubcontractHint,
    _AnalysisBucket.workshop => l10n.materialTaskWorkshopHint,
  };

  MaterialSupplyRoute? get supplyRoute => switch (this) {
    _AnalysisBucket.buy => MaterialSupplyRoute.buy,
    _AnalysisBucket.subcontract => MaterialSupplyRoute.subcontract,
    _AnalysisBucket.workshop => null,
  };
}

/// 创建生产计划的候选行输入（2026-09-05：候选与产品同表单，建任务后按
/// 这些输入直接生成新子件的计划）。
class _BucketCandidatePlanInput {
  const _BucketCandidatePlanInput({
    required this.materialLineId,
    required this.qty,
    this.qtyExact,
    required this.departmentId,
    required this.workshopName,
    required this.workerId,
    this.publicSurplusOnly = false,
    this.allowedOverproductionRate,
  });

  final String materialLineId;
  final double qty;
  final String? qtyExact;
  final double? allowedOverproductionRate;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;

  /// ADR-099：该候选的自制锚点已无剩余需求，本次全是追加的公共备货产出。
  final bool publicSurplusOnly;
}

/// 生成计划的已有产品行输入（可安排详情页收集，宿主页校验后单次下达）。
class _BucketPlanDraft {
  const _BucketPlanDraft({
    required this.analysisLineId,
    required this.qty,
    this.qtyExact,
    required this.departmentId,
    required this.workshopName,
    required this.workerId,
    this.publicSurplusOnly = false,
    this.allowedOverproductionRate,
  });

  final String analysisLineId;
  final double qty;
  final String? qtyExact;
  final double? allowedOverproductionRate;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;

  /// ADR-099：锚点剩余需求已为 0，本行是明确的「再追加一批公共备货产出」。
  final bool publicSurplusOnly;
}

/// 详情页表格的一行：产品 / 自制候选 / 物料操作组 三种形态共用一张表。
/// [mergedGroups]/[mergedAction] 是「同料合并批次」形态（2026-10-09 用户口径
/// 「合并下单的显示要合并，跟下达车间一样」）：同一货品经汇总通道合并下单后，
/// 相关操作组归并成一行——单据号/批次总量取自批次 action，进度/需求量跨成员
/// 聚合；追加下单仍逐成员办理。产品行/候选行不参与合并。
class _BucketRow {
  _BucketRow.product(ProductionMaterialAnalysisProduct value)
    : id = value.analysisLineId,
      product = value,
      candidate = null,
      group = null,
      mergedGroups = null,
      mergedAction = null;
  _BucketRow.candidate(_PendingMakeCandidate value)
    : id = value.material.materialLineId,
      product = null,
      candidate = value,
      group = null,
      mergedGroups = null,
      mergedAction = null;
  _BucketRow.group(_MaterialGroup value)
    : id = value.key,
      product = null,
      candidate = null,
      group = value,
      mergedGroups = null,
      mergedAction = null;
  _BucketRow.merged(
    List<_MaterialGroup> members,
    MaterialAnalysisSupplyAction action,
  ) : id = 'MERGED|${action.actionId}',
      product = null,
      candidate = null,
      group = members.first,
      mergedGroups = List.unmodifiable(members),
      mergedAction = action;
  final String id;
  final ProductionMaterialAnalysisProduct? product;
  final _PendingMakeCandidate? candidate;
  final _MaterialGroup? group;
  final List<_MaterialGroup>? mergedGroups;
  final MaterialAnalysisSupplyAction? mergedAction;
  bool get isMergedBatch => mergedGroups != null;
}

class _MaterialAnalysisBucketPage extends StatefulWidget {
  const _MaterialAnalysisBucketPage({
    required this.host,
    required this.bucket,
    required this.initialFilter,
  });

  /// 宿主页状态（分桶投影/权限/执行编排都在宿主页链上；运行时实例永远是
  /// 最终实现类 _ProductionMaterialAnalysisPageState）。
  final _MaterialAnalysisProductTasksState host;
  final _AnalysisBucket bucket;
  final _PreparationTaskFilter initialFilter;

  @override
  State<_MaterialAnalysisBucketPage> createState() =>
      _MaterialAnalysisBucketPageState();
}

class _MaterialAnalysisBucketPageState
    extends State<_MaterialAnalysisBucketPage> {
  final Set<String> _selectedIds = {};
  late _PreparationTaskFilter _taskFilter;

  /// 采购/委外桶的表头筛选（进度/缺口；视图级过滤，切段清空）。
  final Map<String, String?> _tableFilters = {};

  /// 进行中清单办理追加；本次输入沿用共用核对页。
  bool get _appendMode => _taskFilter == _PreparationTaskFilter.inProgress;

  List<_BucketRow> _filterRows(List<_BucketRow> rows) => rows
      .where((row) {
        return switch (_taskFilter) {
          _PreparationTaskFilter.pending => _host._bucketRowHasPending(
            row,
            _bucket,
          ),
          _PreparationTaskFilter.inProgress => _host._bucketRowInProgress(
            row,
            _bucket,
          ),
          _PreparationTaskFilter.blocked => _host._bucketRowNeedsAttention(
            row,
            _bucket,
          ),
        };
      })
      .toList(growable: false);

  bool _canSelectTask(_BucketRow row) => switch (_taskFilter) {
    _PreparationTaskFilter.pending => _host._bucketRowCanAct(row, _bucket),
    // 进行中任务可单独勾选追加；已有数量不再次提交。
    _PreparationTaskFilter.inProgress => _host._bucketRowCanAppend(
      row,
      _bucket,
    ),
    _PreparationTaskFilter.blocked => false,
  };

  /// 只读桶（MasterDataTableView）的分页：每页 [_pageSize] 行，只构建当页。
  /// 几百上千产品的分析里 waiting/buy 桶动辄数千行——一次性构建在网页端
  /// （CanvasKit 布局更慢）是分钟级卡死；分页后翻页即切页。勾选按业务 id
  /// 由本页持有，跨页天然保留。
  static const int _pageSize = 200;
  int _pageNo = 1;

  _MaterialAnalysisProductTasksState get _host => widget.host;
  _AnalysisBucket get _bucket => widget.bucket;

  @override
  void initState() {
    super.initState();
    _host._preparationReadContexts.add(context);
    _host.materialDetailRevision.addListener(_refreshFromHost);
    _taskFilter = widget.initialFilter;
    // 宿主页「创建子件任务」后自动选中的子件：进桶时先勾上(能办的才勾)。
    for (final row in _host._bucketRows(_bucket)) {
      if (_host._selectedPlanLineIds.contains(row.id) && _canSelectTask(row)) {
        _selectedIds.add(row.id);
      }
    }
  }

  void _refreshFromHost() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _host.materialDetailRevision.removeListener(_refreshFromHost);
    _host._preparationReadContexts.remove(context);
    super.dispose();
  }

  bool _running = false;

  List<_MaterialGroup> _supplyGroupsForRow(_BucketRow row) {
    if (row.mergedGroups case final members?) return members;
    if (row.group != null) return [row.group!];
    if (row.candidate?.group != null) return [row.candidate!.group!];
    final product = row.product;
    final analysis = _host._analysis;
    if (product == null || analysis == null) return const [];
    // 车间桶的行是产品（如待生产的柜）：物料/调拨既可选产品本身（根供给
    // 行——把其它计划已下达的外部供给调进来冲减自制量），也可选其直接
    // 子件；调入只改覆盖数量，下达车间流程不变（2026-09-13 口径）。
    final root = _host._rootSupplyMaterialOf(product);
    final materials = [
      ?root,
      ..._host
          ._depth1MaterialsFor(product)
          .where((material) => material.materialLineId != root?.materialLineId),
    ];
    final indexes = _host._analysisIndexes(analysis);
    return [
      for (final material in materials)
        if (indexes.groupsByLine[material.materialLineId] != null)
          indexes.groupsByLine[material.materialLineId]!,
    ];
  }

  Future<void> _openSupplyDetails(_BucketRow row) async {
    if (_actionsLocked) return;
    final groups = _supplyGroupsForRow(row);
    if (groups.isEmpty) return;
    final before = _host._analysis;
    // 2026-09-13：车间桶的产品行（如待生产的柜）点「物料 / 调拨」直达
    // 根供给行的调拨选择器，不再先弹物料选择；根供给行缺失时才回退选择框。
    final isProductRow =
        row.product != null &&
        row.group == null &&
        row.candidate?.group == null;
    final _MaterialGroup group;
    if (isProductRow) {
      group = groups.firstWhere(
        (group) => group.representative.isRootSupply,
        orElse: () => groups.first,
      );
    } else if (groups.length == 1) {
      group = groups.single;
    } else {
      final selected = await showDialog<_MaterialGroup>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('选择需要查看或调拨的物料'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final group in groups)
                    ListTile(
                      title: Text(
                        group.representative.goodsName ??
                            group.representative.goodsCode ??
                            '物料',
                      ),
                      subtitle: Text(
                        '需求 ${_host._qty(group.representative.requiredQty)} · 物理缺口 ${_host._qty(group.representative.shortageQty)}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).pop(group),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      if (selected == null) return;
      group = selected;
    }
    if (!mounted) return;
    // 2026-09-13 起「物料 / 调拨」先进简化选择器（两个调入入口+完整详情），
    // 供给明细与记录留在完整详情里。
    await _host._showTransferLauncher(group);
    if (!mounted || identical(before, _host._analysis)) return;
    // 调拨改了缺口与在途：本页没有输入框要保，重建行集即可(数量在级联页里
    // 按进页那一刻的快照重新给默认值)。
    setState(() {
      _selectedIds.clear();
      _pageNo = 1;
    });
  }

  // ===== 与主表统一的身份列：物料名称 / 编号 / 颜色 =====
  // 2026-09-14 用户口径「三个入口的列表也用这样的形式，都统一，不要物料分析
  // 页面的表头一种、其他的不一样」。原先分桶详情把编号/规格/颜色塞在身份格里
  // （格式与主表副行各不相同），现在与主表同一组独立列，顺序也一致。
  // 「单位」列 2026-10-10 起（T9 全站口径）与主表一起退役：数量列内联单位。

  /// 本行的物料事实来源：物料组 → 候选物料 → 产品的根供给行。
  ProductionMaterialAnalysisMaterial? _rowMaterial(_BucketRow row) {
    final group = row.group ?? row.candidate?.group;
    if (group != null) return group.representative;
    final material = row.candidate?.material;
    if (material != null) return material;
    final product = row.product;
    return product == null ? null : _host._rootSupplyMaterialOf(product);
  }

  String? _rowGoodsName(_BucketRow row) {
    final product = row.product;
    if (product != null) return product.goodsName ?? product.goodsCode;
    final material = _rowMaterial(row);
    final name = material?.goodsName ?? material?.goodsCode;
    if (name == null) return null;
    // 合并批次行：名称后标注来源条数——「跟下达车间一样」的合并身份。
    if (row.mergedGroups case final members?) {
      final sources = members
          .expand((group) => group.paths)
          .map((path) => path.analysisLineId)
          .toSet()
          .length;
      return '$name（$sources 来源 · 合并下单）';
    }
    return name;
  }

  String? _rowGoodsCode(_BucketRow row) =>
      (row.product?.goodsCode ?? _rowMaterial(row)?.goodsCode)?.trim();

  String? _rowColorName(_BucketRow row) =>
      (row.product?.colorName ?? _rowMaterial(row)?.colorName)?.trim();

  String? _rowUnitName(_BucketRow row) =>
      (row.product?.unitName ?? _rowMaterial(row)?.unitName)?.trim();

  List<MasterColumnDef<_BucketRow>> _identityColumns() => [
    MasterColumnDef<_BucketRow>(
      key: 'goods',
      label: '物料名称',
      width: 220,
      value: _rowGoodsName,
      cellBuilderHandlesSemantics: true,
      // 顶层成品行名称后挂红色「顶层」小框；采购/委外桶的物料行没有 product，
      // 这些表照旧只出身份格。
      cellBuilder: (context, row) => _goodsNameCell(
        context,
        name: _rowGoodsName(row) ?? row.id,
        product: row.product,
      ),
    ),
    MasterColumnDef<_BucketRow>(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: _rowGoodsCode,
    ),
    MasterColumnDef<_BucketRow>(
      key: 'colorName',
      label: '颜色',
      width: 96,
      value: _rowColorName,
    ),
  ];

  /// 本行改路线时作用的操作组（产品行走它的根供给行）。
  _MaterialGroup? _rowRouteGroup(_BucketRow row) {
    final group = row.group ?? row.candidate?.group;
    if (group != null) return group;
    final product = row.product;
    final analysis = _host._analysis;
    if (product == null || analysis == null) return null;
    final root = _host._rootSupplyMaterialOf(product);
    return root == null
        ? null
        : _host._analysisIndexes(analysis).groupsByLine[root.materialLineId];
  }

  /// 供应方式列（2026-09-14）：三个入口都能就地改，确认后本行自动换到对应
  /// 入口；已下达 / 已有下游行动的行只读显示。
  MasterColumnDef<_BucketRow> _routeColumn() => MasterColumnDef<_BucketRow>(
    key: 'route',
    label: _host._l10n.materialRoute,
    width: 132,
    info:
        '这批物料怎么准备：采购 = 向供应商买；委外 = 发给加工商加工；'
        '自制 = 自己车间生产。在这里改并确认后，本行会立刻移到对应的入口，'
        '同时记为该货品下次的默认供料方式。',
    value: (row) {
      // 与单元格同一口径：合并行/锚点行锁定批次路线，避免筛选/排序按错边。
      if (row.mergedAction case final MaterialAnalysisSupplyAction action) {
        return action.route?.label;
      }
      if (row.product?.sourceType == 'AGGREGATE_MAKE') {
        return MaterialSupplyRoute.make.label;
      }
      final group = _rowRouteGroup(row);
      return group == null ? null : _host._draftRoute(group)?.label;
    },
    cellBuilderHandlesSemantics: true,
    cellBuilder: (context, row) => _routeCell(context, row),
  );

  Widget _routeCell(BuildContext context, _BucketRow row) {
    final theme = Theme.of(context);
    // 合并批次行的供应方式锁定为批次路线（批次已成立，不能在桶里改路线）。
    // 共享制造锚点产品行（AGGREGATE_MAKE）同样是已成立的自制批次：显示
    // 「自制」只读——锚点没有根供给行，旧口径在这里显示「—」。
    if (row.mergedAction case final MaterialAnalysisSupplyAction action) {
      return Text(
        action.route?.label ?? '—',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    if (row.product?.sourceType == 'AGGREGATE_MAKE') {
      return Text(
        MaterialSupplyRoute.make.label,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final group = _rowRouteGroup(row);
    if (group == null) return const Text('—');
    final current = _host._draftRoute(group);
    final editable =
        !_actionsLocked &&
        _host._canRoute &&
        _host._canEditMaterialRoute(group);
    if (!editable) {
      return Text(
        current?.label ?? '—',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    // 2026-09-16 用户口径：表格内下拉统一用自家 UtenDropdownField（统一弹层/
    // 单行省略号/描边与同行格一致），不再用原生 DropdownButton。
    // 2026-10-06 行高统一口径：本表没有其它输入控件（读表），下拉走 flat——
    // 高度与单行文本格一致，不再用编辑表的 dense 控件高。
    return UtenDropdownField(
      key: ValueKey('material-bucket-route-${row.id}'),
      flat: true,
      value: current?.name,
      hintText: '请选择供应方式',
      items: [
        for (final option in MaterialSupplyRoute.values)
          UtenDropdownItem(value: option.name, label: option.label),
      ],
      onChanged: (next) {
        if (next == null) return;
        _changeRoute(row, group, MaterialSupplyRoute.values.byName(next));
      },
    );
  }

  Future<void> _changeRoute(
    _BucketRow row,
    _MaterialGroup group,
    MaterialSupplyRoute? next,
  ) async {
    if (next == null || next == _host._draftRoute(group)) return;
    await _host._confirmRouteChange(group, next);
    if (!mounted) return;
    // 换桶后本页行集要跟着变：桶投影按 confirmed_route 算，宿主 setState
    // 不会重建本页。
    setState(() {
      _selectedIds.remove(row.id);
      _pageNo = 1;
    });
  }

  bool get _hasWriteAction => _canAct;

  /// 动作执行窗口（含宿主页 busy 与本页 _running——宿主页 busy 变化不通知
  /// 本页重建，故两态都压住批量入口）。
  bool get _actionsLocked => _host._busy || _running;

  bool get _canAct =>
      (_taskFilter == _PreparationTaskFilter.pending || _appendMode) &&
      switch (_bucket) {
        _AnalysisBucket.workshop => _host._canGenerate || _host._canNotify,
        _AnalysisBucket.buy => _host._canNotify,
        _AnalysisBucket.subcontract => _host._canNotify || _host._canGenerate,
      };

  // 三个桶只负责选择范围，核对和提交复用主表。
  Future<void> _submitMaterialBucket(Set<String> selectedIds) async {
    if (!_canAct || _actionsLocked) return;
    final route = _bucket.supplyRoute;
    final groups = <String, _MaterialGroup>{};
    for (final row in _filterRows(_host._bucketRows(_bucket))) {
      if (!selectedIds.contains(row.id) || !_canSelectTask(row)) continue;
      for (final group in _host._preparationGroupsOf(row)) {
        // 合并行只把「还有事可办」的成员带进核对页：无剩余待办、也没有已下
        // 达量可追加的成员不该预选（缺车间/负责人的成员会阻断整批提交）。
        if (row.isMergedBatch &&
            route != null &&
            _host._preparationUncoveredQty(group) <= 0 &&
            _host._preparationOrderedQty(group) <= 0 &&
            !_host._hasSupplySubmitQty(group, route)) {
          continue;
        }
        groups[group.key] = group;
      }
    }
    if (groups.isEmpty) return;
    setState(() => _running = true);
    try {
      await _host._submitPreparationGroups(
        groups.values.toList(),
        append: _appendMode,
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final analysis = _host._analysis;
    if (analysis == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const SizedBox.shrink();
    }
    final allRows = _host._bucketRows(_bucket);
    final rows = _filterRows(allRows);
    return Scaffold(
      appBar: UtenAppBar(
        title: '${_bucket.countLabel(_host._l10n)} · ${rows.length}',
        // 分桶详情是宿主页的命令式子弹层，没有独立路由 scope；权限入口
        // 由宿主页承载（见 PagePermissionAction._scopeFromRouter 的
        // fail-closed 契约——非 go_router 页路由不得解析 scope）。
        showPagePermissionAction: false,
        leading: UtenBackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      // 下达进行中的遮罩画在**本页**（2026-09-11）：此前是「先 pop 回物料分析
      // → 在宿主页转圈」，用户看到的是「点了下达，页面自己退回去了」。复用宿主页
      // 那一份 `_planSubmissionOverlay`（同一个 key，文案/语义/不可关闭都一致），
      // 不另写一份会漂移的。
      body: Stack(
        children: [
          _bucketBody(theme, analysis, allRows, rows),
          // 进度遮罩跟随宿主的**网络调用本身**（planSubmissionProgress），不跟
          // `_running`：后者要到结果弹层看完才落下，遮罩会一直转在弹层背后。
          // 2026-09-12：下达采购/委外的通用加载遮罩（车间仍走下方专用遮罩）。
          ValueListenableBuilder<String?>(
            valueListenable: _host.bucketActionBusyMessage,
            builder: (context, message, _) => message != null
                ? Positioned.fill(
                    child: UtenBusyOverlay(
                      title: message,
                      description: '所选行会一起处理，全部成功才算完成，完成后自动刷新。',
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _host.planSubmissionProgress,
            builder: (context, submitting, _) => submitting
                ? Positioned.fill(child: _host._planSubmissionOverlay(theme))
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _bucketBody(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
    List<_BucketRow> allRows,
    List<_BucketRow> rows,
  ) {
    return SafeArea(
      // 宽度收敛用外壳容器；selectable:false 退出文字框选——表格页框选
      // 低价值，且 SelectionArea × 可滚动表格（含横向同步/行手势）为
      // 全站未测组合，转场期间有选择区重算开销（准则：外壳容器遇
      // 重交互表格一律退出）。
      child: UtenContentContainer.wide(
        selectable: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
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
                      Icons.info_outline_rounded,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        _bucket.semanticHint(_host._l10n),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                    // 2026-09-05 用户口径：不再给「全选全部 N 条」——表头
                    // 复选框已覆盖当页，跨页批量从宿主页分桶入口按桶执行。
                  ],
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              UtenFilterToolbar<_PreparationTaskFilter>(
                segmentsKey: const Key('material-analysis-task-state'),
                selected: {_taskFilter},
                enabled: !_actionsLocked,
                segments: [
                  UtenFilterSegment(
                    value: _PreparationTaskFilter.pending,
                    label: _host._l10n.materialPreparationPending,
                    count: allRows
                        .where(
                          (row) => _host._bucketRowHasPending(row, _bucket),
                        )
                        .length,
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                  UtenFilterSegment(
                    value: _PreparationTaskFilter.inProgress,
                    label: _host._l10n.materialPreparationInProgress,
                    count: allRows
                        .where(
                          (row) => _host._bucketRowInProgress(row, _bucket),
                        )
                        .length,
                    countForm: UtenSegmentCountForm.inProgress,
                  ),
                  UtenFilterSegment(
                    value: _PreparationTaskFilter.blocked,
                    label: _host._l10n.materialTaskBlocked,
                    // 这是待处理的子集，沿平台规则不重复挂第二枚红色总任务数。
                    count: allRows
                        .where(
                          (row) => _host._bucketRowNeedsAttention(row, _bucket),
                        )
                        .length,
                  ),
                ],
                onSelectionChanged: (value) {
                  if (_actionsLocked || value == _taskFilter) return;
                  setState(() {
                    _taskFilter = value;
                    _pageNo = 1;
                    _selectedIds.clear();
                    _tableFilters.clear();
                  });
                },
              ),
              const SizedBox(height: UtenSpacing.s8),
              // 2026-09-22 起三个桶同一张只读清单(原下达车间的可编辑计划表退役)：
              // 勿传 virtualized(它强制表体撑满剩余高度 → 横滚条恒钉屏底)；保持
              // 默认 content-tall，内容少横滚条贴末行、超高才钉底。
              Expanded(child: _bucketTable(rows)),
            ],
          ),
        ),
      ),
    );
  }

  /// 分页切片：只构建当页行(大分析数千行一次性构建在网页端是分钟级卡死)。
  int _pageTotal(List<_BucketRow> rows) =>
      rows.length <= _pageSize ? 1 : (rows.length / _pageSize).ceil();

  List<_BucketRow> _pageRows(List<_BucketRow> rows, int page) {
    if (rows.length <= _pageSize) return rows;
    final start = (page - 1) * _pageSize;
    if (start >= rows.length) return rows.sublist(0);
    final end = (start + _pageSize).clamp(0, rows.length);
    return rows.sublist(start, end);
  }

  /// 三个桶共用的只读清单(2026-09-22 用户口径「外面的不填数值，得进到详情页
  /// 才能填；表格只显示对应重要的信息」)：进度最前(2026-10-08 口径)，其后身份
  /// 四列 + 供应方式 / 需求量 / 缺口；已下达段把缺口换成下达数量并多一列已下达
  /// 单据。勾选行点底部按钮、或双击一行，都进「父件 + 下层一起下单」页；其余
  /// 信息(所属仓库、生产车间、BOM 路径、仓库余量、公共认领未实收)搬进那一页。
  Widget _bucketTable(List<_BucketRow> rows) {
    final theme = Theme.of(context);
    // 进度视图一次算好（2026-10-09）：表头筛选计数、筛选匹配与下面的默认
    // 排序共用同一份——排序键在比较器里现算会把同一分支乘上 n·log n。
    final progressViews = {
      for (final row in rows) row.id: _rowProgressView(theme, row),
    };
    // 进度 / 缺口两列表头可点筛选(视图级过滤不动选择)，三个桶都给。
    final progressCounts = <String, int>{};
    var gapCount = 0;
    for (final row in rows) {
      final label = progressViews[row.id]?.label;
      if (label != null) {
        progressCounts[label] = (progressCounts[label] ?? 0) + 1;
      }
      if ((_rowShortageQty(row) ?? 0) > 0) gapCount++;
    }
    // 默认排序（2026-10-09 用户口径「按进度排序，最接近完成的在上面」）：
    // 有单据链阶段的行按「本链还差几步」升序（stepCount − stepIndex，已入库/
    // 已完工＝0 最前），同一步里生产中完成比高的在前；没有阶段事实的行
    // （等待下达/阻塞/只读/状态待回传）不冒充进度，排在有阶段事实的行之后，
    // 彼此保持投影原序。下标兜底保证稳定（List.sort 本身不稳定）。
    final sorted =
        [for (var i = 0; i < rows.length; i++) (index: i, row: rows[i])]
          ..sort((a, b) {
            final aStage = progressViews[a.row.id]?.stage;
            final bStage = progressViews[b.row.id]?.stage;
            if (aStage != null && bStage != null) {
              final byRemaining = (aStage.stepCount - aStage.stepIndex)
                  .compareTo(bStage.stepCount - bStage.stepIndex);
              if (byRemaining != 0) return byRemaining;
              final byProgress = (bStage.progress ?? 0).compareTo(
                aStage.progress ?? 0,
              );
              if (byProgress != 0) return byProgress;
            } else if ((aStage == null) != (bStage == null)) {
              return aStage == null ? 1 : -1;
            }
            return a.index.compareTo(b.index);
          });
    final progressFacets = [
      for (final entry in progressCounts.entries)
        MasterFacetBucket(
          value: entry.key,
          count: entry.value,
          label: entry.key,
        ),
    ]..sort((a, b) => a.display.compareTo(b.display));
    final columns = _bucketColumns(theme);
    // 文本列(物料名称 / 编号 / 颜色 / 单位 / 供应方式)按单元格文本分桶：用户口径
    // 2026-09-11「同一张表里类型 / 货品也要有筛选箭头」——桶表改只读后「类型」列
    // 退役, 其余文本列一个不落, 同名货品合并成一桶。
    const textFacetKeys = {
      'goods',
      'goodsCode',
      'colorName',
      'unitName',
      'route',
    };
    final textColumns = {
      for (final column in columns)
        if (textFacetKeys.contains(column.key)) column.key: column.value,
    };
    final textCounts = <String, Map<String, int>>{};
    for (final row in rows) {
      for (final entry in textColumns.entries) {
        final text = entry.value(row)?.trim();
        if (text == null || text.isEmpty) continue;
        final counts = textCounts.putIfAbsent(entry.key, () => {});
        counts[text] = (counts[text] ?? 0) + 1;
      }
    }
    final textFacets = {
      for (final entry in textCounts.entries)
        entry.key: [
          for (final bucket in entry.value.entries)
            MasterFacetBucket(value: bucket.key, count: bucket.value),
        ]..sort((a, b) => a.display.compareTo(b.display)),
    };
    final progressFilter = _tableFilters['taskState'];
    final gapFilter = _tableFilters['shortageQty'];
    final textFilters = {
      for (final entry in _tableFilters.entries)
        if (entry.value != null && textColumns.containsKey(entry.key))
          entry.key: entry.value!,
    };
    final filtered =
        progressFilter == null && gapFilter == null && textFilters.isEmpty
        ? sorted.map((entry) => entry.row).toList(growable: false)
        : sorted
              .where((entry) {
                final row = entry.row;
                if (progressFilter != null &&
                    progressViews[row.id]?.label != progressFilter) {
                  return false;
                }
                if (gapFilter != null && (_rowShortageQty(row) ?? 0) <= 0) {
                  return false;
                }
                for (final entry2 in textFilters.entries) {
                  if (textColumns[entry2.key]!(row)?.trim() != entry2.value) {
                    return false;
                  }
                }
                return true;
              })
              .map((entry) => entry.row)
              .toList(growable: false);
    final filteredTotalPages = _pageTotal(filtered);
    final filteredPage = _pageNo.clamp(1, filteredTotalPages);
    // 已下达段只在真有可追加的行时才出勾选列与动作组(ADR-099)。
    final selectable = _canAct && (!_appendMode || rows.any(_canSelectTask));
    return MasterDataTableView<_BucketRow>(
      tableKey:
          'features.production.pages.material_analysis_bucket_detail.MaterialAnalysisBucketPageState._bucketTable.1',
      columns: columns,
      items: _pageRows(filtered, filteredPage),
      facets: {
        ...textFacets,
        if (progressFacets.isNotEmpty) 'taskState': progressFacets,
        if (!_appendMode && gapCount > 0)
          'shortageQty': [
            MasterFacetBucket(value: 'GAP', count: gapCount, label: '只看有缺口'),
          ],
      },
      nullCounts: const {},
      filters: {
        for (final entry in _tableFilters.entries)
          if (entry.value != null) entry.key: entry.value!,
      },
      onFilterChanged: (key, value) => setState(() {
        _tableFilters[key] = value;
        _pageNo = 1;
      }),
      selectable: selectable,
      idOf: (row) => _canSelectTask(row) ? row.id : null,
      rowKeyOf: (row) => row.id,
      selectedIds: _selectedIds,
      onSelectedIdsChanged: (next) => setState(() {
        _selectedIds
          ..clear()
          ..addAll(next);
      }),
      batchActionsBuilder: selectable ? _batchActions : null,
      rowMenuBuilder: _rowMenu,
      // 单击选中、双击打开：能办的行双击直接进下单页办它这一行。
      onRowTap: _onRowTap,
      enableTextSelection: false,
      showFullscreenToggle: false,
      canOpenRow: (row) =>
          _canSelectTask(row) ||
          row.group != null ||
          (_host._canViewPlans &&
              (row.product?.latestPlanId?.trim().isNotEmpty ?? false)),
      emptyMessage: _host._l10n.materialTaskEmpty,
      currentPage: filteredPage,
      totalPages: filteredTotalPages,
      paginationScope: (_host._analysis?.analysisId, _bucket, _taskFilter),
      onPageChange: (next) => setState(() => _pageNo = next),
    );
  }

  /// 底部动作组：跨页全选 + 一颗「进下单页」按钮。省略号 = 这一下不是提交，
  /// 是进「父件 + 下层一起下单」页；真正的提交在那一页的「一键下单 / 下单」里。
  /// 文案不能更长：悬浮动作组在窄屏下会溢出。
  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    if (!_hasWriteAction) return const [];
    final count = selectedIds.length;
    final append = _appendMode;
    final label = switch (_bucket) {
      _AnalysisBucket.buy => append ? '追加采购($count)…' : '提交采购需求($count)…',
      _AnalysisBucket.subcontract => append ? '追加委外($count)…' : '下达委外($count)…',
      _AnalysisBucket.workshop =>
        append ? '追加生产计划($count)…' : '创建生产计划($count)…',
    };
    final canAct = _canAct && !_actionsLocked && count > 0;
    // 跨页全选放悬浮区（与已选胶囊/提交按钮同框）；表头复选框只选当页。
    final allRows = _filterRows(_host._bucketRows(_bucket));
    final selectableCount = allRows.where(_canSelectTask).length;
    return [
      if (_taskFilter == _PreparationTaskFilter.pending &&
          allRows.length > _pageSize)
        UtenButton(
          key: const Key('material-analysis-bucket-select-all'),
          type: UtenButtonType.ghost,
          size: UtenButtonSize.large,
          icon: Icons.select_all_rounded,
          onPressed: _actionsLocked
              ? null
              : () => setState(() {
                  _selectedIds
                    ..clear()
                    ..addAll(
                      allRows.where(_canSelectTask).map((row) => row.id),
                    );
                }),
          child: Text('全选全部 $selectableCount 条'),
        ),
      UtenButton(
        // 下达车间沿用既有键名(一批用例按它定位)。
        key: Key(
          _bucket == _AnalysisBucket.workshop
              ? 'material-analysis-bucket-action-ready'
              : 'material-analysis-bucket-action-${_bucket.name}',
        ),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: _bucket == _AnalysisBucket.workshop
            ? Icons.factory_outlined
            : Icons.notifications_active_outlined,
        onPressed: canAct ? () => _submitMaterialBucket(selectedIds) : null,
        onDisabledTap: count == 0
            ? null
            : !_canAct
            ? () => context.appWarning('没有下达采购、委外或生产任务的权限')
            : null,
        child: Text(label),
      ),
    ];
  }

  /// 行右键 / 长按菜单：进下单页办这一行、物料调拨、全链路进度。
  List<UtenContextMenuEntry> _rowMenu(_BucketRow row) => [
    if (_canSelectTask(row))
      UtenMenuItem(
        label: _appendMode ? '进详情页追加' : '进详情页下单',
        icon: Icons.open_in_new_rounded,
        enabled: _canAct && !_actionsLocked,
        onTap: () => _submitMaterialBucket({row.id}),
      ),
    UtenMenuItem(
      // 2026-10-10 调拨口径收窄：公共在途不再混进「物料调拨」（可用数量已含
      // 它，下单自动认领）；手动采用保留为独立菜单项（与主表物料行右键一致）。
      label: '物料调拨',
      icon: Icons.inventory_2_outlined,
      enabled: !_actionsLocked && _supplyGroupsForRow(row).isNotEmpty,
      onTap: () => _openSupplyDetails(row),
    ),
    if (row.group != null && _host._canClaimMaterialSharedFuture(row.group!))
      UtenMenuItem(
        label: '采用公共在途',
        icon: Icons.call_received_rounded,
        enabled: !_actionsLocked,
        onTap: () async {
          await _host._claimSharedFuture({row.group!.key});
          if (!mounted) return;
          // 认领改了缺口/在途：重建行集（与调拨返回后的处理同口径）。
          setState(() {
            _selectedIds.clear();
            _pageNo = 1;
          });
        },
      ),
    if (row.group != null ||
        (_host._canViewPlans &&
            (row.product?.latestPlanId?.trim().isNotEmpty ?? false)))
      UtenMenuItem(
        label: row.group != null ? '全链路进度' : '查看生产计划',
        icon: Icons.timeline_rounded,
        enabled: !_actionsLocked,
        onTap: () => _showProgress(row),
      ),
  ];

  /// 双击一行：能办的行直接进「父件 + 下层一起下单」页办它这一行；不能办的
  /// 行看进度。
  void _onRowTap(_BucketRow row) {
    if (_canAct && !_actionsLocked && _canSelectTask(row)) {
      _submitMaterialBucket({row.id});
      return;
    }
    _showProgress(row);
  }

  /// 物料行弹全链路进度；已下达的产品行进它的生产计划详情。
  void _showProgress(_BucketRow row) {
    final material = row.group?.representative;
    if (material != null) {
      showDialog<void>(
        context: context,
        builder: (_) => MaterialSupplyProgressDialog(
          analysisId: _host._analysis!.analysisId,
          material: material,
          canViewProductionPlans: _host._canViewPlans,
        ),
      );
      return;
    }
    final planId = row.product?.latestPlanId?.trim();
    if (_host._canViewPlans && planId != null && planId.isNotEmpty) {
      context.push(RoutePath.productionPlanDetail(planId));
    }
  }

  // ===== 三种行形态(物料组 / 产品 / 自制候选)的同名取值 =====

  double? _rowRequiredQty(_BucketRow row) {
    // 共享制造锚点行（AGGREGATE_MAKE）：需要数量以锚点/批次事实优先——锚点
    // 挂着成员操作组（`_preparationGroupsOf` 走锚点索引），成员行的需求多数已
    // 转交为 0，直接求和会把 3000 显示成 0（2026-10-09 用户反馈）。
    // 「需要数量」是原始来源需求口径，只取批次需求份，不含公共备货/安全补库。
    final product = row.product;
    if (product?.sourceType == 'AGGREGATE_MAKE') {
      if ((product!.requestedQty) > 0) return product.requestedQty;
      final action = _host._aggregateBatchActionOfGoods(
        product.goodsId,
        MaterialSupplyRoute.make,
      );
      if (action != null && action.requestedQty > 0) return action.requestedQty;
    }
    final groups = _host._preparationGroupsOf(row);
    if (groups.isEmpty) {
      return product?.requestedQty;
    }
    if (row.isMergedBatch) {
      // 合并行需求＝各成员行 ∪ 其转交目标行（去重）的真实需求：自制共享批次的
      // 原行需求已转挂到目标行（本行显示 0），只加成员会把 2000 显示成 0。
      final analysis = _host._analysis;
      final visited = <String>{};
      var total = 0.0;
      for (final material in groups.expand((group) => group.paths)) {
        if (!visited.add(material.materialLineId)) continue;
        total += material.sourceRequiredQty ?? material.requiredQty;
        final targets = material.aggregatePreparation?.targetMaterialLineIds;
        if (targets == null || analysis == null) continue;
        for (final targetId in targets) {
          if (!visited.add(targetId)) continue;
          final target = _host._materialOfLine(targetId);
          if (target != null) {
            total += target.sourceRequiredQty ?? target.requiredQty;
          }
        }
      }
      return total;
    }
    return groups.fold<double>(
      0,
      (sum, group) =>
          sum +
          group.paths.fold<double>(
            0,
            (sum, material) =>
                sum + (material.sourceRequiredQty ?? material.requiredQty),
          ),
    );
  }

  double? _rowShortageQty(_BucketRow row) {
    final groups = _host._preparationGroupsOf(row);
    if (groups.isEmpty) return row.product?.remainingQty;
    final budget = _host._preparationBudgetOfGroups(groups);
    if (budget != null) return budget.netShortageQty;
    return groups.fold<double>(
      0,
      (sum, group) => sum + _host._preparationDisplayShortageQty(group),
    );
  }

  double? _rowIssuedQty(_BucketRow row) {
    if (row.mergedAction case final MaterialAnalysisSupplyAction action) {
      // 合并行下单量优先批次真实总量（需求份+公共备货+安全补库）。逐成员求和会
      // 漏掉没有 allocation 锚点的同料路径；批次取消重建后的历史累计（成员行
      // 服务端总量）比新批总量大时取较大者，避免历史下单量凭空消失。
      final actionTotal =
          action.requestedQty +
          action.publicSurplusQty +
          action.safetyReplenishmentQty;
      final membersTotal = _host
          ._preparationGroupsOf(row)
          .fold<double>(
            0,
            (sum, group) => sum + _host._preparationOrderedQty(group),
          );
      return actionTotal > membersTotal ? actionTotal : membersTotal;
    }
    final groups = _host._preparationGroupsOf(row);
    if (groups.isEmpty) return row.product?.planExecutionPlannedQty;
    return groups.fold<double>(
      0,
      (sum, group) => sum + _host._preparationOrderedQty(group),
    );
  }

  double? _rowAvailableQty(_BucketRow row) {
    final groups = _host._preparationGroupsOf(row);
    if (groups.isEmpty) return null;
    final budget = _host._preparationBudgetOfGroups(groups);
    if (budget != null) return budget.availableQty;
    // 同货品的仓库/未来供给是同一池，不能按来源条数相加。
    return groups.fold<double>(
      0,
      (value, group) => value > _host._preparationAvailableQty(group)
          ? value
          : _host._preparationAvailableQty(group),
    );
  }

  /// 进度：物料行走供给进度词表；产品行走执行阶段(未下达统一「等待下达车间」，
  /// 路线待确认给红字原因)；候选看还能不能创建。合并行取批次内首个有真实
  /// 单据阶段的成员（同批各来源共享同一张单据，阶段天然一致；无锚点成员
  /// 自己推不出阶段，不能拿它顶替）。
  /// 行进度完整视图：文案 + 配色 + 单据链阶段（有真实阶段事实才非空）。
  /// 进度格、表头筛选与默认排序（见 [_bucketTable] 的进度排序）共用这一份
  /// 分支，不另写一套判据。
  ({
    String? label,
    MaterialPreparationStatusStyle style,
    ProductionFlowStage? stage,
  })
  _rowProgressView(ThemeData theme, _BucketRow row) {
    final adopted = _host
        ._preparationGroupsOf(row)
        .where(
          (group) => group.paths.any(
            (material) => material.preparationAdoptedQty > 0.0001,
          ),
        );
    if (row.group == null && adopted.isNotEmpty) {
      final status = _host._materialStatus(theme, adopted.first);
      return (
        label: status.label,
        style: _host._preparationMaterialStatusStyle(theme, adopted.first),
        stage: status.flowStage,
      );
    }
    if (row.mergedGroups case final members?) {
      for (final member in members) {
        if (_host._serverFlowStageOf(member) case final stage?) {
          return (
            label: stage.displayLabel,
            style: MaterialPreparationStatusStyle.resolve(stage: stage),
            stage: stage,
          );
        }
      }
      final status = _host._materialStatus(theme, members.first);
      return (
        label: status.label,
        style: _host._preparationMaterialStatusStyle(theme, members.first),
        stage: status.flowStage,
      );
    }
    final group = row.group;
    if (group != null) {
      final status = _host._materialStatus(theme, group);
      return (
        label: status.label,
        style: _host._preparationMaterialStatusStyle(theme, group),
        stage: status.flowStage,
      );
    }
    final product = row.product;
    if (product != null) {
      final stage = _host._productExecutionStage(product);
      if (stage != null) {
        return (
          label: stage.displayLabel,
          style: MaterialPreparationStatusStyle.resolve(
            stage: stage,
            actualState: product.planExecutionStatus,
          ),
          stage: stage,
        );
      }
      if (product.canSchedule) {
        return (
          label: '等待下达车间',
          style: MaterialPreparationStatusStyle.resolve(
            phase: MaterialPreparationStatusPhase.pending,
          ),
          stage: null,
        );
      }
      // 阻塞与主表共用整格底色及配对前景，不按供应路线分色。
      return (
        label:
            _host._rootRouteScheduleHint(product) ??
            product.scheduleBlockedReason ??
            _host._l10n.materialTaskBlocked,
        style: MaterialPreparationStatusStyle.resolve(
          phase: MaterialPreparationStatusPhase.blocked,
        ),
        stage: null,
      );
    }
    final candidate = row.candidate;
    if (candidate == null) {
      return (
        label: null,
        style: MaterialPreparationStatusStyle.resolve(),
        stage: null,
      );
    }
    return (
      label: _host._canArrangePendingMakeCandidate(candidate)
          ? '等待下达车间'
          : '当前状态不可创建',
      style: MaterialPreparationStatusStyle.resolve(
        phase: _host._canArrangePendingMakeCandidate(candidate)
            ? MaterialPreparationStatusPhase.pending
            : MaterialPreparationStatusPhase.blocked,
      ),
      stage: null,
    );
  }

  ({String? label, MaterialPreparationStatusStyle style}) _rowProgress(
    ThemeData theme,
    _BucketRow row,
  ) {
    final view = _rowProgressView(theme, row);
    return (label: view.label, style: view.style);
  }

  /// 这条产品行是不是**顶层**成品(销售 / 手工来源),而不是自制子件。
  ///
  /// `parentAnalysisLineId` 是服务端给的结构事实:只有子件行才有父装配行
  /// (模型注释「Null for top-level sales/manual sources」)。`sourceType` 再兜一道,
  /// 脏数据缺父指针时也不会把子件当顶层。
  bool _isTopLevelProduct(ProductionMaterialAnalysisProduct? product) =>
      product != null &&
      (product.parentAnalysisLineId?.isEmpty ?? true) &&
      product.sourceType != 'MAKE_COMPONENT' &&
      product.sourceType != 'AGGREGATE_MAKE';

  /// 物料名称格：身份格 + 顶层产品的红色「顶层」小框。
  ///
  /// 2026-09-15 用户口径：下达车间里一眼看不出哪一行是顶层——2026-09-05 起
  /// 「顶层与子层自制同构」，类型列一律写「自制候选」，顶层和子件长得一模一样。
  /// 名称后挂个红框就分得清「这一行是成品」。
  ///
  /// **不走 [UtenGoodsIdentityCell.trailing]**：那会在名称外面包一层 `Row`，而
  /// 本页族既有用例按「离名称最近的 Row = 整行」定位数量框与复选框
  /// (`material_analysis_root_routes_test` 等)，包了就全定位不到。`Wrap` 不是
  /// `Row`，排版等效(列窄时徽章换行而不是溢出)，定位契约因此不变。
  Widget _goodsNameCell(
    BuildContext context, {
    required String name,
    ProductionMaterialAnalysisProduct? product,
  }) {
    // 编号/颜色/单位已各自成列；规格按 2026-09-29 用户口径不再显示。
    final cell = UtenGoodsIdentityCell(name: name);
    if (!_isTopLevelProduct(product)) return cell;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: UtenSpacing.s4,
      children: [cell, const MaterialTopLevelBadge()],
    );
  }

  /// 三个桶同一组列(2026-09-22)：进度最前(2026-10-08 用户口径「状态或进度列
  /// 默认放最前」)，其后身份三列(物料名称 / 编号 / 颜色，单位列 2026-10-10 T9
  /// 退役并入数量) / 供应方式 / 需求量 / 缺口(未下达段) / 下单数量
  /// (已下达段) / 已下达单据(采购、委外的已下达段)。
  List<MasterColumnDef<_BucketRow>> _bucketColumns(ThemeData theme) {
    final host = _host;
    final issued = _appendMode;
    final route = _bucket.supplyRoute;
    return [
      MasterColumnDef<_BucketRow>(
        key: 'taskState',
        label: host._l10n.materialProgress,
        width: 260,
        info: host._l10n.materialSupplyProgressHint,
        value: (row) => _rowProgress(theme, row).label,
        cellColor: (context, row) =>
            _rowProgress(Theme.of(context), row).style.background,
        cellBuilderHandlesSemantics: true,
        cellBuilder: (context, row) {
          final progress = _rowProgress(Theme.of(context), row);
          return MaterialAnalysisPreparationCell(
            key: ValueKey('material-preparation-progress-${row.id}'),
            label: progress.label ?? '—',
            style: progress.style,
          );
        },
      ),
      ..._identityColumns(),
      _routeColumn(),
      // 2026-10-10 T9：单位列退役，四个数量列内联单位（宽度各 +35 容下「N 个」）。
      MasterColumnDef<_BucketRow>(
        key: 'requiredQty',
        label: host._l10n.materialRequired,
        width: 135,
        type: 'number',
        value: (row) =>
            formatQtyWithUnit(_rowRequiredQty(row), _rowUnitName(row)),
        exactValueOf: (row) => _rowRequiredQty(row)?.toString(),
        info: '原始来源需求；下单和追加不会改写这个数量。',
      ),
      MasterColumnDef<_BucketRow>(
        key: 'availableQty',
        label: host._l10n.materialPublicAvailable,
        width: 145,
        type: 'number',
        value: (row) =>
            formatQtyWithUnit(_rowAvailableQty(row), _rowUnitName(row)),
        exactValueOf: (row) => _rowAvailableQty(row)?.toString(),
        info: host._l10n.materialPreparationAvailableHint,
      ),
      // 缺口始终使用服务端实际缺料事实；下达量和公共备货不改变本批需求。
      // 仅未下达段保留(已下达段看已下总量与到货进度)。
      if (!issued)
        MasterColumnDef<_BucketRow>(
          key: 'shortageQty',
          label: '还需安排',
          width: 125,
          type: 'number',
          value: (row) =>
              formatQtyWithUnit(_rowShortageQty(row), _rowUnitName(row)),
          exactValueOf: (row) => _rowShortageQty(row)?.toString(),
          info: '与主表相同的待安排量；包含可采用供给时，实际提交会先核对并占用供给。',
          cellBuilder: (context, row) {
            final shortage = _rowShortageQty(row);
            if (shortage == null) return const SizedBox.shrink();
            // key 供测试/语义锚定「物理缺口」单元格；颜色与主表同一口径。
            return KeyedSubtree(
              key: const Key('bucket-shortage-qty-cell'),
              child: Text(
                formatQtyWithUnit(shortage, _rowUnitName(row)),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: host._shortageTextColor(theme, shortage),
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          },
          cellColor: (context, row) {
            final shortage = _rowShortageQty(row);
            return shortage == null
                ? null
                : host._shortageCellColor(Theme.of(context), shortage);
          },
        ),
      if (issued)
        MasterColumnDef<_BucketRow>(
          key: 'issuedQty',
          label: '下单数量',
          width: 145,
          type: 'number',
          value: (row) =>
              formatQtyWithUnit(_rowIssuedQty(row), _rowUnitName(row)),
          exactValueOf: (row) => _rowIssuedQty(row)?.toString(),
          info: '实际下单量，包含超量备货。勾选后可在同一核对页填写追加数量。',
        ),
      if (issued && route != null)
        MasterColumnDef<_BucketRow>(
          key: 'supplyProgress',
          label: '${host._l10n.materialTaskIssued}单据',
          width: 240,
          // 只展示单号：状态与全链路进度走行菜单「全链路进度」。合并批次行
          // 直接给批次单据号（部分同料路径没有 allocation 锚点，逐行引用会空）。
          value: (row) =>
              row.mergedAction?.documentNo ??
              row.group?.paths
                  .expand((path) => path.notifiedTargets)
                  .where((target) => target.target == route)
                  .map((target) => target.documentNo)
                  .whereType<String>()
                  .where((value) => value.isNotEmpty)
                  .toSet()
                  .join(' / '),
        ),
    ];
  }
}

/// 顶层产品行的红色「顶层」小框（2026-09-15 起分桶详情用，2026-10-07 起按物料
/// 汇总视图的顶层产品行同款复用）。整页族（本页与主表同库）共用这一枚，保证
/// 两个页面「顶层」的视觉口径一致：error 语义色 12% 底 / 50% 描边 / labelSmall
/// 加粗，紧凑行高不受影响。
class MaterialTopLevelBadge extends StatelessWidget {
  const MaterialTopLevelBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return Container(
      key: const ValueKey('material-analysis-top-level-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        '顶层',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 物料分析页族（主表 / 三个下达桶）状态·进度格的内容：图标 + 单行文字，
/// **一律继承表格注入的 DefaultTextStyle**（深底自动切白、亮琥珀底切深字、
/// 选中行 cellColor 让位给青绿高亮时回落常态字色），图标色同取继承字色。
///
/// 2026-10-08 状态色改版口径：格内 builder 不许写死颜色——共用
/// [MaterialPreparationStatusLabel] 的成套前景在选中行上会留下白字
/// （浅绿高亮底 + 白字看不清），本页族因此自持这一枚继承版；相位图标仍取
/// [MaterialPreparationStatusStyle.icon]，底色由列 cellColor 铺同一相位。
/// 公开仅为测试读取 [style]（与 [MaterialAnalysisBorrowBadgeContent] 同款
/// @visibleForTesting 先例）。
@visibleForTesting
class MaterialAnalysisPreparationCell extends StatelessWidget {
  const MaterialAnalysisPreparationCell({
    super.key,
    required this.label,
    required this.style,
  });

  final String label;

  /// 相位样式：本格只用 [MaterialPreparationStatusStyle.icon]，
  /// 颜色不取它（交给表格双向对比度约定）。
  final MaterialPreparationStatusStyle style;

  @override
  Widget build(BuildContext context) {
    final inherited = DefaultTextStyle.of(context).style;
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(style.icon, size: 18, color: inherited.color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                // 状态/进度列由表格统一 w700 加粗；颜色/字重都继承，不写死。
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
