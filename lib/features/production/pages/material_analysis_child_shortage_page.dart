part of 'production_material_analysis_page.dart';

/// 「补下层物料」页(ADR-117)：把刚下单的件下面还缺的料都列出来，数量已按缺口填好，
/// 一键下单。
///
/// 这一页**没有自己的一套数据**：输入框、车间 / 负责人、供应方式、勾选之外的一切都是
/// 主表那一份([_MaterialAnalysisMaterialTableState])，提交走同一个
/// [_MaterialAnalysisMaterialTableState._submitMaterialTableRows]——父先子后分段、失败
/// 即停、成功后「下单数量」锁成累计已下单量、「追加下单」回 0。所以回到主表时，下单
/// 数量、追加、还缺数量已经是新的，不会出现两处数字对不上。
///
/// 一轮下完如果更深一层又缺了(比如刚给自制子件排了计划，它的原料就要跟着备)，本页
/// 按最新快照自动列出下一层，不用退出重进；全部补齐后显示「都下够了」。
class _ChildShortageFillPage extends StatefulWidget {
  const _ChildShortageFillPage({
    required this.host,
    this.rootKeys,
    this.orderedQty = const {},
    this.appendedKeys = const {},
  });

  final _MaterialAnalysisChildShortageState host;

  /// 从下单后弹窗进来：刚下单的那几件；null = 从提示条进来(所有已下单的件)。
  final Set<String>? rootKeys;
  final Map<String, double> orderedQty;
  final Set<String> appendedKeys;

  @override
  State<_ChildShortageFillPage> createState() => _ChildShortageFillPageState();
}

class _ChildShortageFillPageState extends State<_ChildShortageFillPage> {
  /// 用户亲手撤掉勾的行(其余能下单的行默认都勾着)。
  final Set<String> _deselected = {};
  bool _submitting = false;
  bool _refreshing = false;

  /// 本页已经成功下过几轮：用来区分「一进来就没有缺的」与「补完了」。
  int _rounds = 0;

  _MaterialAnalysisChildShortageState get _host => widget.host;

  late final Listenable _hostChanges = Listenable.merge([
    _host._childShortageRevision,
    _host.materialDetailRevision,
    _host._tableEstimateTick,
  ]);

  /// 缺哪些料只随分析快照与宿主状态(路线草稿等)变；敲数量只刷新格子里的估算，
  /// 不必每敲一个键把整棵 BOM 重走一遍(大分析上会卡)。
  ProductionMaterialAnalysisView? _rootsAnalysis;
  int _rootsRevision = -1;
  List<_ChildShortageRoot> _rootsCache = const [];

  List<_ChildShortageRoot> _roots() {
    final analysis = _host._analysis;
    final revision = _host._childShortageRevision.value;
    if (!identical(analysis, _rootsAnalysis) || revision != _rootsRevision) {
      _rootsAnalysis = analysis;
      _rootsRevision = revision;
      _rootsCache = _host._childShortageRoots(
        rootKeys: widget.rootKeys,
        orderedQty: widget.orderedQty,
        appendedKeys: widget.appendedKeys,
      );
    }
    return _rootsCache;
  }

  _MaterialTableRow _rowOf(_ChildShortageLine line) => _MaterialTableRow(
    kind: _MaterialTableRowKind.material,
    key: 'CHILD_SHORTAGE|${line.group.key}',
    sequence: '',
    depth: line.depth,
    material: line.material,
    group: line.group,
  );

  /// 勾选框的状态：没被撤勾、而且能下单。
  bool _checked(_ChildShortageLine line) =>
      !_deselected.contains(line.group.key) &&
      _host._tableIssueBlockedReason(line.group) == null;

  /// 算进「一键下单(N)」的行：勾着，而且填的数大于 0(清空的行不下)。
  bool _selected(_ChildShortageLine line) =>
      _checked(line) && _host._tableSubmitQtyOf(line.group) > 0.0001;

