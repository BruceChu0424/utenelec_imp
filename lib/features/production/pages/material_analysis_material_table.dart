part of 'production_material_analysis_page.dart';

enum _MaterialTableRowKind {
  product,
  material,
  aggregate,
  aggregatePath,
  orphan,
}

typedef _MaterialTreePosition = ({
  String sequence,
  List<bool> ancestorContinuations,
  bool isLastChild,
});

final class _MaterialTableRow {
  const _MaterialTableRow({
    required this.kind,
    required this.key,
    required this.sequence,
    required this.depth,
    this.product,
    this.material,
    this.group,
    this.aggregate,
    this.hasChildren = false,
    this.ancestorContinuations = const [],
    this.isLastChild = false,
    this.contextOnly = false,
    this.rootAnalysisLineId,
    this.parentMaterialLineId,
  });

  final _MaterialTableRowKind kind;
  final String key;
  final String sequence;
  final int depth;
  final ProductionMaterialAnalysisProduct? product;
  final ProductionMaterialAnalysisMaterial? material;
  final _MaterialGroup? group;
  final _MaterialAggregate? aggregate;
  final bool hasChildren;
  final List<bool> ancestorContinuations;
  final bool isLastChild;
  final bool contextOnly;
  final String? rootAnalysisLineId;
  final String? parentMaterialLineId;

  _MaterialTableRow asPageContext(int page) => _MaterialTableRow(
    kind: kind,
    key: 'PAGE_CONTEXT|$page|$key',
    sequence: sequence,
    depth: depth,
    product: product,
    material: material,
    aggregate: aggregate,
    ancestorContinuations: ancestorContinuations,
    isLastChild: isLastChild,
    contextOnly: true,
    rootAnalysisLineId: rootAnalysisLineId,
    parentMaterialLineId: parentMaterialLineId,
  );
}

