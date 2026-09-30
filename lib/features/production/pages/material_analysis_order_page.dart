part of 'production_material_analysis_page.dart';

/// 三个准备桶的核对入口。数量、勾选、路线、指派和提交均由主表持有。
class _PreparationOrderPage extends StatefulWidget {
  const _PreparationOrderPage({required this.host, required this.rootLineIds});

  final _MaterialAnalysisChildShortageState host;
  final Set<String> rootLineIds;

  @override
  State<_PreparationOrderPage> createState() => _PreparationOrderPageState();
}

class _PreparationOrderPageState extends State<_PreparationOrderPage> {
  _MaterialAnalysisChildShortageState get _host => widget.host;
  bool _submitting = false;
  int _page = 1;
  ProductionMaterialAnalysisView? _rowsAnalysis;
  List<_MaterialTableRow> _rowsCache = const [];
  static const _pageSize = 100;
  late final _changes = Listenable.merge([
    _host._childShortageRevision,
    _host.materialDetailRevision,
    _host._tableEstimateTick,
  ]);

  @override
  void initState() {
    super.initState();
    _host._preparationReadContexts.add(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _host.setState(() {
        for (final row in _rows()) {
          final group = row.group!;
          if (!_host._tableUserDeselectedKeys.contains(group.key) &&
              _host._preparationCanIssue(group) &&
              _host._preparationUncoveredQty(group) > 0.0001) {
            _host._selectedMaterialGroupKeys.add(group.key);
          }
        }
        _host._draftBudget.invalidate();
      });
    });
  }

  @override
  void dispose() {
    _host._preparationReadContexts.remove(context);
    super.dispose();
  }

  List<_MaterialTableRow> _rows() {
    final analysis = _host._analysis;
    if (analysis == null) return const [];
    if (identical(analysis, _rowsAnalysis)) return _rowsCache;
    final tree = _host._bomPresentation(analysis);
    final indexes = _host._analysisIndexes(analysis);
    final depths = <String, int>{};
    int? depthOf(String id) {
      if (depths.containsKey(id)) return depths[id];
      final trail = <String>[];
      final visited = <String>{};
      String? current = id;
      while (current != null && visited.add(current)) {
        if (widget.rootLineIds.contains(current) ||
            depths.containsKey(current)) {
          var depth = depths[current] ?? 0;
          depths[current] = depth;
          for (final child in trail.reversed) {
            depths[child] = ++depth;
          }
          return depths[id];
        }
        trail.add(current);
        current = tree.parentIdsByMaterial[current];
      }
      return null;
    }

    final nodes = [
      for (final node in tree.nodesByProduct.values.expand((nodes) => nodes))
        if (depthOf(node.materialLineId) != null) node,
    ];
    final rows = <_MaterialTableRow>[];
    for (final node in _host._orderedBomNodes(
      nodes,
      parentIds: tree.parentIdsByMaterial,
    )) {
      final group = indexes.groupsByLine[node.materialLineId];
      if (group == null) continue;
      rows.add(
        _MaterialTableRow(
          kind: node.isRootSupply
              ? _MaterialTableRowKind.product
              : _MaterialTableRowKind.material,
          key: 'PREPARATION|${node.materialLineId}',
          sequence: '',
          depth: depths[node.materialLineId]!,
          product: node.isRootSupply
              ? indexes.productsById[node.analysisLineId]
              : null,
          material: node,
          group: group,
          rootAnalysisLineId: tree.rootIdsByMaterial[node.materialLineId],
          parentMaterialLineId: tree.parentIdsByMaterial[node.materialLineId],
        ),
      );
    }
    _rowsAnalysis = analysis;
    return _rowsCache = _host._withSharedTreeProjection(rows);
  }

  Future<void> _submit(List<_MaterialTableRow> rows) async {
    if (_submitting || _host._busy) return;
    final groups = <String, _MaterialGroup>{};
    for (final row in rows) {
      final group = row.group;
      if (group != null &&
          _host._selectedMaterialGroupKeys.contains(group.key)) {
        groups[group.key] = group;
      }
    }
    if (groups.isEmpty) return;
    final missingAssignment = groups.values
        .where(
          (group) => const {
            _MaterialAnalysisMaterialTableState._tableMissingWorkshopReason,
            _MaterialAnalysisMaterialTableState._tableMissingWorkerReason,
          }.contains(_host._tableIssueBlockedReason(group)),
        )
        .firstOrNull;
    if (missingAssignment != null) {
      final index = rows.indexWhere(
        (row) => row.group?.key == missingAssignment.key,
      );
      if (index >= 0) setState(() => _page = index ~/ _pageSize + 1);
      context.appWarning(
        _host._l10n.materialPreparationMissingAssignment(
          _host._tableGroupLabel(missingAssignment),
        ),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      await _host._submitMaterialTableRows(groups.values.toList());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _changes,
    builder: (context, _) {
      final theme = Theme.of(context);
      final rows = _rows();
      final pages = rows.isEmpty ? 1 : (rows.length / _pageSize).ceil();
      final page = _page.clamp(1, pages);
      final start = (page - 1) * _pageSize;
      final shown = rows.sublist(
        start,
        (start + _pageSize).clamp(0, rows.length),
      );
      bool selectedRow(_MaterialTableRow row) =>
          row.group != null &&
          _host._selectedMaterialGroupKeys.contains(row.group!.key);
      final selected = rows.where(selectedRow).length;
      return PopScope(
        canPop: !_submitting && !_host._busy,
        child: Scaffold(
          key: const Key('material-preparation-order-page'),
          appBar: UtenAppBar(
            title: _host._l10n.materialPreparationReview,
            showPagePermissionAction: false,
            leading: _submitting || _host._busy
                ? const SizedBox(width: 48)
                : UtenBackButton(onPressed: () => Navigator.of(context).pop()),
          ),
          body: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: MasterDataTableView<_MaterialTableRow>(
                  tableKey:
                      'features.production.pages.material_analysis_order_page.PreparationOrderPageState.build.1',
                  key: const Key('material-preparation-order-table'),
                  columns: _host._materialTableColumns(
                    theme,
                    revealAssignmentKeys: false,
                  ),
                  items: shown,
                  facets: const {},
                  filters: const {},
                  nullCounts: const {},
                  onFilterChanged: (_, _) {},
                  virtualized: true,
                  selectable: true,
                  rowKeyOf: (row) => row.key,
                  idOf: (row) => _host._materialRowSelectableGroups(row).isEmpty
                      ? null
                      : row.key,
                  selectedIds: {
                    for (final row in rows)
                      if (selectedRow(row)) row.key,
                  },
                  selectionSummaryCount: selected,
                  onSelectedIdsChanged: (ids) =>
                      _host._changeMaterialTableSelection(rows, ids),
                  paginationScope: (widget.host, _rowsAnalysis),
                  currentPage: page,
                  totalPages: pages,
                  onPageChange: (next) => setState(() => _page = next),
                  emptyMessage: _host._l10n.materialPreparationNoActions,
                  toolbarLeadingActions: [
                    if (_host._permissions.contains(Perm.productionPlanApprove))
                      SizedBox(
                        width: 220,
                        child: CheckboxListTile(
                          key: const Key('material-preparation-approve-now'),
                          dense: true,
                          title: Text(
                            _host._l10n.materialPreparationApproveNow,
                          ),
                          value: _host._preparationApproveNow,
                          onChanged:
                              _submitting ||
                                  _host._busy ||
                                  _host._aggregateTable.uncertain
                              ? null
                              : (value) => _host._setPreparationApproveNow(
                                  value ?? false,
                                ),
                        ),
                      ),
                    if (_host._preparationPlanResults.isNotEmpty)
                      _host._preparationPlanResultsButton(),
                  ],

                  batchActionsBuilder: (_, _) => [
                    UtenButton(
                      key: const Key('material-preparation-order-submit'),
                      size: UtenButtonSize.large,
                      icon: Icons.shopping_cart_checkout_rounded,
                      onPressed: _submitting || _host._busy || selected == 0
                          ? null
                          : () => unawaited(_submit(rows)),
                      child: Text(
                        _submitting
                            ? _host._l10n.materialPreparationOrdering
                            : _host._l10n.materialPreparationOrderCount(
                                selected,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: _host.bucketActionBusyMessage,
                builder: (context, message, _) => message == null
                    ? const SizedBox.shrink()
                    : Positioned.fill(
                        child: message.startsWith('正在生成')
                            ? _host._planSubmissionOverlay(theme)
                            : UtenBusyOverlay(
                                semanticsKey: const Key(
                                  'material-analysis-action-progress',
                                ),
                                title: message,
                                description: _host._actionBusyDescription(
                                  message,
                                ),
                              ),
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