  Future<void> _refresh() async {
    if (_refreshing || _submitting || _host._busy) return;
    setState(() => _refreshing = true);
    try {
      await _host._refreshPreparationFacts(context);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _submit(List<_ChildShortageLine> lines) async {
    if (_submitting || _refreshing || _host._busy) return;
    final groups = [
      for (final line in lines)
        if (_selected(line)) line.group,
    ];
    if (groups.isEmpty) {
      context.appInfo('先勾选要下单的料');
      return;
    }
    setState(() => _submitting = true);
    var ok = false;
    try {
      ok = await _host._submitMaterialTableRows(groups, fromShortagePage: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    if (!mounted || !ok) return;
    setState(() => _rounds++);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _hostChanges,
      builder: (context, _) {
        final analysis = _host._analysis;
        final roots = analysis == null
            ? const <_ChildShortageRoot>[]
            : _roots();
        final lines = [for (final root in roots) ...root.lines];
        final urged = _host._urgedMaterialLineIds();
        final selectable = [
          for (final line in lines)
            if (_selected(line)) line,
        ];
        // 下单跑到一半不许退出(返回键、手势都拦住)：按层级一段段提交，退出了就看不到
        // 哪一段没下成，也列不出更深一层。
        return PopScope(
          canPop: !_submitting && !_refreshing,
          child: Scaffold(
            key: const Key('child-shortage-page'),
            appBar: UtenAppBar(
              title: '补下层物料',
              info: '数量已按缺口填好，核对后点右下角「一键下单」。没下过的是「下单」，下过的是「追加」。',
              // 命令式子页面，没有独立路由 scope；权限入口由物料分析页承载。
              showPagePermissionAction: false,
              // 提交期间按钮常驻但空转（PopScope 已挡返回；传 null 会回落默认
              // 返回），leading 槽恒为 UtenBackButton，标题不再左右跳变。
              leading: UtenBackButton(
                onPressed: _submitting || _refreshing
                    ? () {}
                    : () => Navigator.of(context).pop(),
              ),
              actions: [
                UtenRefreshButton(
                  key: const Key('child-shortage-refresh'),
                  enabled: !_submitting && !_refreshing && !_host._busy,
                  onRefresh: _refresh,
                ),
              ],
            ),
            body: Stack(
              children: [
                lines.isEmpty
                    ? _doneState(theme)
                    : UtenPageEdgePadding(
                        padding: const EdgeInsets.all(UtenSpacing.s16),
                        child: _table(theme, roots, lines, urged),
                      ),
                // 遮罩只跟宿主的网络段走(与分桶页、级联页同一份)：提交前宿主还会弹确认框，
                // 那段时间挂遮罩会把确认框盖在转圈背后点不动。
                AnimatedBuilder(
                  animation: Listenable.merge([
                    _host.bucketActionBusyMessage,
                    _host.planSubmissionProgress,
                  ]),
                  builder: (context, _) {
                    final segment = _host.bucketActionBusyMessage.value;
                    if (!_submitting ||
                        (segment == null &&
                            !_host.planSubmissionProgress.value)) {
                      return const SizedBox.shrink();
                    }
                    return UtenBusyOverlay(
                      semanticsKey: const Key('child-shortage-busy'),
                      title: segment ?? '正在下达车间',
                      description: '按层级先下上层再下下层：任一段失败会停下提示，已成功的不会重复下单。',
                    );
                  },
                ),
              ],
            ),
            // 全站口径（2026-09-26）：批量操作条退役吸底，改右下悬浮组——
            // 「已选 N 项」标准胶囊 + 「一键下单(N)」；未选时按钮仍在但禁用
            // （可辨识度由控件禁用态承担，见 UtenFloatingActionGroup 注释）。
            floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
            floatingActionButtonAnimator:
                FloatingActionButtonAnimator.noAnimation,
            floatingActionButton: lines.isEmpty
                ? null
                : _selectionActions(lines, selectable),
          ),
        );
      },
    );
  }

  /// 右下悬浮操作组：已选计数胶囊（✕ 撤掉全部勾选）+「一键下单(N)」。
  Widget _selectionActions(
    List<_ChildShortageLine> lines,
    List<_ChildShortageLine> selectable,
  ) {
    final hasChecked = lines.any(_checked);
    return UtenFloatingActionGroup(
      children: [
        UtenSelectionSummaryPill(
          clearKey: const Key('child-shortage-clear-selection'),
          count: selectable.length,
          onClear: !hasChecked || _submitting || _refreshing
              ? null
              : () => _clearSelection(lines),
        ),
        UtenButton(
          key: const Key('child-shortage-submit'),
          size: UtenButtonSize.large,
          icon: Icons.shopping_cart_checkout_rounded,
          // 不转圈：点下去先弹宿主的确认框，转圈会在确认框背后一直转；
          // 真正跑网络段时由上面的遮罩说明在做什么。
          onPressed:
              selectable.isEmpty || _submitting || _refreshing || _host._busy
              ? null
              : () => unawaited(_submit(lines)),
          child: Text(_submitting ? '正在下单…' : '一键下单(${selectable.length})'),
        ),
      ],
    );
  }

  /// 胶囊的 ✕：把还勾着的行全部撤勾（清空数量的行不动，它们本来就不下单）。
  void _clearSelection(List<_ChildShortageLine> lines) {
    setState(() {
      for (final line in lines) {
        if (_checked(line)) _deselected.add(line.group.key);
      }
    });
  }

  Widget _doneState(ThemeData theme) {
    final color = theme.brightness == Brightness.dark
        ? UtenColors.successOnDark
        : UtenColors.success;
    return Center(
      key: const Key('child-shortage-done'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.task_alt_rounded, size: 72, color: color),
            const SizedBox(height: UtenSpacing.s16),
            Text(
              _rounds > 0 ? '下层物料都下够了' : '下层物料都够，不用补',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: UtenSpacing.s24),
            UtenButton(
              key: const Key('child-shortage-back'),
              size: UtenButtonSize.large,
              icon: Icons.arrow_back_rounded,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回物料分析'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _table(
    ThemeData theme,
    List<_ChildShortageRoot> roots,
    List<_ChildShortageLine> lines,
    Set<String> urged,
  ) {
    final byRow = {
      for (final root in roots)
        for (final line in root.lines) _rowOf(line): (root: root, line: line),
    };
    final blocked = {
      for (final line in lines)
        line.group.key: _host._tableIssueBlockedReason(line.group),
    };
    final shared = {
      for (final column in _host._materialTableColumns(
        theme,
        revealAssignmentKeys: false,
      ))
        column.key: column,
    };
    final locked = _submitting || _refreshing || _host._busy;
    bool issued(_MaterialTableRow row) => _host._tableGroupIssued(row.group!);
    bool isUrged(_ChildShortageLine line) =>
        urged.contains(line.material.materialLineId);
    return MasterDataTableView<_MaterialTableRow>(
      key: const Key('child-shortage-list'),
      tableKey: 'production.materialPreparation.childShortage',
      columns: [
        MasterColumnDef(
          key: 'material',
          label: '物料名称',
          width: 260,
          value: (row) => _host._tableGroupLabel(row.group!),
          cellBuilder: (_, row) {
            final line = byRow[row]!.line;
            final name = Text(
              _host._tableGroupLabel(line.group),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
            final reason = blocked[line.group.key];
            return Row(
              children: [
                Expanded(child: name),
                if (reason != null)
                  UtenFieldHintIcon(
                    key: ValueKey('child-shortage-blocked-${line.group.key}'),
                    info: reason,
                    dense: true,
                  ),
                if (isUrged(line))
                  const UtenStatusBadge(
                    label: '车间在催',
                    type: UtenStatusBadgeType.danger,
                    size: UtenStatusBadgeSize.small,
                  ),
              ],
            );
          },
        ),
        shared['goodsCode']!,
        shared['colorName']!,
        shared['route']!,
        MasterColumnDef(
          key: 'kind',
          label: '办理',
          width: 112,
          value: (row) => row.material!.confirmedRoute == null
              ? '先选方式'
              : issued(row)
              ? '追加'
              : '下单',
        ),
        MasterColumnDef(
          key: 'shortageQty',
          label: '还缺数量',
          width: 134,
          info: '待认领表示仍需办理，本次下单会优先使用可认领的公共在途。',
          cellBuilder: (_, row) => _shortageCell(theme, byRow[row]!.line),
          value: (row) => _host._qty(_host._tableShownQty(row.material!).net),
        ),
        MasterColumnDef(
          key: 'orderQty',
          label: '本次下单量',
          width: 146,
          type: 'number',
          value: (row) => _host._tableSubmitQtyTextOf(row.group!),
          cellBuilder: (_, row) => issued(row)
              ? _host._materialTableAppendQtyCell(theme, row)
              : _host._materialTableOrderQtyCell(theme, row),
          cellBuilderHandlesSemantics: true,
        ),
        shared['orderMethod']!,
        MasterColumnDef(
          key: 'allowedOverproductionRate',
          label: '允许超产比例',
          width: 96,
          info: shared['allowedOverproductionRate']!.info,
          value: (row) => !_host._tableIssueTarget(row.group!).viaWorkshop
              ? '—'
              : _host
                    ._overproductionPercentController(
                      materialLineId: row.material!.materialLineId,
                    )
                    .text,
          measureWidthOf: (context, row, scaler) =>
              !_host._tableIssueTarget(row.group!).viaWorkshop
              ? 0
              : ProductionOverproductionRateField.contentWidthOf(
                  context,
                  '${_host._overproductionPercentController(materialLineId: row.material!.materialLineId).text}%',
                  scaler,
                ),
          measureWidthScope: 'material-shortage-overproduction-rate',
          cellBuilder: (_, row) =>
              !_host._tableIssueTarget(row.group!).viaWorkshop
              ? const Text('—')
              : ProductionOverproductionRateField(
                  key: ValueKey(
                    'child-shortage-overproduction-rate-${row.group!.key}',
                  ),
                  controller: _host._overproductionPercentController(
                    materialLineId: row.material!.materialLineId,
                  ),
                  enabled: _host._canGenerate && !locked,
                ),
        ),
        shared['productionWorkshop']!,
        shared['responsible']!,
        MasterColumnDef(
          key: 'parent',
          label: '直接上层物料',
          width: 172,
          value: (row) => byRow[row]!.line.parentLabel,
        ),
        MasterColumnDef(
          key: 'root',
          label: '来源件',
          width: 260,
          value: (row) => _host._tableGroupLabel(byRow[row]!.root.group),
          cellBuilder: (_, row) {
            final root = byRow[row]!.root;
            return Tooltip(
              message: _rootOrderLabel(root),
              child: Text(
                _host._tableGroupLabel(root.group),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            );
          },
        ),
      ],
      items: byRow.keys.toList(growable: false),
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      virtualized: true,
      expensiveRowMounts: true,
      showFullscreenToggle: false,
      showSelectionSummary: false,
      selectable: true,
      rowKeyOf: (row) => row.key,
      rowWidgetKeyOf: (row) =>
          ValueKey('child-shortage-line-${row.group!.key}'),
      idOf: (row) => blocked[row.group!.key] == null ? row.group!.key : null,
      unselectableLeadingBuilder: (_, row) => Checkbox(
        key: ValueKey('child-shortage-check-${row.group!.key}'),
        value: false,
        onChanged: null,
      ),
      selectedIds: {
        for (final line in lines)
          if (blocked[line.group.key] == null &&
              !_deselected.contains(line.group.key))
            line.group.key,
      },
      onSelectedIdsChanged: (selected) {
        if (locked) return;
        setState(() {
          for (final line in lines) {
            final key = line.group.key;
            if (blocked[key] != null) continue;
            if (selected.contains(key)) {
              _deselected.remove(key);
            } else {
              _deselected.add(key);
            }
          }
        });
      },
      toolbarLeadingActions: [
        if (roots.length == 1)
          UtenStatusBadge(
            label: _rootOrderLabel(roots.single),
            type: UtenStatusBadgeType.success,
          ),
        ..._summaryBadges(lines, urged),
      ],
      bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
      paginationScope: _host._analysis?.analysisId,
    );
  }

  List<Widget> _summaryBadges(
    List<_ChildShortageLine> lines,
    Set<String> urged,
  ) {
    var toOrder = 0, toAppend = 0, routeFirst = 0, urgedCount = 0;
    for (final line in lines) {
      if (line.material.confirmedRoute == null) {
        routeFirst++;
      } else if (_host._tableGroupIssued(line.group)) {
        toAppend++;
      } else {
        toOrder++;
      }
      if (urged.contains(line.material.materialLineId)) urgedCount++;
    }
    return [
      if (toOrder > 0)
        UtenStatusBadge(
          key: const Key('child-shortage-count-order'),
          label: '要下单 $toOrder 种',
          type: UtenStatusBadgeType.success,
          icon: Icons.add_shopping_cart_rounded,
        ),
      if (toAppend > 0)
        UtenStatusBadge(
          key: const Key('child-shortage-count-append'),
          label: '要追加 $toAppend 种',
          type: UtenStatusBadgeType.warning,
          icon: Icons.exposure_plus_1_rounded,
        ),
      if (routeFirst > 0)
        UtenStatusBadge(
          key: const Key('child-shortage-count-route'),
          label: '先维护货品来源 $routeFirst 种',
          type: UtenStatusBadgeType.danger,
          icon: Icons.alt_route_rounded,
        ),
      if (urgedCount > 0)
        UtenStatusBadge(
          key: const Key('child-shortage-count-urged'),
          label: '车间在催 $urgedCount 种',
          type: UtenStatusBadgeType.danger,
          icon: Icons.notifications_active_rounded,
        ),
    ];
  }

  String _rootOrderLabel(_ChildShortageRoot root) {
    final unit = root.group.representative.unitName ?? '';
    final fromOrder = widget.rootKeys != null;
    if (!root.quantityKnown) {
      return '${fromOrder ? '本次' : ''}已下单，数量见关联单据';
    }
    final action = !fromOrder
        ? '已下单'
        : root.appended
        ? '刚追加'
        : '刚下单';
    return '$action ${_host._qty(root.orderedQty)}$unit';
  }

  Widget _shortageCell(ThemeData theme, _ChildShortageLine line) {
    final material = line.material;
    final shown = _host._tableShownQty(material);
    final unit = material.unitName ?? '';
    final covered = shown.residual - shown.net;
    return Tooltip(
      message: covered > 0.0001
          ? '本次要覆盖 ${_host._qty(shown.residual)}$unit，'
                '其中 ${_host._qty(covered)}$unit 可先认领公共在途。'
          : '还要另外下单 ${_host._qty(shown.net)}$unit。',
      child: Text(
        shown.net > 0.0001
            ? '还缺 ${_host._qty(shown.net)}$unit'
            : '待认领 ${_host._qty(_host._childShortageUncovered(material))}$unit',
        key: ValueKey('child-shortage-net-${line.group.key}'),
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.error,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