/// Excel-style material table layered on top of the existing authoritative
/// analysis projection. It deliberately reuses the route, gate, progress,
/// borrow/reallocation and write orchestration methods from the host state;
/// this file owns presentation only and never recalculates inventory facts.
abstract class _MaterialAnalysisMaterialTableState
    extends _MaterialAnalysisBorrowState {
  static const int _materialTablePageSize = 100;
  ProductionMaterialAnalysisView? _materialRowsCacheAnalysis;
  String? _materialRowsCacheKey;
  List<_MaterialTableRow>? _materialRowsCache;
  List<_MaterialTableRow>? _materialPageCacheSource;
  int? _materialPageCachePage;
  int? _materialPageCacheStart;
  int? _materialPageCacheEnd;
  List<_MaterialTableRow>? _materialPageCache;

  List<_MaterialTableRow> _materialTableRows(
    ProductionMaterialAnalysisView analysis,
  ) {
    final projectionKey = <String>[
      _bomViewMode.name,
      _bomKeyword,
      _bomAggregateByMaterial.toString(),
      (_collapsedBomProducts.toList()..sort()).join(','),
      (_collapsedBomBranches.toList()..sort()).join(','),
      (_expandedMaterialAggregates.toList()..sort()).join(','),
    ].join('|');
    if (identical(_materialRowsCacheAnalysis, analysis) &&
        _materialRowsCacheKey == projectionKey &&
        _materialRowsCache != null) {
      return _materialRowsCache!;
    }
    final rows = _computeMaterialTableRows(analysis);
    _materialRowsCacheAnalysis = analysis;
    _materialRowsCacheKey = projectionKey;
    _materialRowsCache = rows;
    _materialPageCacheSource = null;
    _materialPageCache = null;
    return rows;
  }

  List<_MaterialTableRow> _computeMaterialTableRows(
    ProductionMaterialAnalysisView analysis,
  ) {
    if (_bomAggregateByMaterial) {
      return _aggregateTableRows(analysis);
    }
    final indexes = _analysisIndexes(analysis);
    final projection = _bomFilterProjection(analysis);
    final presentation = projection.presentation;
    final matchingProducts = [
      for (final product in analysis.products)
        if (!_isEmbeddedMakeChildProduct(product) &&
            projection.nodesByProduct[product.analysisLineId]?.isNotEmpty ==
                true)
          product,
    ];
    // A single table pager replaces the legacy "first 30 products + continue"
    // navigator. Stacking both would hide the continue action on a later page.
    final visibleProducts = matchingProducts;
    final result = <_MaterialTableRow>[];
    for (
      var productIndex = 0;
      productIndex < visibleProducts.length;
      productIndex++
    ) {
      final product = visibleProducts[productIndex];
      final visibleNodes = projection.nodesByProduct[product.analysisLineId]!;
      final rootMaterial = _rootSupplyMaterialOf(product);
      final nodes = visibleNodes
          .where((node) => node.materialLineId != rootMaterial?.materialLineId)
          .toList(growable: false);
      result.add(
        _MaterialTableRow(
          kind: _MaterialTableRowKind.product,
          key: 'PRODUCT|${product.analysisLineId}',
          sequence: 'P${productIndex + 1}',
          depth: 0,
          product: product,
          material: rootMaterial,
          group: rootMaterial == null
              ? null
              : indexes.groupsByLine[rootMaterial.materialLineId],
          rootAnalysisLineId: product.analysisLineId,
          hasChildren: nodes.isNotEmpty,
        ),
      );
      if (_collapsedBomProducts.contains(product.analysisLineId)) continue;
      final positions = _materialTreePositions(
        nodes,
        parentIds: presentation.parentIdsByMaterial,
      );
      final parentKeys = {
        for (final node in nodes)
          presentation.parentIdsByMaterial[node.materialLineId],
      };
      for (final material in _orderedBomNodes(
        nodes,
        parentIds: presentation.parentIdsByMaterial,
      )) {
        final group = indexes.groupsByLine[material.materialLineId];
        if (group == null) continue;
        final position = positions[material.materialLineId];
        result.add(
          _MaterialTableRow(
            kind: _MaterialTableRowKind.material,
            key: 'MATERIAL|${material.materialLineId}',
            sequence:
                'P${productIndex + 1}.'
                '${position?.sequence ?? material.level}',
            depth:
                (presentation.depthByMaterial[material.materialLineId] ??
                        material.level)
                    .clamp(1, 99),
            material: material,
            group: group,
            rootAnalysisLineId:
                presentation.rootIdsByMaterial[material.materialLineId],
            parentMaterialLineId:
                presentation.parentIdsByMaterial[material.materialLineId],
            hasChildren: parentKeys.contains(material.materialLineId),
            ancestorContinuations: position?.ancestorContinuations ?? const [],
            isLastChild: position?.isLastChild ?? false,
          ),
        );
      }
    }
    final knownProductIds = analysis.products
        .map((product) => product.analysisLineId)
        .toSet();
    final unassigned = [
      for (final entry in projection.nodesByProduct.entries)
        if (entry.key == null ||
            !knownProductIds.contains(entry.key) ||
            _isEmbeddedMakeChildProduct(indexes.productsById[entry.key]))
          ...entry.value,
    ];
    if (unassigned.isNotEmpty) {
      result.add(
        const _MaterialTableRow(
          kind: _MaterialTableRowKind.orphan,
          key: 'ORPHAN',
          sequence: '!',
          depth: 0,
        ),
      );
      final positions = _materialTreePositions(
        unassigned,
        parentIds: presentation.parentIdsByMaterial,
      );
      final parentKeys = {
        for (final node in unassigned)
          presentation.parentIdsByMaterial[node.materialLineId],
      };
      for (final material in _orderedBomNodes(
        unassigned,
        parentIds: presentation.parentIdsByMaterial,
      )) {
        final group = indexes.groupsByLine[material.materialLineId];
        if (group == null) continue;
        final position = positions[material.materialLineId];
        result.add(
          _MaterialTableRow(
            kind: _MaterialTableRowKind.material,
            key: 'ORPHAN_MATERIAL|${material.materialLineId}',
            sequence: position?.sequence ?? '?',
            depth:
                (presentation.depthByMaterial[material.materialLineId] ??
                        material.level)
                    .clamp(1, 99),
            material: material,
            group: group,
            rootAnalysisLineId:
                presentation.rootIdsByMaterial[material.materialLineId],
            parentMaterialLineId:
                presentation.parentIdsByMaterial[material.materialLineId],
            hasChildren: parentKeys.contains(material.materialLineId),
            ancestorContinuations: position?.ancestorContinuations ?? const [],
            isLastChild: position?.isLastChild ?? false,
          ),
        );
      }
    }
    return result;
  }

  List<_MaterialTableRow> _aggregateTableRows(
    ProductionMaterialAnalysisView analysis,
  ) {
    final indexes = _analysisIndexes(analysis);
    final aggregates = _materialAggregates(analysis, indexes);
    final result = <_MaterialTableRow>[];
    for (
      var aggregateIndex = 0;
      aggregateIndex < aggregates.length;
      aggregateIndex++
    ) {
      final aggregate = aggregates[aggregateIndex];
      final prefix = 'M${aggregateIndex + 1}';
      result.add(
        _MaterialTableRow(
          kind: _MaterialTableRowKind.aggregate,
          key: 'AGGREGATE|${aggregate.key}',
          sequence: prefix,
          depth: 0,
          aggregate: aggregate,
          hasChildren: aggregate.paths.isNotEmpty,
        ),
      );
      if (!_expandedMaterialAggregates.contains(aggregate.key)) continue;
      for (var pathIndex = 0; pathIndex < aggregate.paths.length; pathIndex++) {
        final material = aggregate.paths[pathIndex];
        final group = indexes.groupsByLine[material.materialLineId];
        if (group == null) continue;
        result.add(
          _MaterialTableRow(
            kind: _MaterialTableRowKind.aggregatePath,
            key: 'AGGREGATE_PATH|${material.materialLineId}',
            sequence: '$prefix.${pathIndex + 1}',
            depth: 1,
            material: material,
            group: group,
            isLastChild: pathIndex == aggregate.paths.length - 1,
          ),
        );
      }
    }
    return result;
  }

  /// Stable hierarchical numbers independent of the current branch-collapse
  /// state. Legacy cycles/orphans are appended once and never recurse forever.
  Map<String, _MaterialTreePosition> _materialTreePositions(
    List<ProductionMaterialAnalysisMaterial> nodes, {
    required Map<String, String?> parentIds,
  }) {
    final byId = {for (final node in nodes) node.materialLineId: node};
    final children = <String, List<ProductionMaterialAnalysisMaterial>>{};
    final roots = <ProductionMaterialAnalysisMaterial>[];
    int compare(
      ProductionMaterialAnalysisMaterial left,
      ProductionMaterialAnalysisMaterial right,
    ) => (left.goodsCode ?? left.goodsName ?? left.materialLineId).compareTo(
      right.goodsCode ?? right.goodsName ?? right.materialLineId,
    );
    for (final node in nodes) {
      final parentKey = parentIds[node.materialLineId];
      if (parentKey == null ||
          parentKey.isEmpty ||
          parentKey == node.materialLineId ||
          !byId.containsKey(parentKey)) {
        roots.add(node);
      } else {
        children.putIfAbsent(parentKey, () => []).add(node);
      }
    }
    roots.sort(compare);
    for (final values in children.values) {
      values.sort(compare);
    }
    final result = <String, _MaterialTreePosition>{};
    final visited = <String>{};
    void visit(
      ProductionMaterialAnalysisMaterial node,
      String sequence,
      List<bool> ancestorContinuations,
      bool isLastChild,
    ) {
      if (!visited.add(node.materialLineId)) return;
      result[node.materialLineId] = (
        sequence: sequence,
        ancestorContinuations: List.unmodifiable(ancestorContinuations),
        isLastChild: isLastChild,
      );
      final nodeKey = node.materialLineId;
      final values = children[nodeKey] ?? const [];
      for (var index = 0; index < values.length; index++) {
        visit(values[index], '$sequence.${index + 1}', [
          ...ancestorContinuations,
          !isLastChild,
        ], index == values.length - 1);
      }
    }

    for (var index = 0; index < roots.length; index++) {
      visit(roots[index], '${index + 1}', const [], index == roots.length - 1);
    }
    for (final node in nodes.where(
      (candidate) => !visited.contains(candidate.materialLineId),
    )) {
      visit(node, '?${result.length + 1}', const [], true);
    }
    return result;
  }

  /// A flat pager may start in the middle of a product branch. Repeat the
  /// product and material ancestors as read-only context rows so the first
  /// visible child is never orphaned. Repeated rows have no group/id and are
  /// excluded from selection and business counts.
  List<_MaterialTableRow> _materialTablePageRows(
    List<_MaterialTableRow> rows,
    int start,
    int end,
    int page,
  ) {
    if (rows.isEmpty || start >= end) return const [];
    if (identical(_materialPageCacheSource, rows) &&
        _materialPageCachePage == page &&
        _materialPageCacheStart == start &&
        _materialPageCacheEnd == end &&
        _materialPageCache != null) {
      return _materialPageCache!;
    }
    final slice = rows.sublist(start, end);
    if (start == 0) {
      return _cacheMaterialTablePage(rows, page, start, end, slice);
    }
    final first = slice.first;
    final contextRows = <_MaterialTableRow>[];
    if (first.kind == _MaterialTableRowKind.aggregatePath) {
      for (var index = start - 1; index >= 0; index--) {
        final candidate = rows[index];
        if (candidate.kind == _MaterialTableRowKind.aggregate) {
          contextRows.add(candidate.asPageContext(page));
          break;
        }
      }
    } else if (first.material != null) {
      final analysisLineId =
          first.rootAnalysisLineId ?? first.material!.analysisLineId;
      final hasProductContext = rows.any(
        (candidate) => candidate.product?.analysisLineId == analysisLineId,
      );
      for (var index = start - 1; index >= 0; index--) {
        final candidate = rows[index];
        if (candidate.product?.analysisLineId == analysisLineId ||
            (!hasProductContext &&
                candidate.kind == _MaterialTableRowKind.orphan)) {
          contextRows.add(candidate.asPageContext(page));
          break;
        }
      }
      final byMaterialId = <String, _MaterialTableRow>{
        for (final candidate in rows.take(start))
          if (candidate.material != null)
            candidate.material!.materialLineId: candidate,
      };
      final ancestors = <_MaterialTableRow>[];
      var parentKey = first.parentMaterialLineId;
      final visited = <String>{};
      while (parentKey != null &&
          parentKey.isNotEmpty &&
          visited.add(parentKey)) {
        final parent = byMaterialId[parentKey];
        if (parent == null) break;
        if (parent.kind != _MaterialTableRowKind.product) {
          ancestors.add(parent.asPageContext(page));
        }
        parentKey = parent.parentMaterialLineId;
      }
      contextRows.addAll(ancestors.reversed);
    }
    return _cacheMaterialTablePage(rows, page, start, end, [
      ...contextRows,
      ...slice,
    ]);
  }

  List<_MaterialTableRow> _cacheMaterialTablePage(
    List<_MaterialTableRow> source,
    int page,
    int start,
    int end,
    List<_MaterialTableRow> value,
  ) {
    _materialPageCacheSource = source;
    _materialPageCachePage = page;
    _materialPageCacheStart = start;
    _materialPageCacheEnd = end;
    _materialPageCache = value;
    return value;
  }

  /// 该操作组当前是否可显式「采用公共在途」（行内动作与右键菜单共用）。
  bool _canClaimMaterialSharedFuture(_MaterialGroup group) {
    final analysis = _analysis;
    final material = group.representative;
    final route = material.confirmedRoute;
    final routeEligible =
        route == MaterialSupplyRoute.buy ||
        (route == MaterialSupplyRoute.subcontract &&
            analysis != null &&
            !_hasProductionBomChildren(material, analysis));
    final recommended = group.paths.fold<double>(
      0,
      (sum, path) => sum + path.additionalSupplyRecommendedQty,
    );
    final publicRemaining = group.paths.fold<double>(
      0,
      (max, path) => path.publicSurplusRemainingQty > max
          ? path.publicSurplusRemainingQty
          : max,
    );
    return _canClaimSharedFuture &&
        group.actionable &&
        _planningBlockForGroup(group) == null &&
        group.paths.every(_hasResolvedMaterialSource) &&
        !_dirtyRouteGroups.contains(group.key) &&
        routeEligible &&
        material.actionGroupKey?.isNotEmpty == true &&
        publicRemaining > 0 &&
        recommended > 0;
  }

  /// Canonical route selections are independent of visible rows and pages.
  List<_MaterialGroup> _materialRowGroups(_MaterialTableRow row) {
    if (row.contextOnly ||
        (row.product != null && row.group == null) ||
        _analysis == null) {
      return const [];
    }
    final indexes = _analysisIndexes(_analysis!);
    final paths =
        row.aggregate?.paths ??
        row.group?.paths ??
        const <ProductionMaterialAnalysisMaterial>[];
    final groups = <String, _MaterialGroup>{};
    for (final path in paths) {
      final group = indexes.groupsByLine[path.materialLineId];
      if (group != null && _canEditMaterialRoute(group)) {
        groups[group.key] = group;
      }
    }
    return groups.values.toList(growable: false);
  }

  bool _materialRowSelected(_MaterialTableRow row) {
    if (!_canRoute) return false;
    final groups = _materialRowGroups(row);
    return groups.isNotEmpty &&
        groups.every((group) => _selectedMaterialGroupKeys.contains(group.key));
  }

  void _changeMaterialTableSelection(
    List<_MaterialTableRow> rows,
    Set<String> selected,
  ) {
    if (_busy || !_canRoute) return;
    final additions = <String>{};
    final removals = <String>{};
    for (final row in rows) {
      final wasSelected = _materialRowSelected(row);
      final nowSelected = selected.contains(row.key);
      if (wasSelected == nowSelected) continue;
      final target = nowSelected ? additions : removals;
      target.addAll(_materialRowGroups(row).map((group) => group.key));
    }
    setState(() {
      _selectedMaterialGroupKeys.removeAll(removals);
      _selectedMaterialGroupKeys.addAll(additions);
    });
  }

  Color _materialTableForeground(ThemeData theme, _MaterialTableRow row) =>
      _materialRowSelected(row)
      ? Colors.white
      : theme.brightness == Brightness.light
      ? Colors.black
      : theme.colorScheme.onSurface;

  Widget _materialAnalysisTable(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis, {
    bool primary = true,
  }) {
    final rows = _materialTableRows(analysis);
    final totalPages = rows.isEmpty
        ? 1
        : (rows.length / _materialTablePageSize).ceil();
    final page = _bomTablePageNo.clamp(1, totalPages);
    final start = (page - 1) * _materialTablePageSize;
    final end = (start + _materialTablePageSize).clamp(0, rows.length);
    final pageRows = _materialTablePageRows(rows, start, end, page);
    return KeyedSubtree(
      key: const Key('material-analysis-material-table-region'),
      child: MasterDataTableView<_MaterialTableRow>(
        key: const Key('material-analysis-material-table'),
        columns: _materialTableColumns(theme),
        // 2026-09-05 用户口径：表头上方工具条只留视图切换（缺料/全部 BOM/汇总）；
        // 右下悬浮区只保留「确认路线(N)」，批量选择走表头复选框（按当页）。
        // 2026-09-06 起视图切换按钮改走 toolbarLeadingActions：渲染在「表头设置/
        // 全屏」左簇内紧挨全屏按钮（原先塞右侧贴边动作区，与全屏按钮相距过远
        // 且多按钮间无间距）。
        onFullscreenChanged: (fullscreen) =>
            setState(() => _bomTableFullscreen = fullscreen),
        toolbarLeadingActions: [..._bomToolbarActions(theme, analysis)],
        selectable: true,
        preserveSelectionOnContextMenu: true,
        idOf: (row) =>
            _canRoute && _materialRowGroups(row).isNotEmpty ? row.key : null,
        selectionSummaryCount: _selectedMaterialGroupKeys.length,
        onClearSelection: () {
          if (!_busy) setState(_selectedMaterialGroupKeys.clear);
        },
        selectedIds: {
          ..._selectedMaterialGroupKeys,
          for (final row in rows)
            if (_materialRowSelected(row)) row.key,
        },
        onSelectedIdsChanged: (selected) =>
            _changeMaterialTableSelection(rows, selected),
        batchActionsBuilder: (_, _) => _bottomActionButtons(),
        items: pageRows,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        // 宽屏联动滚动：整页先滚、表格列头顶到页面顶部后表体内滚；横向滚动
        // 条按内容高度定位（行少贴末行下、超高钉在联动区底），与货品资料页
        // 同一套交互。窄屏单滚动区回退为有界高度 + 虚拟滚动。
        primary: primary,
        virtualized: !primary,
        rowKeyOf: (row) => row.key,
        rowWidgetKeyOf: _materialTableRowWidgetKey,
        enableTextSelection: false,
        emptyMessage: _bomAggregateByMaterial
            ? '当前筛选下没有物料，可切换“全部 BOM”或清除查找'
            : '当前条件下没有物料任务，可切换“全部 BOM”或清除查找',
        currentPage: page,
        totalPages: totalPages,
        onPageChange: (next) => setState(() => _bomTablePageNo = next),
        rowColor: (row) {
          if (row.contextOnly) {
            return theme.colorScheme.surfaceContainerHigh.withValues(
              alpha: 0.45,
            );
          }
          if (row.kind == _MaterialTableRowKind.orphan) {
            return theme.colorScheme.errorContainer.withValues(alpha: 0.35);
          }
          if (row.kind == _MaterialTableRowKind.product) {
            return theme.colorScheme.primaryContainer.withValues(alpha: 0.28);
          }
          if ((row.material?.shortageQty ?? row.aggregate?.totalShortage ?? 0) >
              0) {
            return theme.colorScheme.errorContainer.withValues(alpha: 0.18);
          }
          return null;
        },
        onRowTap: _openMaterialTableRow,
        canOpenRow: (row) => !row.contextOnly && row.group != null,
        rowMenuBuilder: _materialTableRowMenu,
        canShowRowMenu: (row) => !row.contextOnly && row.group != null,
      ),
    );
  }

  List<MasterColumnDef<_MaterialTableRow>> _materialTableColumns(
    ThemeData theme,
  ) => [
    MasterColumnDef(
      key: 'treeIdentity',
      label: _bomAggregateByMaterial
          ? _l10n.materialIdentityByMaterial
          : _l10n.materialIdentityByProduct,
      width: 360,
      value: _materialTableIdentityText,
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => _materialTableIdentityCell(theme, row),
    ),
    MasterColumnDef(
      key: 'route',
      label: _l10n.materialRoute,
      width: 132,
      value: _materialTableRouteText,
      info:
          '这批物料怎么准备：采购 = 向供应商买；委外 = 发给加工商加工；'
          '自制 = 自己车间生产。带下层物料的可选路线更多。',
      cellBuilder: (_, row) => _materialTableRouteCell(theme, row),
    ),
    MasterColumnDef(
      key: 'requiredQty',
      label: _l10n.materialRequired,
      width: 100,
      type: 'number',
      info: '按本批产品数量 × 单件用量算出的总需求量。',
      value: (row) => _qty(_materialTableRequiredQty(row)),
    ),
    MasterColumnDef(
      key: 'allocatedAvailableQty',
      label: _l10n.materialAllocated,
      width: 100,
      type: 'number',
      info: _l10n.materialPreparedQuantityHint,
      value: (row) => _qty(_materialTableAllocatedQty(row)),
    ),
    MasterColumnDef(
      key: 'shortageQty',
      label: _l10n.materialShortage,
      width: 100,
      type: 'number',
      info: _l10n.materialPhysicalShortageHint,
      value: (row) => _qty(_materialTableShortageQty(row)),
      cellBuilder: (_, row) => Text(
        // 2026-09-05 顶层同构：缺口列与物料行一致，只显示数字
        //（不再「待生产 X」特例；列头「缺口」已说明含义）。
        _qty(_materialTableShortageQty(row)),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: _materialRowSelected(row)
              ? Colors.white
              : (_materialTableShortageQty(row) ?? 0) > 0
              ? theme.colorScheme.error
              : theme.colorScheme.onSurface,
          fontWeight: FontWeight.w800,
        ),
      ),
      cellColor: (_, row) => (_materialTableShortageQty(row) ?? 0) > 0
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
          : null,
    ),
    MasterColumnDef(
      key: 'additionalSupplyRecommendedQty',
      label: _l10n.materialToSupply,
      width: 138,
      type: 'number',
      info:
          '还缺数量扣除「在途未到」后，建议本次新下单的数量（可改小分批）。'
          '仓库现货已够的行显示 0，仍可按富余量下单。',
      value: (row) => _qty(_materialTableAdditionalRecommendedQty(row)),
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => _materialRowSelected(row)
          ? Text(
              _qty(_materialTableAdditionalRecommendedQty(row)),
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
            )
          : _materialTableSupplyRecommendationCell(theme, row),
    ),
    MasterColumnDef(
      key: 'inboundQty',
      label: _l10n.materialFutureSupply,
      width: 140,
      type: 'number',
      info:
          '已下单采购/委外、还在路上没到货入库的数量；到货并验收合格后自动'
          '补进可用量（已锚定本批，非公共现货）。',
      value: (row) => _qty(_materialTableInboundQty(row)),
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => _materialRowSelected(row)
          ? Text(
              _qty(_materialTableInboundQty(row)),
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
            )
          : _materialTableInboundCell(theme, row),
    ),
    MasterColumnDef(
      key: 'status',
      label: _l10n.materialProgress,
      width: 230,
      info:
          '这行物料现在走到哪一步（等待下单 → 下单 → 财务审批 → 收货 → 检验 → '
          '入库）；点击状态可看全程明细。',
      value: _materialTableStatusText,
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => _materialRowSelected(row)
          ? Text(
              _materialTableStatusText(row) ?? '—',
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
            )
          : _materialTableStatusCell(theme, row),
    ),
  ];

  Key _materialTableRowWidgetKey(_MaterialTableRow row) {
    if (row.contextOnly) return ValueKey(row.key);
    if (row.product != null) {
      return ValueKey('material-bom-product-${row.product!.analysisLineId}');
    }
    if (row.aggregate != null) {
      return ValueKey('material-aggregate-${row.aggregate!.key}');
    }
    final material = row.material;
    if (material != null) {
      return ValueKey('material-table-row-${material.materialLineId}');
    }
    return ValueKey(row.key);
  }

  String? _materialTableIdentityText(_MaterialTableRow row) {
    String? codeOf() => switch (row.kind) {
      _MaterialTableRowKind.product => row.product?.goodsCode,
      _MaterialTableRowKind.aggregate => row.aggregate?.goodsCode,
      _MaterialTableRowKind.material ||
      _MaterialTableRowKind.aggregatePath => row.material?.goodsCode,
      _MaterialTableRowKind.orphan => null,
    };
    final code = codeOf()?.trim();
    final name = switch (row.kind) {
      _MaterialTableRowKind.product =>
        row.product?.goodsName ?? row.product?.goodsCode ?? '未命名产品',
      _MaterialTableRowKind.aggregate =>
        row.aggregate?.goodsName ?? row.aggregate?.goodsCode ?? '未命名物料',
      _MaterialTableRowKind.material || _MaterialTableRowKind.aggregatePath =>
        row.material?.goodsName ?? row.material?.goodsCode ?? '未命名物料',
      _MaterialTableRowKind.orphan => '未归属产品的 BOM 节点',
    };
    return code?.isNotEmpty == true
        ? '${row.sequence} $name $code'
        : '${row.sequence} $name';
  }

  /// 第一列身份格（2026-09-04 收敛）：不再显示 BOM 路径与「组件 N 级」文案，
  /// 统一「P几 + 名字」一行、编号第二行；层级仍由缩进/连接线/级联序号表达。
  Widget _materialTableIdentityCell(ThemeData theme, _MaterialTableRow row) {
    if (row.kind == _MaterialTableRowKind.orphan) {
      return Semantics(
        container: true,
        label: '数据异常，未归属产品的 BOM 节点，请检查分析数据',
        child: ExcludeSemantics(
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
              const SizedBox(width: UtenSpacing.s8),
              const Expanded(child: Text('未归属产品的 BOM 节点，请检查分析数据')),
            ],
          ),
        ),
      );
    }
    final product = row.product;
    final aggregate = row.aggregate;
    final material = row.material;
    VoidCallback? toggle;
    var expanded = false;
    if (product != null) {
      expanded = !_collapsedBomProducts.contains(product.analysisLineId);
      toggle = () {
        _toggleBomProductCollapsed(product.analysisLineId);
        _bomTablePageNo = 1;
      };
    } else if (aggregate != null) {
      expanded = _expandedMaterialAggregates.contains(aggregate.key);
      toggle = () => setState(() {
        if (!_expandedMaterialAggregates.add(aggregate.key)) {
          _expandedMaterialAggregates.remove(aggregate.key);
        }
        _bomTablePageNo = 1;
      });
    } else if (material != null && row.hasChildren) {
      expanded = !_collapsedBomBranches.contains(material.materialLineId);
      toggle = () => setState(() {
        final key = material.materialLineId;
        if (!_collapsedBomBranches.add(key)) {
          _collapsedBomBranches.remove(key);
        }
        _bomTablePageNo = 1;
      });
    }
    final title =
        product?.goodsName ??
        product?.goodsCode ??
        aggregate?.goodsName ??
        aggregate?.goodsCode ??
        material?.goodsName ??
        material?.goodsCode ??
        '未命名物料';
    final code =
        (product?.goodsCode ?? aggregate?.goodsCode ?? material?.goodsCode)
            ?.trim();
    return UtenTreeTableCell(
      key: ValueKey('material-table-tree-${row.key}'),
      toggleKey: ValueKey('material-table-toggle-${row.key}'),
      depth: row.depth,
      sequence: row.sequence,
      sequenceInline: true,
      title: title,
      subtitle: [
        if (code?.isNotEmpty == true) code!,
        if ((product?.colorName ?? aggregate?.colorName ?? material?.colorName)
                ?.isNotEmpty ==
            true)
          (product?.colorName ?? aggregate?.colorName ?? material?.colorName)!,
        if ((material?.unitName ?? product?.unitName ?? aggregate?.unitName)
                ?.isNotEmpty ==
            true)
          (material?.unitName ?? product?.unitName ?? aggregate?.unitName)!,
        if (aggregate != null)
          _l10n.materialAggregateSources(
            aggregate.productCount,
            aggregate.paths.length,
          ),
      ].join(' · '),
      foregroundColor: _materialTableForeground(theme, row),
      hasChildren: row.hasChildren,
      expanded: expanded,
      onToggle: toggle,
      ancestorContinuations: row.ancestorContinuations,
      isLastChild: row.isLastChild,
    );
  }

  MaterialSupplyRoute? _materialDisplayRoute(_MaterialGroup group) {
    final confirmed = group.representative.confirmedRoute;
    if (_routeDraft.containsKey(group.key)) return _routeDraft[group.key];
    if (confirmed != null) return confirmed;
    final issued = group.paths
        .expand((path) => path.notifiedTargets)
        .where((target) => target.status != 'CANCELLED')
        .map((target) => target.target)
        .toSet();
    if (issued.isNotEmpty) return issued.length == 1 ? issued.single : null;
    return _draftRoute(group);
  }

  MaterialSupplyRoute? _materialTableRoute(_MaterialTableRow row) {
    if (row.contextOnly) return null;
    if (row.group != null) return _materialDisplayRoute(row.group!);
    final analysis = _analysis;
    if (analysis == null || row.aggregate == null) return null;
    final indexes = _analysisIndexes(analysis);
    final routes = row.aggregate!.paths.map((path) {
      final group = indexes.groupsByLine[path.materialLineId];
      return group == null
          ? path.confirmedRoute ?? MaterialSupplyRoute.subcontract
          : _materialDisplayRoute(group);
    }).toSet();
    return routes.length == 1 ? routes.single : null;
  }

  String? _materialTableRouteText(_MaterialTableRow row) =>
      _materialTableRoute(row)?.label ??
      (row.aggregate == null && row.group == null
          ? '—'
          : _l10n.materialMixedRoutes);

  Widget _materialTableRouteCell(ThemeData theme, _MaterialTableRow row) {
    final route = _materialTableRoute(row);
    final groups = _materialRowGroups(row);
    final editable = _canRoute && !_busy && groups.isNotEmpty;
    final foreground = _materialTableForeground(theme, row);
    if (!editable) {
      return Text(
        _materialTableRouteText(row) ?? '—',
        style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
      );
    }
    return DropdownButtonHideUnderline(
      child: DropdownButton<MaterialSupplyRoute>(
        key: ValueKey(
          'material-route-dropdown-${row.material?.materialLineId ?? row.key}',
        ),
        value: route,
        isExpanded: true,
        dropdownColor: theme.colorScheme.surface,
        iconEnabledColor: foreground,
        hint: Text(
          _l10n.materialMixedRoutes,
          style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
        ),
        selectedItemBuilder: (_) => [
          for (final option in MaterialSupplyRoute.values)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                option.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
        items: [
          for (final option in MaterialSupplyRoute.values)
            DropdownMenuItem(
              value: option,
              child: Text(
                option.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
        ],
        onChanged: (chosen) {
          if (chosen == null) return;
          setState(() {
            for (final group in groups) {
              _routeDraft[group.key] = chosen;
              if (group.representative.confirmedRoute == chosen) {
                _dirtyRouteGroups.remove(group.key);
              } else {
                _dirtyRouteGroups.add(group.key);
              }
              _selectedMaterialGroupKeys.add(group.key);
            }
            _invalidateBucketRowsCache();
          });
        },
      ),
    );
  }

  double? _materialTableRequiredQty(_MaterialTableRow row) => row.contextOnly
      ? null
      : row.material?.isRootSupply == true
      ? row.material!.requiredQty
      : row.product?.remainingQty ??
            row.aggregate?.totalRequired ??
            row.material?.requiredQty;

  double? _materialTableAllocatedQty(_MaterialTableRow row) => row.contextOnly
      ? null
      : row.aggregate != null
      ? row.aggregate!.paths.fold<double>(
          0,
          (sum, material) => sum + material.allocatedAvailableQty,
        )
      : row.material?.allocatedAvailableQty;

  double? _materialTableExactQty(_MaterialTableRow row) => row.contextOnly
      ? null
      : row.aggregate != null
      ? row.aggregate!.paths.fold<double>(
          0,
          (sum, material) => sum + material.exactPeggedQty,
        )
      : row.material?.exactPeggedQty;

  String? _materialTablePublicAvailableQty(_MaterialTableRow row) {
    if (row.contextOnly) return '—';
    final material = row.material ?? row.aggregate?.representative;
    if (material == null) return '—';
    // The main-warehouse budget is authoritative; per-leaf or pre-allocation
    // figures cannot be relabelled as this group's unassigned public stock.
    return _qty(material.mainWarehousePublicAvailableQty);
  }

  double? _materialTableInboundQty(_MaterialTableRow row) => row.contextOnly
      ? null
      // 根供料的预计供给包含尚未合格入库的车间计划量。
      : row.product != null && row.material?.isRootSupply != true
      ? null
      : row.aggregate != null
      ? (() {
          final values = row.aggregate!.paths
              .map((material) => material.inboundQty)
              .toSet();
          return values.length == 1 ? values.single : null;
        })()
      : row.material?.inboundQty;

  Widget _materialTableInboundCell(ThemeData theme, _MaterialTableRow row) {
    if (row.contextOnly) return const Text('—');
    if (row.product != null && row.material?.isRootSupply != true) {
      return const Text('—');
    }
    final value = _materialTableInboundQty(row);
    if (row.aggregate != null && value == null) {
      return Text(
        '各路径按期供给不同，展开逐条查看',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final label = '${_qty(value)}（已锚定，非现货）';
    const explanation = '已锚定预计供给，非现货，入库并质检合格前不进入当前可开工量';
    return Tooltip(
      message: explanation,
      child: Semantics(
        container: true,
        label: '$label，$explanation',
        child: ExcludeSemantics(
          child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }

  double? _materialTablePublicSurplusRemainingQty(_MaterialTableRow row) =>
      row.contextOnly || row.product != null
      ? null
      : row.aggregate != null
      ? (() {
          final values = row.aggregate!.paths
              .map((material) => material.publicSurplusRemainingQty)
              .toSet();
          final dates = row.aggregate!.paths
              .map((material) => material.publicSurplusExpectedDate ?? '')
              .toSet();
          final routes = row.aggregate!.paths
              .map((material) => material.confirmedRoute?.wireName ?? '')
              .toSet();
          return values.length == 1 &&
                  dates.length == 1 &&
                  routes.length == 1 &&
                  !routes.contains('')
              ? values.single
              : null;
        })()
      : row.material?.publicSurplusRemainingQty;

  double? _materialTableSharedFutureClaimedQty(_MaterialTableRow row) =>
      row.contextOnly || row.product != null
      ? null
      : row.aggregate != null
      ? row.aggregate!.paths.fold<double>(
          0,
          (sum, material) => sum + material.sharedFutureClaimedQty,
        )
      : row.material?.sharedFutureClaimedQty;

  double? _materialTableAdditionalRecommendedQty(_MaterialTableRow row) =>
      row.contextOnly
      ? null
      // 顶层直购/直委外产品行（ROOT_SUPPLY 外部路线）沿用根供料行的建议量
      //（2026-09-06 用户口径：顶层待补数量不再显示「—」）；顶层自制产品
      // 的补货走「下达车间」，不在此列。
      : row.product != null && !_rootExternalSupplyRow(row)
      ? null
      : row.aggregate != null
      ? row.aggregate!.paths.fold<double>(
          0,
          (sum, material) => sum + material.additionalSupplyRecommendedQty,
        )
      : row.material?.additionalSupplyRecommendedQty;

  Widget _materialTableSupplyRecommendationCell(
    ThemeData theme,
    _MaterialTableRow row,
  ) {
    if (row.contextOnly) return const Text('—');
    // 顶层自制产品无采购/委外建议量；直购/直委外顶层行继续展示根供料建议量。
    if (row.product != null && !_rootExternalSupplyRow(row)) {
      return const Text('—');
    }
    final recommended = _materialTableAdditionalRecommendedQty(row) ?? 0;
    return Tooltip(
      message: '主仓汇总后，当前还需补充 ${_qty(recommended)}。',
      child: Text(_qty(recommended), style: theme.textTheme.bodySmall),
    );
  }

  Widget _materialTableSharedFutureCell(
    ThemeData theme,
    _MaterialTableRow row,
  ) {
    if (row.contextOnly || row.product != null) return const Text('—');
    final remainingValue = _materialTablePublicSurplusRemainingQty(row);
    if (row.aggregate != null && remainingValue == null) {
      return Text(
        '各路径路线、可采用量或日期不同，展开逐条处理',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final remaining = remainingValue ?? 0;
    final claimed = _materialTableSharedFutureClaimedQty(row) ?? 0;
    final recommended = _materialTableAdditionalRecommendedQty(row) ?? 0;
    final material = row.material ?? row.aggregate?.representative;
    final expectedDate = material?.publicSurplusExpectedDate;
    final refs = row.aggregate == null
        ? material?.sharedFutureSupplyRefs ?? const <SharedFutureSupplyRef>[]
        : row.aggregate!.paths
              .expand((path) => path.sharedFutureSupplyRefs)
              .toList(growable: false);
    final aggregateRefsProtected =
        row.aggregate != null &&
        refs.any((ref) => ref.sourceActionId?.isNotEmpty != true);
    final displayRefs = <SharedFutureSupplyRef>[];
    if (!aggregateRefsProtected) {
      final seen = <String>{};
      for (final ref in refs) {
        final key = ref.sourceActionId;
        if (key == null || seen.add(key)) displayRefs.add(ref);
      }
    } else if (row.aggregate == null) {
      displayRefs.addAll(refs);
    }
    final currentPublic = displayRefs
        .where((ref) => ref.sourceIsCurrentAnalysis)
        .fold<double>(0, (sum, ref) => sum + ref.availableToClaimQty);
    final otherPublic = displayRefs
        .where((ref) => !ref.sourceIsCurrentAnalysis)
        .fold<double>(0, (sum, ref) => sum + ref.availableToClaimQty);
    final approvedTotal = row.aggregate == null
        ? material?.publicSurplusApprovedInboundQty
        : row.aggregate!.paths
              .map((path) => path.publicSurplusApprovedInboundQty)
              .fold<double>(0, (max, value) => value > max ? value : max);
    final message = recommended <= 0
        ? claimed > 0
              ? '已采用 ${_qty(claimed)}；公共在途余量 ${_qty(remaining)}；本节点无需另补'
              : currentPublic > 0
              ? '本分析公共备货 ${_qty(currentPublic)}，可供后续分析采用；本节点无需另补'
              : otherPublic > 0
              ? '其它分析公共在途 ${_qty(otherPublic)}；本节点当前无需采用或另补'
              : (approvedTotal ?? 0) > 0
              ? '已批准公共在途候选 ${_qty(approvedTotal)}；本节点当前无需采用或另补'
              : remaining > 0
              ? '公共在途余量 ${_qty(remaining)}，可供后续分析采用；本节点无需另补'
              : '本节点当前无需采用或另补'
        : remaining >= recommended
        ? '可覆盖 ${_qty(recommended)}；采用后公共预计剩 '
              '${_qty(remaining - recommended)}'
        : remaining > 0
        ? '可采用 ${_qty(remaining)}；采用后仍需另补 '
              '${_qty(recommended - remaining)}'
        : '暂无公共在途可采用；当前建议另补 ${_qty(recommended)}';
    final sourceSummary = refs.isEmpty
        ? null
        : aggregateRefsProtected
        ? '共 ${row.aggregate!.paths.length} 条路径；来源明细请展开查看（来源单号受权限保护）'
        : displayRefs
              .map(
                (ref) =>
                    '${ref.sourceIsCurrentAnalysis ? '本分析来源' : '其它分析来源'} / '
                    '${ref.route?.label ?? '供给'} '
                    '批准 ${_qty(ref.approvedInboundQty)} / '
                    '可采用 ${_qty(ref.availableToClaimQty)} / '
                    '${ref.expectedDate ?? '日期待定'} / '
                    '${ref.documentNo?.trim().isNotEmpty == true ? ref.documentNo! : '来源单号受权限保护'}',
              )
              .join('；');
    final detail = [
      message,
      if ((approvedTotal ?? 0) > 0) '批准公共候选总量 ${_qty(approvedTotal)}',
      if (expectedDate?.isNotEmpty == true) '预计 $expectedDate',
      ?sourceSummary,
    ].join('；');
    return Tooltip(
      message: detail,
      child: Semantics(
        container: true,
        label: detail,
        child: ExcludeSemantics(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: remaining > 0
                  ? theme.colorScheme.secondary
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: remaining > 0 ? FontWeight.w700 : null,
            ),
          ),
        ),
      ),
    );
  }

  double? _materialTableShortageQty(_MaterialTableRow row) => row.contextOnly
      ? null
      : row.aggregate?.totalShortage ?? row.material?.shortageQty;

  String _materialProductStatus(ProductionMaterialAnalysisProduct product) {
    if (!_canSelectProduct(product)) {
      return _rootRouteScheduleHint(product) ??
          product.scheduleBlockedReason ??
          _l10n.materialTaskBlocked;
    }
    // 2026-09-06 词表：未下达产品显示「等待下达车间」，不区分下层齐不齐
    // ——计划只管下发任务，物料齐不齐由车间执行段 WAITING→READY 自动判断；
    // 齐套数量仍在本表「齐套缺口/现货分配」列如实施示。
    return '等待下达车间';
  }

  bool _rootExternalSupplyRow(_MaterialTableRow row) =>
      row.material?.isRootSupply == true &&
      row.material?.confirmedRoute != null &&
      row.material?.confirmedRoute != MaterialSupplyRoute.make;

  String? _materialTableStatusText(_MaterialTableRow row) {
    if (row.contextOnly) return '上级路径上下文（只读）';
    final block = row.group == null
        ? _analysis?.planningBlockedReason(
            row.product?.analysisLineId ?? row.material?.analysisLineId ?? '',
          )
        : _planningBlockForGroup(row.group!);
    if (block != null) return block;
    if (_rootExternalSupplyRow(row) && (row.product?.remainingQty ?? 1) <= 0) {
      return _l10n.materialRootSupplyCompleted;
    }
    if (row.product != null && !_rootExternalSupplyRow(row)) {
      return _productExecutionStage(row.product!)?.displayLabel ??
          _materialProductStatus(row.product!);
    }
    if (row.aggregate != null) {
      return '合格库存保障 ${_qty(row.aggregate!.qualifiedCoveredQty)}/'
          '${_qty(row.aggregate!.totalRequired)}';
    }
    final group = row.group;
    return group == null
        ? null
        : _materialStatus(Theme.of(context), group).label;
  }

  Widget _materialTableStatusCell(ThemeData theme, _MaterialTableRow row) {
    final planningBlock = row.group == null
        ? _analysis?.planningBlockedReason(
            row.product?.analysisLineId ?? row.material?.analysisLineId ?? '',
          )
        : _planningBlockForGroup(row.group!);
    if (!row.contextOnly && planningBlock != null) {
      return _statusLabel(
        theme,
        _StatusView(
          planningBlock,
          Icons.info_outline_rounded,
          theme.colorScheme.tertiary,
        ),
      );
    }
    if (row.contextOnly) {
      return Text(
        '上级路径上下文（只读）',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    if (_rootExternalSupplyRow(row) && (row.product?.remainingQty ?? 1) <= 0) {
      return _statusLabel(
        theme,
        _StatusView(
          _l10n.materialRootSupplyCompleted,
          Icons.check_circle_outline_rounded,
          theme.colorScheme.primary,
        ),
      );
    }
    if (row.product != null && !_rootExternalSupplyRow(row)) {
      final stage = _productExecutionStage(row.product!);
      return _statusLabel(
        theme,
        stage == null
            ? _StatusView(
                _materialProductStatus(row.product!),
                _canSelectProduct(row.product!)
                    ? Icons.play_circle_outline_rounded
                    : Icons.do_not_disturb_on_outlined,
                _canSelectProduct(row.product!)
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              )
            : _StatusView(
                stage.label,
                stage.icon,
                _productExecutionColor(theme, stage),
              ),
      );
    }
    if (row.aggregate != null) {
      final aggregate = row.aggregate!;
      final ratio = aggregate.coverageRatio;
      final color = aggregate.totalDemandSupplyGap <= 0
          ? theme.colorScheme.primary
          : ratio <= 0
          ? theme.colorScheme.error
          : theme.colorScheme.tertiary;
      return Semantics(
        container: true,
        label:
            '合格库存保障 ${_qty(aggregate.qualifiedCoveredQty)}/${_qty(aggregate.totalRequired)}，百分之 ${(ratio * 100).toStringAsFixed(0)}',
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '保障 ${_qty(aggregate.qualifiedCoveredQty)}/'
                '${_qty(aggregate.totalRequired)} '
                '(${(ratio * 100).toStringAsFixed(0)}%)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                color: color,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ],
          ),
        ),
      );
    }
    final group = row.group;
    if (group == null) {
      // 产品行（顶层）：路线待确认与物料行同款红色徽章，其余保持纯文本。
      final product = row.product;
      if (product != null && _rootRoutePending(product)) {
        return _statusLabel(
          theme,
          _StatusView(
            _l10n.materialRootRoutePending,
            Icons.help_outline_rounded,
            theme.colorScheme.error,
          ),
        );
      }
      return Text(_materialTableStatusText(row) ?? '—');
    }
    final status = _materialStatus(theme, group);
    Widget result = _statusLabel(theme, status);
    if (_notifiedTargetOf(group.representative) != null) {
      result = InkWell(
        key: ValueKey(
          'material-table-supply-progress-${group.representative.materialLineId}',
        ),
        onTap: _busy ? null : () => _showSupplyProgress(group),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
            child: Align(alignment: Alignment.centerLeft, child: result),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [result, _borrowBadges(theme, group.representative)],
    );
  }

  List<UtenContextMenuEntry> _materialTableRowMenu(_MaterialTableRow row) {
    final group = row.group;
    if (group == null) return const [];
    if (!group.paths.every(_hasResolvedMaterialSource)) {
      return [
        UtenMenuItem(
          label: '查看物料详情',
          icon: Icons.info_outline_rounded,
          onTap: () => _showMaterialTableDetails(group),
        ),
      ];
    }
    if (row.product != null &&
        row.material?.isRootSupply == true &&
        _materialDisplayRoute(group) == MaterialSupplyRoute.make) {
      return [
        UtenMenuItem(
          label: '查看物料详情',
          icon: Icons.info_outline_rounded,
          onTap: () => _showMaterialTableDetails(group),
        ),
        if (_canGenerate)
          UtenMenuItem(
            label: _l10n.materialTaskWorkshop,
            icon: Icons.factory_outlined,
            enabled: !_busy && _canSelectProduct(row.product!),
            onTap: () async {
              if (_busy || !_canSelectProduct(row.product!)) return;
              setState(
                () => _selectedPlanLineIds.add(row.product!.analysisLineId),
              );
              await _openBucketDetail(_AnalysisBucket.workshop);
            },
          ),
      ];
    }
    final route = _materialDisplayRoute(group);
    // 2026-09-05 简化（ADR-71 后续）：自制路线退役「创建子件任务」行入口——
    // 统一走「下达车间」桶的「创建生产计划」单次原子下达。
    if (route == MaterialSupplyRoute.make) {
      return [
        UtenMenuItem(
          label: '查看物料详情',
          icon: Icons.info_outline_rounded,
          onTap: () => _showMaterialTableDetails(group),
        ),
        const UtenMenuDivider(),
        UtenMenuItem(
          label: '采用公共在途',
          icon: Icons.call_received_rounded,
          enabled: !_busy && _canClaimMaterialSharedFuture(group),
          onTap: () => _claimSharedFuture({group.key}),
        ),
      ];
    }
    final executable =
        route != null && _canNotify && _isExecutableSupplyGroup(group, route);
    final actionLabel = switch (route) {
      MaterialSupplyRoute.buy => '提交采购需求',
      MaterialSupplyRoute.subcontract => '创建委外子件任务',
      MaterialSupplyRoute.make => '执行当前任务',
      null => '执行当前任务',
    };
    return [
      UtenMenuItem(
        label: '查看物料详情',
        icon: Icons.info_outline_rounded,
        onTap: () => _showMaterialTableDetails(group),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: '采用公共在途',
        icon: Icons.call_received_rounded,
        enabled: !_busy && _canClaimMaterialSharedFuture(group),
        onTap: () => _claimSharedFuture({group.key}),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: actionLabel,
        icon: route == MaterialSupplyRoute.subcontract
            ? Icons.factory_outlined
            : Icons.notifications_active_outlined,
        enabled: !_busy && executable,
        onTap: () async {
          if (!executable) return;
          switch (route) {
            case MaterialSupplyRoute.buy:
              await _notifyRoute(route, onlyGroupKeys: {group.key});
            case MaterialSupplyRoute.subcontract:
              await _arrangeSubcontractProduction(onlyGroupKeys: {group.key});
            case MaterialSupplyRoute.make:
              break;
          }
        },
      ),
    ];
  }

  Future<void> _openMaterialTableRow(_MaterialTableRow row) async {
    final group = row.group;
    if (group != null) {
      await _showMaterialTableDetails(group);
      return;
    }
  }

  Future<void> _showMaterialTableDetails(
    _MaterialGroup group,
  ) => showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final material = group.representative;
      final row = _MaterialTableRow(
        kind: _MaterialTableRowKind.material,
        key: group.key,
        sequence: '',
        depth: 0,
        material: material,
        group: group,
      );
      return AlertDialog(
        title: Text(material.goodsName ?? material.goodsCode ?? '物料详情'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _nodeDetails(theme, group),
                if (material.notifiedTargets.any(
                  (target) => target.isRootOutput,
                ))
                  _rootOutputHistory(dialogContext, material),
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  _l10n.materialWarehouseFacts,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: UtenSpacing.s16,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    Text(
                      '${_l10n.materialExactStock}: ${_qty(_materialTableExactQty(row))}',
                    ),
                    Text(
                      '${_l10n.materialPublicStock}: ${_materialTablePublicAvailableQty(row)}',
                    ),
                    Text(
                      '${_l10n.materialClaimedSupply}: ${_qty(_materialTableSharedFutureClaimedQty(row))}',
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s8),
                _materialTableSharedFutureCell(theme, row),
                if (material.sharedFutureSupplyRefs.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  _sharedFutureSourcesPanel(theme, material),
                ],
                if (material.notifiedTargets.any(
                  (target) =>
                      target.actionId?.trim().isNotEmpty == true &&
                      target.status?.toUpperCase() != 'CANCELLED' &&
                      target.status?.toUpperCase() != 'DONE',
                )) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  _cancellableActionsPanel(dialogContext, theme, material),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );

  bool get _canRevokeRootOutput =>
      _permissions.contains(Perm.productionMaterialAnalysisView) &&
      _permissions.contains(Perm.productionMaterialAnalysisNotify) &&
      _serverAllows('ROOT_OUTPUT_REVOKE');

  Widget _rootOutputHistory(
    BuildContext dialogContext,
    ProductionMaterialAnalysisMaterial material,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: UtenSpacing.s12),
      Text(
        _l10n.materialRootOutputHistory,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      for (final output in material.notifiedTargets.where(
        (target) => target.isRootOutput,
      ))
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            output.documentType == 'ROOT_STOCK_ALLOCATION'
                ? _l10n.materialRootStockAllocation
                : _l10n.materialRootReceivedSupply,
          ),
          subtitle: Text(
            '${_qty(output.allocatedQty)} ${material.unitName ?? ''} · ${output.isReversedRootOutput ? _l10n.materialRootOutputReversed : _l10n.materialRootSupplyCompleted}',
          ),
          trailing:
              _canRevokeRootOutput &&
                  output.documentType == 'ROOT_STOCK_ALLOCATION' &&
                  output.status == 'COMPLETED' &&
                  output.documentId != null
              ? UtenButton(
                  key: ValueKey(
                    'material-root-output-revoke-${output.documentId}',
                  ),
                  type: UtenButtonType.ghost,
                  onPressed: _busy
                      ? null
                      : () async {
                          if (await _revokeRootOutput(output.documentId!) &&
                              dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                        },
                  child: Text(_l10n.materialRevokeRootStock),
                )
              : null,
        ),
    ],
  );

  Future<bool> _revokeRootOutput(String eventId) async {
    final analysis = _analysis;
    if (analysis == null || !_canRevokeRootOutput || _busy) return false;
    final reason = await _promptCancellationReason(
      _l10n.materialRevokeRootStock,
    );
    if (!mounted || reason == null) return false;
    final key = businessIdempotencyKey(
      'material-root-output-revoke',
      '${analysis.analysisId}|$eventId|${analysis.version}|${analysis.fingerprint}|$reason',
    );
    setState(() => _cancellingAction = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .revokeMaterialRootStockOutput(
            analysis: analysis,
            eventId: eventId,
            idempotencyKey: key,
            reason: reason,
          );
      if (!mounted) return false;
      setState(() {
        _cancellingAction = false;
        _applyAnalysis(view);
      });
      context.appSuccess(_l10n.materialRootOutputReversed);
      return true;
    } catch (error) {
      if (!mounted) return false;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: _l10n.materialRevokeRootStock,
      )) {
        if (mounted) setState(() => _cancellingAction = false);
        return false;
      }
      if (!mounted) return false;
      setState(() => _cancellingAction = false);
      context.appError(
        productionErrorMessage(error, fallback: _l10n.materialRootRevokeFailed),
      );
      return false;
    }
  }

  Widget _sharedFutureSourcesPanel(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
  ) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '公共在途来源',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        for (final ref in material.sharedFutureSupplyRefs)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Text(
              '${ref.sourceIsCurrentAnalysis ? '本分析来源' : '其它分析来源'} · '
              '${ref.route?.label ?? '供给路线待定'} · '
              '批准在途 ${_qty(ref.approvedInboundQty)} · '
              '尚可采用 ${_qty(ref.availableToClaimQty)} · '
              '预计 ${ref.expectedDate ?? '日期待定'} · '
              '${ref.documentNo?.trim().isNotEmpty == true ? ref.documentNo! : '来源单号受权限保护'}',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    ),
  );

  Widget _cancellableActionsPanel(
    BuildContext dialogContext,
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
  ) {
    final targets = material.notifiedTargets
        .where(
          (target) =>
              target.actionId?.trim().isNotEmpty == true &&
              (target.status?.toUpperCase() != 'CANCELLED' ||
                  target.notificationReversalPending) &&
              (target.status?.toUpperCase() != 'DONE' ||
                  target.documentType == 'SUBCONTRACT_MAKE_TASK' ||
                  target.documentType == 'SUBCONTRACT_APPLICATION'),
        )
        .toList(growable: false);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            AppLocalizations.of(dialogContext).materialSupplyTasksAndReversals,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          for (final target in targets)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${target.target?.label ?? '供给'} · '
                    '${target.status ?? '状态待回传'} · '
                    '分配 ${_qty(target.allocatedQty)} · '
                    '${target.documentNo?.trim().isNotEmpty == true ? target.documentNo! : '来源单号受权限保护'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (_canCancelAction)
                  TextButton.icon(
                    key: ValueKey(
                      'material-table-cancel-action-${target.actionId}',
                    ),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: _cancellingAction
                        ? null
                        : () async {
                            final cancelled = await _cancelMaterialAction(
                              target.actionId!,
                            );
                            if (cancelled && dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                          },
                    icon: const Icon(Icons.undo_rounded),
                    label: Text(
                      target.notificationReversalPending
                          ? AppLocalizations.of(
                              dialogContext,
                            ).materialNotificationReversalReconcile
                          : '撤回',
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _claimSharedFuture(Set<String> groupKeys) async {
    final analysis = _analysis;
    if (analysis == null || !_canClaimSharedFuture || _busy) return;
    final eligibleGroups =
        _materialGroups(analysis)
            .where(
              (group) =>
                  groupKeys.contains(group.key) &&
                  _canClaimMaterialSharedFuture(group),
            )
            .toList(growable: false)
          ..sort(
            (left, right) => (left.representative.actionGroupKey ?? left.key)
                .compareTo(right.representative.actionGroupKey ?? right.key),
          );
    final eligible =
        eligibleGroups
            .map((group) => group.representative.actionGroupKey)
            .whereType<String>()
            .toSet()
            .toList()
          ..sort();
    if (eligible.isEmpty) {
      context.appInfo('所选物料当前没有可采用的公共在途，请刷新后重试');
      return;
    }
    final confirmed = await _confirmSharedFutureClaim(eligibleGroups);
    if (confirmed != true || !mounted) return;
    final chunks = _chunked(eligible);
    var current = analysis;
    var completed = 0;
    setState(() {
      _claimingSharedFuture = true;
      _bulkOperationLabel = '正在采用公共在途';
      _bulkOperationCompleted = 0;
      _bulkOperationTotal = eligible.length;
    });
    try {
      for (final chunk in chunks) {
        final idempotencyKey = businessIdempotencyKey(
          'material-analysis-claim-shared-future',
          '${current.analysisId}|${current.version}|${current.fingerprint}|'
              '${chunk.join(',')}',
        );
        current = await ref
            .read(productionPlanRepositoryProvider)
            .claimSharedFutureSupply(
              analysis: current,
              idempotencyKey: idempotencyKey,
              actionGroupKeys: chunk,
            );
        completed += chunk.length;
        if (mounted) setState(() => _bulkOperationCompleted = completed);
      }
      if (!mounted) return;
      setState(() {
        _claimingSharedFuture = false;
        _clearBulkOperation();
        _applyAnalysis(current);
      });
      context.appSuccess('已采用公共在途，分析已按权威供给重新计算');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _claimingSharedFuture = false;
        _clearBulkOperation();
        if (!identical(current, analysis)) _applyAnalysis(current);
      });
      if (completed == 0) {
        if (await _recoverLatestAnalysisAfterConflict(
          error,
          operation: '采用公共在途',
        )) {
          return;
        }
      }
      if (!mounted) return;
      context.appError(
        completed > 0
            ? '已采用 $completed/${eligible.length} 项；余下项目未执行，请按最新结果重新选择。'
            : productionErrorMessage(error, fallback: '采用失败，请刷新后重新选择'),
        force: true,
      );
    }
  }

  Future<bool?> _confirmSharedFutureClaim(List<_MaterialGroup> groups) {
    final totalsByUnit = <String, double>{};
    final entries =
        <({String label, String unit, double take, double after})>[];
    final remainingByPool = <String, double>{};
    for (final group in groups) {
      final material = group.representative;
      final poolKey = [
        _analysis?.warehouseId,
        material.goodsId,
        material.colorId,
        material.unitId,
        material.confirmedRoute?.wireName,
      ].whereType<String>().join('|');
      final available = group.paths.fold<double>(
        0,
        (max, path) => path.publicSurplusRemainingQty > max
            ? path.publicSurplusRemainingQty
            : max,
      );
      remainingByPool.update(
        poolKey,
        (current) => available > current ? available : current,
        ifAbsent: () => available,
      );
    }
    for (final group in groups) {
      final material = group.representative;
      final poolKey = [
        _analysis?.warehouseId,
        material.goodsId,
        material.colorId,
        material.unitId,
        material.confirmedRoute?.wireName,
      ].whereType<String>().join('|');
      final recommended = group.paths.fold<double>(
        0,
        (sum, path) => sum + path.additionalSupplyRecommendedQty,
      );
      final publicRemaining = remainingByPool[poolKey] ?? 0;
      final take = publicRemaining < recommended
          ? publicRemaining
          : recommended;
      final after = publicRemaining - take;
      remainingByPool[poolKey] = after;
      final unit = material.unitName?.trim().isNotEmpty == true
          ? material.unitName!
          : '未标单位';
      totalsByUnit.update(unit, (value) => value + take, ifAbsent: () => take);
      entries.add((
        label: material.goodsName ?? material.goodsCode ?? '未命名物料',
        unit: unit,
        take: take,
        after: after,
      ));
    }
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('确认采用公共在途（${groups.length} 项）'),
        content: SizedBox(
          width: 640,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '采用后会把跨分析未来供给认领给本分析的节点需求；不会新建或修改来源采购/委外单。'
                '实际入库并质检合格前不算现货或当前可开工。'
                '同 SKU 多条路径共享同一个公共在途池，下表已按稳定任务顺序逐条扣减，不会重复显示同一份余量。',
              ),
              const SizedBox(height: UtenSpacing.s12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final entry = entries[index];
                    return ListTile(
                      title: Text(entry.label),
                      subtitle: Text(
                        '建议采用 ${_qty(entry.take)} ${entry.unit}；'
                        '采用后公共预计剩 ${_qty(entry.after)} ${entry.unit}',
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '本次合计：${totalsByUnit.entries.map((entry) => '${_qty(entry.value)} ${entry.key}').join('；')}',
                style: Theme.of(
                  dialogContext,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('返回检查'),
          ),
          FilledButton.icon(
            key: const Key('material-table-confirm-claim-shared'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.call_received_rounded),
            label: const Text('确认采用'),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptCancellationReason(String title) => showDialog<String>(
    context: context,
    builder: (_) => MaterialRequiredReasonDialog(
      title: title,
      fieldKey: const Key('material-analysis-cancel-reason'),
      initialValue: '',
      info: '原因会写入审计记录；取消后不得把已发生的仓库或执行事实静默抹除。',
      confirmLabel: '确认取消',
    ),
  );

  Future<void> _cancelCurrentAnalysis() async {
    final analysis = _analysis;
    if (analysis == null || !_canCancelAnalysis || _busy) return;
    final reason = await _promptCancellationReason('取消物料分析');
    if (reason == null || !mounted) return;
    final idempotencyKey = businessIdempotencyKey(
      'material-analysis-cancel',
      '${analysis.analysisId}|${analysis.version}|${analysis.fingerprint}|$reason',
    );
    setState(() => _cancellingAnalysis = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .cancelMaterialAnalysis(
            analysis: analysis,
            idempotencyKey: idempotencyKey,
            reason: reason,
          );
      if (!mounted) return;
      setState(() {
        _cancellingAnalysis = false;
        _applyAnalysis(view);
      });
      context.appSuccess('物料分析已取消');
    } catch (error) {
      if (!mounted) return;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '取消物料分析',
      )) {
        if (mounted) setState(() => _cancellingAnalysis = false);
        return;
      }
      if (!mounted) return;
      setState(() => _cancellingAnalysis = false);
      context.appError(
        productionErrorMessage(error, fallback: '取消分析失败，请刷新后重试'),
        force: true,
      );
    }
  }

  Future<bool> _cancelMaterialAction(String actionId) async {
    final analysis = _analysis;
    if (analysis == null || !_canCancelAction || _busy) return false;
    final reason = await _promptCancellationReason('撤回供给任务');
    if (reason == null || !mounted) return false;
    final idempotencyKey = businessIdempotencyKey(
      'material-analysis-cancel-action',
      '${analysis.analysisId}|$actionId|${analysis.version}|${analysis.fingerprint}|$reason',
    );
    setState(() => _cancellingAction = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .cancelMaterialSupplyAction(
            analysis: analysis,
            actionId: actionId,
            idempotencyKey: idempotencyKey,
            reason: reason,
          );
      if (!mounted) return false;
      setState(() {
        _cancellingAction = false;
        _applyAnalysis(view);
      });
      context.appSuccess('供给任务已撤回，分析已按最新事实重算');
      return true;
    } catch (error) {
      if (!mounted) return false;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '撤回供给任务',
      )) {
        if (mounted) setState(() => _cancellingAction = false);
        return false;
      }
      if (!mounted) return false;
      setState(() => _cancellingAction = false);
      context.appError(
        productionErrorMessage(error, fallback: '撤回任务失败，请刷新后重试'),
        force: true,
      );
      return false;
    }
  }
}
