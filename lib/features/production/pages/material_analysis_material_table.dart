part of 'production_material_analysis_page.dart';

enum _MaterialTableRowKind {
  product,
  material,
  aggregate,
  aggregatePath,
  orphan,
}

/// 实际备料的三个动态数：备料需求 / 本次要覆盖的量(毛) / 还缺数量(净)。
/// 来源按优先级：页面当场换算的估算值 → 服务端模拟快照 → 权威快照。
typedef _TableQty = ({double required, double residual, double net});

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
    this.childCount,
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

  /// 层级连线用的祖先链与末位标记。**由 `utenTreeProjection` 按最终渲染序
  /// 统一推导**（[_withTree]），不要在本文件里另建一棵树再 DFS 一遍——
  /// 2026-09-15 之前这里是自建的「深度 − 1 相对」口径，与画笔差一级，
  /// 末位子件的竖线永远不收口，而级联页同一棵料却画得对。
  final List<bool> ancestorContinuations;
  final bool isLastChild;

  /// 只读上下文：表头筛选未命中、仅因子孙命中而保留的祖先。无勾选/下拉/
  /// 行菜单，不计入业务数量。
  final bool contextOnly;
  final String? rootAnalysisLineId;
  final String? parentMaterialLineId;

  /// 当前投影下的可见直接子件数（树形格「N」徽章）；「只看缺料」等视图下是
  /// 可见子件数而非 BOM 全量。
  final int? childCount;

  bool get isAggregateSource => kind == _MaterialTableRowKind.aggregatePath;

  /// 套上共享树投影的连线信息。[hasChildren] / [childCount] **不由投影接管**：
  /// 折叠起来的分支在渲染序里没有子行，但展开箭头与「N」徽章必须照旧显示，
  /// 这两个值仍按全量子件数算。
  _MaterialTableRow _withTree(UtenTreeRowProjection tree) => _MaterialTableRow(
    kind: kind,
    key: key,
    sequence: sequence,
    depth: depth,
    product: product,
    material: material,
    group: group,
    aggregate: aggregate,
    hasChildren: hasChildren,
    ancestorContinuations: tree.ancestorContinuations,
    isLastChild: tree.isLastChild,
    contextOnly: contextOnly,
    rootAnalysisLineId: rootAnalysisLineId,
    parentMaterialLineId: parentMaterialLineId,
    childCount: childCount,
  );
}

/// Excel-style material table layered on top of the existing authoritative
/// analysis projection. It deliberately reuses the route, gate, progress,
/// borrow/reallocation and write orchestration methods from the host state;
/// this file owns presentation only and never recalculates inventory facts.
abstract class _MaterialAnalysisMaterialTableState
    extends _MaterialAnalysisBorrowState {
  late final _aggregateTable = _MaterialAggregateTableController(this);
  late final _draftBudget = _MaterialPreparationDraftBudgetController(this);
  final Set<String> _tableLastReseedRoots = {};
  bool? _preparationUseAvailableQty;
  Future<bool?>? _preparationUsageQuestion;

  String get _preparationUsageLabel =>
      _preparationUseAvailableQty == false ? '保留余量，额外下单' : '优先使用可用余量';

  @override
  void _applyAnalysisKeepingPreparationEditing(
    ProductionMaterialAnalysisView view,
  ) {
    final orderTexts = {
      for (final entry in _tableOrderQtyControllers.entries)
        entry.key: entry.value.text,
    };
    final appendTexts = {
      for (final entry in _tableAppendQtyControllers.entries)
        entry.key: entry.value.text,
    };
    final batchTexts = {
      for (final entry in _batchQtyControllers.entries)
        entry.key: entry.value.text,
    };
    final seeds = Map<String, String>.from(_tableSeededQtyTexts);
    final typed = Map<String, double>.from(_tableUserTypedQty);
    final selected = Set<String>.from(_selectedMaterialGroupKeys);
    final deselected = Set<String>.from(_tableUserDeselectedKeys);
    final autoSelected = Set<String>.from(_tableAutoSelectedKeys);
    final planSelected = Set<String>.from(_selectedPlanLineIds);
    final priority = List<String>.from(_priorityDraft);
    final priorityBaseline = List<String>.from(_priorityBaseline);
    final editingPriority = _editingPriorities;
    final previousIds =
        _analysis?.materials.map((row) => row.materialLineId).toSet() ??
        <String>{};
    final routeDrafts = _applyAnalysisPreservingRouteDrafts(view);
    void restore(
      Map<String, TextEditingController> controllers,
      Map<String, String> texts,
    ) {
      for (final entry in texts.entries) {
        final controller = controllers[entry.key];
        if (controller != null && controller.text != entry.value) {
          controller.text = entry.value;
        }
      }
    }

    restore(_tableOrderQtyControllers, orderTexts);
    restore(_tableAppendQtyControllers, appendTexts);
    restore(_batchQtyControllers, batchTexts);
    _tableSeededQtyTexts
      ..clear()
      ..addAll(seeds);
    _tableUserTypedQty
      ..clear()
      ..addAll(typed);
    final validGroups = _analysisIndexes(_analysis!).groupsByKey.keys.toSet();
    final validProducts = _analysis!.products
        .map((product) => product.analysisLineId)
        .toSet();
    _selectedMaterialGroupKeys
      ..clear()
      ..addAll(selected.intersection(validGroups));
    _tableUserDeselectedKeys
      ..clear()
      ..addAll(deselected.intersection(validGroups));
    _tableAutoSelectedKeys
      ..clear()
      ..addAll(autoSelected.intersection(validGroups));
    _selectedPlanLineIds
      ..clear()
      ..addAll(planSelected.intersection(validProducts));
    if (editingPriority &&
        priority.toSet().containsAll(validProducts) &&
        validProducts.containsAll(priority)) {
      _priorityDraft = priority;
      _priorityBaseline = priorityBaseline;
      _editingPriorities = true;
    }
    final freshIds = _analysis!.materials
        .map((row) => row.materialLineId)
        .toSet();
    if (!freshIds.containsAll(previousIds) ||
        !previousIds.containsAll(freshIds)) {
      _serverRefreshNotice = '物料结构已更新，已保留仍对应原行的输入；请核对新增或变化的来源后下单。';
    } else if (routeDrafts.preserved > 0 ||
        routeDrafts.dropped > 0 ||
        routeDrafts.settled > 0) {
      _serverRefreshNotice = _routeDraftRefreshNotice(routeDrafts);
    }
    _recomputeTableEstimates();
    _draftBudget.invalidate();
    _tableEstimateTick.value++;
    // 保留编辑套用新快照后也要刷新没人改过的预填比例(汇总草稿开着时新默认
    // 跟着来源走)；人填过的与已下达的由 reseed 自己跳过。
    _reseedSystemOverproductionRates();
  }

  void _mutateAggregateTable(VoidCallback change) {
    if (mounted) {
      setState(() {
        change();
        _draftBudget.invalidate();
      });
    }
  }

  @override
  bool get _busy =>
      super._busy ||
      _aggregateTable.saving ||
      _aggregateTable.submission.running;
  @override
  bool get _materialAggregateWorking => _aggregateTable.saving;
  @override
  Widget? _materialAggregateToolbarAction() {
    final aggregateAction = _aggregateTable.toolbarAction();
    final usageAction = _preparationSupplyUsageAction();
    if (usageAction == null) return aggregateAction;
    return Wrap(
      spacing: UtenSpacing.s8,
      children: [usageAction, ?aggregateAction],
    );
  }

  Widget? _preparationSupplyUsageAction() => _preparationUseAvailableQty == null
      ? null
      : UtenButton(
          key: const Key('material-preparation-supply-usage'),
          type: UtenButtonType.ghost,
          height: UtenTableToolbar.controlHeight,
          onPressed:
              _busy || _preparationSubmissionActive || _aggregateTable.uncertain
              ? null
              : () => unawaited(
                  _askClaimableSupplyUsage(
                    _selectedIssuableGroups().visible,
                    null,
                    forceChoice: true,
                  ),
                ),
          child: Text('下单方式：$_preparationUsageLabel'),
        );

  @override
  void _materialAggregateAnalysisChanged() => _aggregateTable.analysisChanged();
  @override
  bool _materialAggregateOwnsLine(String lineId) =>
      _aggregateTable.ownsLine(lineId);

  void _setPreparationApproveNow(bool value) {
    if (_busy || _aggregateTable.uncertain) return;
    setState(() {
      _preparationApproveChoice = value;
      _tableCascadeGeneration++;
      _tableCascadePreview = null;
      _aggregateTable._revision++;
      _aggregateTable._preview = null;
      _aggregateTable._previewSignature = null;
    });
    _aggregateTable.schedulePreview();
  }

  @override
  double _preparationOrderedQty(_MaterialGroup group) =>
      _tableGroupDisplayedIssuedQty(group);

  @override
  double _preparationUncoveredQty(_MaterialGroup group) =>
      _tableGroupResidual(group);

  @override
  double _preparationAvailableQty(_MaterialGroup group) =>
      _draftBudget
          .summarize(group.paths.map((path) => path.materialLineId))
          ?.availableQty ??
      group.representative.preparationAvailableQty ??
      (group.representative.mainWarehousePublicAvailableQty +
          group.representative.sharedFutureClaimableQty);

  @override
  MaterialPreparationBudgetRow? _preparationBudgetOfGroups(
    Iterable<_MaterialGroup> groups,
  ) => _draftBudget.summarize(
    groups.expand((group) => group.paths.map((path) => path.materialLineId)),
  );

  @override
  double _preparationDisplayShortageQty(_MaterialGroup group) =>
      _draftBudget
          .summarize(group.paths.map((path) => path.materialLineId))
          ?.netShortageQty ??
      group.paths.fold<double>(
        0,
        (total, path) => total + _tableShownQty(path).net,
      );

  MaterialPreparationBudgetRow? _tableBudgetOf(_MaterialTableRow row) =>
      row.contextOnly
      ? null
      : _draftBudget.summarize(
          row.aggregate?.paths.map((path) => path.materialLineId) ??
              row.group?.paths.map((path) => path.materialLineId) ??
              (row.material == null
                  ? const <String>[]
                  : [row.material!.materialLineId]),
        );

  @override
  bool _preparationCanIssue(_MaterialGroup group) => const [
    null,
    _tableMissingWorkshopReason,
    _tableMissingWorkerReason,
  ].contains(_tableIssueBlockedReason(group));

  @override
  bool _preparationCanAppend(_MaterialGroup group) =>
      _tableGroupIssued(group) && _preparationCanIssue(group);

  @override
  bool _materialAggregateOwnsProductLine(String lineId) {
    final analysis = _analysis;
    if (analysis == null) return false;
    final indexes = _analysisIndexes(analysis);
    final material = indexes.materialsByAnchorProduct[lineId];
    final root = indexes.productsById[lineId]?.rootMaterialLineId;
    return (root != null && _aggregateTable.ownsLine(root)) ||
        (material != null && _aggregateTable.ownsLine(material.materialLineId));
  }

  @override
  int _materialOrderSelectionCount(List<_MaterialGroup> groups) =>
      _bomAggregateByMaterial
      ? groups
            .map((group) => _aggregateKeyOf(group.representative))
            .toSet()
            .length
      : groups.length;
  ProductionMaterialAnalysisView? _materialRowsCacheAnalysis;
  String? _materialRowsCacheKey;
  List<_MaterialTableRow>? _materialRowsCache;

  /// 与 [_materialRowsCache] 同生命周期的表头筛选桶（产品视图取自投影，汇总
  /// 视图按聚合行聚合）；始终从「未套表头筛选」的行集算出。
  Map<String, List<MasterFacetBucket>> _materialRowsFacetsCache = const {};

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
      _materialTableProjectionSignature(),
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
    return rows;
  }

  /// 可见子件计数：父键不在本层节点集内（根供料/产品直挂）的记 null 桶，
  /// 供产品行/孤儿区头行使用。
  Map<String?, int> _childCountByParent(
    List<ProductionMaterialAnalysisMaterial> nodes,
    Map<String, String?> parentIds,
  ) {
    final nodeIds = {for (final node in nodes) node.materialLineId};
    final counts = <String?, int>{};
    for (final node in nodes) {
      final parent = parentIds[node.materialLineId];
      final key = parent != null && nodeIds.contains(parent) ? parent : null;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  List<_MaterialTableRow> _computeMaterialTableRows(
    ProductionMaterialAnalysisView analysis,
  ) {
    if (_bomAggregateByMaterial) {
      return _aggregateTableRows(analysis);
    }
    final indexes = _analysisIndexes(analysis);
    final projection = _bomFilterProjection(analysis);
    _materialRowsFacetsCache = projection.facets;
    final presentation = projection.presentation;
    final matchingProducts = [
      for (final product in analysis.products)
        if (!_isEmbeddedMakeChildProduct(product) &&
            projection.visibleProductIds.contains(product.analysisLineId))
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
      final visibleNodes =
          projection.nodesByProduct[product.analysisLineId] ??
          const <ProductionMaterialAnalysisMaterial>[];
      final rootMaterial = _rootSupplyMaterialOf(product);
      final nodes = visibleNodes
          .where((node) => node.materialLineId != rootMaterial?.materialLineId)
          .toList(growable: false);
      final childCounts = _childCountByParent(
        nodes,
        presentation.parentIdsByMaterial,
      );
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
          childCount: childCounts[null],
          contextOnly: projection.contextOnlyProductIds.contains(
            product.analysisLineId,
          ),
        ),
      );
      if (_collapsedBomProducts.contains(product.analysisLineId)) continue;
      final sequences = _materialTreeSequences(
        nodes,
        parentIds: presentation.parentIdsByMaterial,
      );
      for (final material in _orderedBomNodes(
        nodes,
        parentIds: presentation.parentIdsByMaterial,
      )) {
        final group = indexes.groupsByLine[material.materialLineId];
        if (group == null) continue;
        final childCount = childCounts[material.materialLineId];
        result.add(
          _MaterialTableRow(
            kind: _MaterialTableRowKind.material,
            key: 'MATERIAL|${material.materialLineId}',
            sequence:
                'P${productIndex + 1}.'
                '${sequences[material.materialLineId] ?? material.level}',
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
            hasChildren: childCount != null,
            childCount: childCount,
            contextOnly: projection.contextOnlyMaterialIds.contains(
              material.materialLineId,
            ),
          ),
        );
      }
    }
    // 同料合并的共享制造批次(AGGREGATE_MAKE 产品)不在产品视图再立顶层行：
    // 2026-09-26 用户实机「下单后结构变了，正常只有插座0/1/2，现在把子层级也
    // 拿出来了」——它的用料与进度在「按物料汇总」视图整装待阅，产品视图里
    // 原行锁成转交份额即可(见 _tableAggregateDelegatedShare)。
    final knownProductIds = analysis.products
        .map((product) => product.analysisLineId)
        .toSet();
    final unassigned = [
      for (final entry in projection.nodesByProduct.entries)
        if (entry.key == null ||
            !knownProductIds.contains(entry.key) ||
            (_isEmbeddedMakeChildProduct(indexes.productsById[entry.key]) &&
                indexes.productsById[entry.key]?.sourceType !=
                    'AGGREGATE_MAKE'))
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
      final sequences = _materialTreeSequences(
        unassigned,
        parentIds: presentation.parentIdsByMaterial,
      );
      final childCounts = _childCountByParent(
        unassigned,
        presentation.parentIdsByMaterial,
      );
      for (final material in _orderedBomNodes(
        unassigned,
        parentIds: presentation.parentIdsByMaterial,
      )) {
        final group = indexes.groupsByLine[material.materialLineId];
        if (group == null) continue;
        final childCount = childCounts[material.materialLineId];
        result.add(
          _MaterialTableRow(
            kind: _MaterialTableRowKind.material,
            key: 'ORPHAN_MATERIAL|${material.materialLineId}',
            sequence: sequences[material.materialLineId] ?? '?',
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
            hasChildren: childCount != null,
            childCount: childCount,
            contextOnly: projection.contextOnlyMaterialIds.contains(
              material.materialLineId,
            ),
          ),
        );
      }
    }
    return _withSharedTreeProjection(result);
  }

  /// 统一套上共享树投影：连线的祖先链 / 末位标记一律由**最终渲染序**推导
  /// （`utenTreeProjection`），与级联页、货品 BOM 是同一个函数、同一套口径。
  /// 各视图只负责把行按父子相邻排好，不再各自算一遍树几何。
  List<_MaterialTableRow> _withSharedTreeProjection(
    List<_MaterialTableRow> rows,
  ) {
    final tree = utenTreeProjection<_MaterialTableRow>(
      rows,
      depthOf: (row) => row.depth,
    );
    return [
      for (var index = 0; index < rows.length; index++)
        rows[index]._withTree(tree[index]),
    ];
  }

  /// 汇总视图：桶按全部聚合行聚合（不含路径行）；表头筛选作用于聚合行，
  /// 命中的聚合行连同其展开的路径行一起保留（路径行不单独过滤）。
  List<_MaterialTableRow> _aggregateTableRows(
    ProductionMaterialAnalysisView analysis,
  ) {
    final indexes = _analysisIndexes(analysis);
    final aggregates = _materialAggregates(analysis, indexes);
    _aggregateByLineId
      ..clear()
      ..addAll({
        for (final aggregate in aggregates)
          for (final path in aggregate.paths) path.materialLineId: aggregate,
      });
    final aggregateRows = <_MaterialTableRow>[
      for (var index = 0; index < aggregates.length; index++)
        _MaterialTableRow(
          kind: _MaterialTableRowKind.aggregate,
          key: 'AGGREGATE|${aggregates[index].key}',
          sequence: 'M${index + 1}',
          depth: 0,
          aggregate: aggregates[index],
          hasChildren: _aggregateDisplayPaths(aggregates[index]).isNotEmpty,
        ),
    ];
    _materialRowsFacetsCache = _materialTableFacetsOf(aggregateRows);
    final filterActive = _hasActiveMaterialTableFilters;
    // 顶层产品行是汇总视图的一等可下单行（2026-10-07 用户口径）：挂根供给组、
    // 可勾选、数量/车间/负责人格照常编辑，提交时经按产品通道（issue-plans 的
    // planDrafts / notify）逐产品下达——不走 AGGREGATE_MAKE 共享批次，销售订单
    // 来源守恒不变（服务端 AggregateMaterialOrderPreviewService 对 level==0 的
    // 拒绝继续成立，前端在提交分流处保证顶层永不进汇总请求）。行序固定在所有
    // 聚合行之前，名称前带「顶层」徽章。
    final products = analysis.products
        .where((product) => !_isEmbeddedMakeChildProduct(product))
        .toList(growable: false);
    final result = <_MaterialTableRow>[
      for (var productIndex = 0; productIndex < products.length; productIndex++)
        _MaterialTableRow(
          kind: _MaterialTableRowKind.product,
          key: 'PRODUCT|${products[productIndex].analysisLineId}',
          sequence: 'P${productIndex + 1}',
          depth: 0,
          product: products[productIndex],
          material: indexes
              .groupsByLine[products[productIndex].rootMaterialLineId]
              ?.representative,
          group:
              indexes.groupsByLine[products[productIndex].rootMaterialLineId],
          rootAnalysisLineId: products[productIndex].analysisLineId,
        ),
    ];
    for (final aggregateRow in aggregateRows) {
      if (filterActive && !_headerFilterMatchesRow(aggregateRow)) continue;
      final aggregate = aggregateRow.aggregate!;
      final prefix = aggregateRow.sequence;
      result.add(aggregateRow);
      if (!_expandedMaterialAggregates.contains(aggregate.key)) continue;
      final displayPaths = _aggregateDisplayPaths(aggregate);
      for (var pathIndex = 0; pathIndex < displayPaths.length; pathIndex++) {
        final material = displayPaths[pathIndex];
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
          ),
        );
      }
    }
    return _withSharedTreeProjection(result);
  }

  /// Covered aggregate-tree context is still retained in command/coverage facts,
  /// but it is not a fourth original product source. Unknown/pending stays visible.
  List<ProductionMaterialAnalysisMaterial> _aggregateDisplayPaths(
    _MaterialAggregate aggregate,
  ) {
    final products = _analysis == null
        ? null
        : _analysisIndexes(_analysis!).productsById;
    return aggregate.paths
        .where((path) {
          if (products?[path.analysisLineId]?.sourceType != 'AGGREGATE_MAKE') {
            return true;
          }
          final source = materialPresentationFact(
            path.quantityFactsExact,
            'sourceRequiredQty',
            path.sourceRequiredQty,
          );
          final preparation = path.aggregatePreparation;
          final pending = preparation == null
              ? materialPresentationFact(
                  path.quantityFactsExact,
                  'planningUncoveredQty',
                  path.planningUncoveredQty,
                )
              : materialPresentationFact(
                  preparation.quantityFactsExact,
                  'planningUncoveredQty',
                  preparation.planningUncoveredQty,
                );
          return source == null ||
              source != '0' ||
              pending == null ||
              pending != '0';
        })
        .toList(growable: false);
  }

  /// 与折叠状态无关的稳定级联编号（1 / 1.1 / 1.1.2）。历史环与孤儿节点补在
  /// 末尾，只访问一次、不会无限递归。
  ///
  /// **只产出编号**：连线的祖先链与末位标记 2026-09-15 起一律由
  /// [_withSharedTreeProjection] 按渲染序统一推导——这里曾经顺带算过一份，
  /// 但它的排序比较器与真正决定行序的 [_orderedBomNodes]（先比 level）不同，
  /// 兄弟顺序一旦不一致，收口的肘线就会画在中间某行上。
  Map<String, String> _materialTreeSequences(
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
    final result = <String, String>{};
    final visited = <String>{};
    void visit(ProductionMaterialAnalysisMaterial node, String sequence) {
      if (!visited.add(node.materialLineId)) return;
      result[node.materialLineId] = sequence;
      final values = children[node.materialLineId] ?? const [];
      for (var index = 0; index < values.length; index++) {
        visit(values[index], '$sequence.${index + 1}');
      }
    }

    for (var index = 0; index < roots.length; index++) {
      visit(roots[index], '${index + 1}');
    }
    for (final node in nodes.where(
      (candidate) => !visited.contains(candidate.materialLineId),
    )) {
      visit(node, '?${result.length + 1}');
    }
    return result;
  }

  /// 该操作组当前是否可显式「采用公共在途」（行内动作与右键菜单共用）。
  bool _canClaimMaterialSharedFuture(_MaterialGroup group) {
    final analysis = _analysis;
    final material = group.representative;
    final route = material.confirmedRoute;
    // 2026-09-13 起自制（车间）物料也可采用公共在途；委外只放行无下层的纯外协
    // (有直属物料的委外件由我方领料发外，认领别人的公共在途会凭空多出一份
    // 无人负责的直属物料需求，服务端同口径，ADR-143)。
    final routeEligible =
        route == MaterialSupplyRoute.buy ||
        route == MaterialSupplyRoute.make ||
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
    final lateRemaining = group.paths.fold<double>(
      0,
      (max, path) => path.lateSharedFutureAvailableQty > max
          ? path.lateSharedFutureAvailableQty
          : max,
    );
    return _canClaimSharedFuture &&
        group.actionable &&
        _planningBlockForGroup(group) == null &&
        group.paths.every(_hasResolvedMaterialSource) &&
        !_dirtyRouteGroups.contains(group.key) &&
        routeEligible &&
        material.actionGroupKey?.isNotEmpty == true &&
        (publicRemaining > 0 || lateRemaining > 0) &&
        recommended > 0;
  }

  /// Canonical route selections are independent of visible rows and pages.
  /// 本行对应的全部操作组，**不过滤可改路线**。
  ///
  /// ADR-102 拆出这一个：勾选换义成「选行去下单」之后，已经下过单的行必须也能
  /// 勾上(要填追加下单)，而 [_materialRowGroups] 按定义排除了「已有未撤销下游
  /// 任务」的组——那是给路线下拉用的口径，不能拿来当下单的口径。
  List<_MaterialGroup> _materialRowAllGroups(_MaterialTableRow row) {
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
      if (group != null) groups[group.key] = group;
    }
    return groups.values.toList(growable: false);
  }

  /// 本行里**可以改供料路线**的操作组(已有未撤销下游任务的组不在内)。
  List<_MaterialGroup> _materialRowGroups(_MaterialTableRow row) {
    if (row.isAggregateSource ||
        (row.aggregate == null &&
            row.material != null &&
            _aggregateTable.ownsLine(row.material!.materialLineId))) {
      return const [];
    }
    final groups = _materialRowAllGroups(row);
    // One displayed route must never edit only an invisible subset of sources.
    if (groups.any((group) => !_canEditMaterialRoute(group))) return const [];
    return groups;
  }

  /// 勾选只表示下单/追加意图；供应方式另行自动保存。
  /// 汇总和原行共用办理资格，缺少可编辑指派不隐藏选择入口。
  List<_MaterialGroup> _materialRowSelectableGroups(_MaterialTableRow row) =>
      _aggregateTable.selectableGroups(row);

  /// 勾选框本身的权限门：四把锁的并集，缺哪一把只是少一个可做的动作，
  /// 不该整列没有勾选框。
  bool get _canSelectMaterialRows =>
      _canRoute || _canNotify || _canGenerate || _canCrossReallocate;

  /// 灰勾选框悬浮里的「为什么勾不了」：权限门、组级拦截原因（已转交 / 已下满 /
  /// 缺权限等，见 [_tableIssueBlockedReason]），都说不上的按只读上下文行解释。
  String _materialTableUnselectableReason(_MaterialTableRow row) {
    if (!_canSelectMaterialRows) {
      return '缺少下单 / 调拨相关权限，这些行当前不可勾选';
    }
    for (final group in _materialRowAllGroups(row)) {
      final reason = _tableIssueBlockedReason(group);
      if (reason != null) return reason;
    }
    return '只读上下文行，不参与下单';
  }

  bool _materialRowSelected(_MaterialTableRow row) {
    if (!_canSelectMaterialRows) return false;
    final groups = _materialRowSelectableGroups(row);
    return groups.isNotEmpty &&
        groups.every((group) => _selectedMaterialGroupKeys.contains(group.key));
  }

  void _changeMaterialTableSelection(
    List<_MaterialTableRow> rows,
    Set<String> selected,
  ) {
    if (_aggregateTable.uncertain) {
      context.appWarning('提交回执尚未确认，请在当前页面重试下单以核对结果');
      return;
    }
    if (_busy || !_canSelectMaterialRows) return;
    final additions = <String>{};
    final removals = <String>{};
    for (final row in rows) {
      final directGroups = row.product != null
          ? _materialRowAllGroups(row)
                .where(
                  (group) => _materialRowSelectableGroups(
                    row,
                  ).any((candidate) => candidate.key == group.key),
                )
                .toList()
          : _materialRowSelectableGroups(row);
      final wasSelected =
          directGroups.isNotEmpty &&
          directGroups.every(
            (group) => _selectedMaterialGroupKeys.contains(group.key),
          );
      final nowSelected = selected.contains(row.key);
      if (wasSelected == nowSelected) continue;
      final target = nowSelected ? additions : removals;
      target.addAll(directGroups.map((group) => group.key));
    }
    // 2026-09-27 用户口径「点左上角就是全选，包括收起的层级」：表头三态勾
    // 传回的集合只覆盖当前渲染的行——折叠分支、被筛选藏掉的子行不在 items 里。
    // 全选/清全选这两个端点按整份分析的可勾组扫一遍，收起的行一样选上/撤掉；
    // 部分选中状态不经过这里(表头勾只会点到两个端点)。
    final checkableIds = [
      for (final row in rows)
        if (_materialRowSelectableGroups(row).isNotEmpty) row.key,
    ];
    if (checkableIds.isNotEmpty) {
      final allOn = checkableIds.every(selected.contains);
      final allOff = checkableIds.every((id) => !selected.contains(id));
      if (allOn) {
        additions.addAll(_aggregateTable.allSelectableGroupKeys());
      } else if (allOff) {
        removals.addAll(_aggregateTable.allSelectableGroupKeys());
      }
    }
    setState(() {
      for (final row in rows) {
        final aggregate = row.aggregate;
        if (aggregate != null &&
            selected.contains(row.key) &&
            _aggregateTable.drafts.containsKey(aggregate.key)) {
          _aggregateTable.begin(aggregate);
        }
      }
      _selectedMaterialGroupKeys.removeAll(removals);
      _selectedMaterialGroupKeys.addAll(additions);
      // 亲手撤掉的勾，父行改量的自动勾选不再替他勾回来；亲手勾上 / 撤掉的都
      // 不再算「替他勾的」。
      _tableUserDeselectedKeys
        ..addAll(removals)
        ..removeAll(additions);
      _tableAutoSelectedKeys
        ..removeAll(removals)
        ..removeAll(additions);
    });
    _tableSelectionChanged();
  }

  void _changeMaterialRowSelection(_MaterialTableRow row, bool selected) {
    if (_busy || !_canSelectMaterialRows) return;
    if (_aggregateTable.uncertain) {
      context.appWarning('提交回执尚未确认，请在当前页面重试下单以核对结果');
      return;
    }
    final keys = _materialRowSelectableGroups(
      row,
    ).map((group) => group.key).toSet();
    setState(() {
      if (selected) {
        if (row.aggregate case final aggregate?) {
          if (_aggregateTable.drafts.containsKey(aggregate.key)) {
            _aggregateTable.begin(aggregate);
          }
        }
        _selectedMaterialGroupKeys.addAll(keys);
        _tableUserDeselectedKeys.removeAll(keys);
      } else {
        _selectedMaterialGroupKeys.removeAll(keys);
        _tableUserDeselectedKeys.addAll(keys);
      }
      _tableAutoSelectedKeys.removeAll(keys);
    });
    _tableSelectionChanged();
  }

  Map<String, double> _selectedTableTypedOutputs() {
    final analysis = _analysis;
    if (analysis == null) return const {};
    final byLine = _analysisIndexes(analysis).groupsByLine;
    final values = <String, double>{};
    for (final lineId in _tableUserTypedQty.keys) {
      final group = byLine[lineId];
      if (group == null || !_selectedMaterialGroupKeys.contains(group.key)) {
        continue;
      }
      final value = _tableSubmitQtyOf(group);
      if (value.isFinite && value > 0) values[lineId] = value;
    }
    return values;
  }

  void _tableSelectionChanged() {
    _draftBudget.invalidate();
    if (_tableSubmitting) return;
    _recomputeTableEstimates();
    _reseedTableQtyInputs(autoSelect: true);
    _tableEstimateTick.value++;
    _scheduleTableEstimateRebuild();
    final typed = _selectedTableTypedOutputs();
    if (_tableCascadePreview != null ||
        _tableCascadeInFlight ||
        typed.keys.any(
          (id) => _tableGroupHasChildren(
            _analysisIndexes(_analysis!).groupsByLine[id]!,
          ),
        )) {
      _tableCascadeDebounce?.cancel();
      _tableCascadeDebounce = Timer(
        const Duration(milliseconds: 300),
        () => unawaited(_refreshTableCascadePreview()),
      );
    }
  }

  /// 物料表树格/路线格的常态字色（选中行统一淡绿底+常态字色，2026-09-13 起不再
  /// 随选中切白字）。
  Color _materialTableForeground(ThemeData theme) =>
      theme.colorScheme.onSurface;

  Widget _materialAnalysisTable(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis, {
    bool primary = true,
  }) {
    // 主表要用的两份按需事实(ADR-102)——批量可调拨量、车间/负责人学习记忆——
    // 2026-09-27 起不在 build 里各取各的：套用快照时与在途调拨、车间在催合成一批
    // 由公共装载器取回、只重画一次 (见 _requestCompanionReads)；会话/权限一变由
    // _reloadCompanionScopes 按作用域键补取。
    // 表头筛选已在投影层生效（祖先保留为只读上下文），行集即最终行；桶随
    // 行缓存一起算出（未套表头筛选的全量行）。
    // 2026-09-27 用户口径「不要分上下页，直接都在一页，不断下拉不断显示全」：
    // 整棵行集直接交给表体(ListView.builder 懒建，滚到哪建到哪)，客户端分页
    // 与翻页条退役——上百上千行也只有一条连续滚动。
    final rows = _materialTableRows(analysis);
    return KeyedSubtree(
      key: const Key('material-analysis-material-table-region'),
      child: MasterDataTableView<_MaterialTableRow>(
        tableKey:
            'features.production.pages.material_analysis_material_table.MaterialAnalysisMaterialTableState._materialAnalysisTable.1',
        key: const Key('material-analysis-material-table'),
        columns: _materialTableColumns(theme),
        // 视图与结果入口位于表头，批量下单位于悬浮操作区。
        onFullscreenChanged: (fullscreen) =>
            setState(() => _bomTableFullscreen = fullscreen),
        toolbarLeadingActions: [
          ..._bomToolbarActions(theme, analysis),
          if (_preparationPlanResults.isNotEmpty)
            _preparationPlanResultsButton(),
        ],
        selectable: true,
        preserveSelectionOnContextMenu: true,
        selectionStateOf: _aggregateTable.selectionState,
        // 只对具备下单/追加能力的原行或汇总行开放勾选。
        idOf: (row) =>
            _canSelectMaterialRows &&
                _materialRowSelectableGroups(row).isNotEmpty
            ? row.key
            : null,
        // idOf 为 null 的行组件默认渲染灰勾选框：已确认未改动的行明确「无勾选框」
        // （勾了也不计数），其余不可勾选行（产品行/只读上下文/不可改路线）保持既有灰框，
        // 并把「为什么勾不了」的人话原因挂到灰框悬浮——零解释的灰框只会让人反复点、
        // 猜不出是已转交/已下满还是缺权限(2026-10-07 用户实机：汇总视图下满后回到
        // 按产品视图，子行灰框勾不上又无任何提示)。
        // 缺 BOM 的委外件给灰框并说明原因(ADR-143 §二.3)：等研发完善后自动可勾。
        unselectableLeadingBuilder: (_, row) {
          final bomMissing = _tableRowBomMissingLabel(row);
          if (bomMissing != null) {
            return Tooltip(
              message: '$bomMissing，研发完善 BOM 前不能下达委外',
              child: Checkbox(
                key: ValueKey('material-table-bom-missing-${row.key}'),
                value: false,
                onChanged: null,
              ),
            );
          }
          return row.isAggregateSource ||
                  (_materialRowGroups(row).isNotEmpty &&
                      _materialRowSelectableGroups(row).isEmpty)
              ? const SizedBox.shrink()
              : Tooltip(
                  message: _materialTableUnselectableReason(row),
                  child: const Checkbox(value: false, onChanged: null),
                );
        },
        selectionSummaryCount: _bomAggregateByMaterial
            ? _materialOrderSelectionCount(
                _analysisIndexes(analysis).groups
                    .where(
                      (group) => _selectedMaterialGroupKeys.contains(group.key),
                    )
                    .toList(),
              )
            : _selectedMaterialGroupKeys.length,
        onClearSelection: () {
          if (_aggregateTable.uncertain) {
            context.appWarning('提交回执尚未确认，请先核对结果');
            return;
          }
          if (_busy) return;
          setState(() {
            _selectedMaterialGroupKeys.clear();
            _tableAutoSelectedKeys.clear();
          });
        },
        selectedIds: {
          ..._selectedMaterialGroupKeys,
          for (final row in rows)
            if (_materialRowSelected(row)) row.key,
        },
        onSelectedIdsChanged: (selected) =>
            _changeMaterialTableSelection(rows, selected),
        onRowSelectionChanged: _changeMaterialRowSelection,
        batchActionsBuilder: (_, _) => _bottomActionButtons(),
        items: rows,
        // 表头筛选（2026-09-09 用户口径：进度/路线列下拉筛选，UtenTableColumnKit
        // 同款锚定弹窗；2026-09-10 F2a 改稳定键 + 投影级过滤）：bucket 从当前
        // BOM 视图全量行聚合（非当前页、不含表头筛选本身），过滤在节点投影层
        // 生效（保留祖先为只读上下文、箭头/子件数/chip 计数同步），与视图 chip 叠加。
        facets: _materialRowsFacetsCache,
        nullCounts: const {},
        filters: _materialTableFilters,
        onFilterChanged: (key, value) => setState(() {
          _materialTableFilters[key] = value;
        }),
        // 宽屏联动滚动：整页先滚、表格列头顶到页面顶部后表体内滚；横向滚动
        // 条按内容高度定位（行少贴末行下、超高钉在联动区底），与货品资料页
        // 同一套交互。窄屏单滚动区回退为有界高度 + 虚拟滚动。
        primary: primary,
        virtualized: !primary,
        rowKeyOf: (row) => row.key,
        rowWidgetKeyOf: _materialTableRowWidgetKey,
        enableTextSelection: false,
        // 空态：组件层在有激活表头筛选时补「清除筛选」按钮与生效数提示（F2a-flow）。
        emptyMessage: '当前视图/筛选下没有物料任务，可切换“全部 BOM”、清除查找或清除表头筛选',
        rowColor: (row) {
          if (row.contextOnly) {
            return theme.colorScheme.surfaceContainerHigh.withValues(
              alpha: 0.45,
            );
          }
          if (row.kind == _MaterialTableRowKind.orphan) {
            return theme.colorScheme.errorContainer.withValues(alpha: 0.35);
          }
          if (_futureProgressFor(row).outgoing > 0) {
            return _crossReallocationSourceColor(theme).withValues(alpha: 0.10);
          }
          if (row.material?.crossReallocationRefs.any(
                (allocation) =>
                    allocation.isOutbound &&
                    !allocation.isReversed &&
                    !allocation.isCancelled,
              ) ==
              true) {
            return _crossReallocationSourceColor(theme).withValues(alpha: 0.10);
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
        // 2026-10-08：无业务组的顶层产品行（汇总视图）与聚合行也开右键菜单——
        // 菜单里只有整树展开/收起；孤儿头行（kind=orphan）不弹。
        canShowRowMenu: (row) =>
            !row.contextOnly &&
            (row.group != null ||
                row.kind != _MaterialTableRowKind.orphan &&
                    (row.aggregate != null || row.product != null)),
      ),
    );
  }

  // ===== 表头筛选（2026-09-10 F2a：稳定桶键 + 投影级过滤）=====
  //
  // 桶键：路线 = BUY/SUBCONTRACT/MAKE/MIXED（当前显示路线：草稿优先，其次已确认、
  // 已下达目标、学习/主档默认）；进度 = routePending/pendingIssue/inTransit/
  // covered/blocked/inactive 或流程阶段键（[ProductionFlowStage.key]），汇总行
  // aggregateCovered/aggregatePartial/aggregateUncovered。文案带数量/百分比的
  // 行只按键进桶，桶标签是中文短标签（[MasterFacetBucket.label]）。
  //
  // 所属仓库(V587)的桶键直接就是仓库名, 没登记归属的行落「未登记」一桶; 取值走
  // 宿主的 owningWarehouseFilterValue, 与单元格显示同一份真相(含本次会话改过的
  // 覆盖值)。

  /// 表头筛选状态（key=列 key，value=稳定桶键；null/移除=清除）。
  final Map<String, String?> _materialTableFilters = {};

  String? _materialTableFilterValue(String key) {
    final value = _materialTableFilters[key];
    return value == null || value.isEmpty ? null : value;
  }

  /// 这是「要不要跑筛选」的总闸：为 false 时投影层整批放行，
  /// 所有 _headerFilterMatchesRow 都不会被调用。
  ///
  /// 因此它必须认全部筛选键，**不能只列特例四个**——漏掉的键会表现成
  /// 「下拉里选了值、桶和计数都对，但一行都没被过滤掉」，
  /// 直到用户顺手又选了一个特例键，总闸翻 true，先前那个筛选才突然追认生效。
  /// 2026-09-22 对抗复查抓出来的真缺陷(新增的十个通用筛选当时全是死的)。
  @override
  bool get _hasActiveMaterialTableFilters => _materialTableFilters.values.any(
    (value) => value != null && value.isNotEmpty,
  );

  /// 投影/行缓存键：表头筛选值 + 路线草稿/脏组/学习记忆代际（路线桶与路线
  /// 筛选随下拉草稿变化）+ 视图排布。
  @override
  String _materialTableProjectionSignature() {
    final filters = [
      for (final entry in _materialTableFilters.entries)
        if (entry.value != null && entry.value!.isNotEmpty)
          '${entry.key}=${entry.value}',
    ]..sort();
    final drafts = [
      for (final entry in _routeDraft.entries)
        '${entry.key}:${entry.value.wireName}',
    ]..sort();
    final dirty = _dirtyRouteGroups.toList()..sort();
    // 所属仓库的本地覆盖也要进签名: 改完只 setState 而签名不变的话, 行缓存与
    // BOM 投影会原样复用, 新仓库名和新筛选桶都不会出现在界面上。
    final owningWarehouses = [
      for (final entry in _owningWarehouseNameOverrides.entries)
        '${entry.key}:${entry.value ?? ''}',
    ]..sort();
    return [
      _bomAggregateByMaterial.toString(),
      filters.join(','),
      drafts.join(','),
      dirty.join(','),
      owningWarehouses.join(','),
    ].join('|');
  }

  @override
  _MaterialTableRow _probeProductRow(
    ProductionMaterialAnalysisProduct product,
    _MaterialAnalysisIndexes indexes,
  ) {
    final rootMaterial = _rootSupplyMaterialOf(product);
    return _MaterialTableRow(
      kind: _MaterialTableRowKind.product,
      key: 'PRODUCT|${product.analysisLineId}',
      sequence: '',
      depth: 0,
      product: product,
      material: rootMaterial,
      group: rootMaterial == null
          ? null
          : indexes.groupsByLine[rootMaterial.materialLineId],
      rootAnalysisLineId: product.analysisLineId,
    );
  }

  @override
  _MaterialTableRow _probeMaterialRow(
    ProductionMaterialAnalysisMaterial material,
    _MaterialAnalysisIndexes indexes,
  ) => _MaterialTableRow(
    kind: _MaterialTableRowKind.material,
    key: 'MATERIAL|${material.materialLineId}',
    sequence: '',
    depth: 1,
    material: material,
    group: indexes.groupsByLine[material.materialLineId],
    rootAnalysisLineId: material.analysisLineId,
  );

  /// 路线列桶键：产品行（无根供料）/孤儿头行/上下文行不进桶。
  String? _materialTableRouteFacetKey(_MaterialTableRow row) {
    if (row.contextOnly || (row.aggregate == null && row.group == null)) {
      return null;
    }
    return _materialTableRoute(row)?.wireName ?? 'MIXED';
  }

  String _materialTableRouteFacetLabel(String key) =>
      MaterialSupplyRoute.fromWire(key)?.label ?? _l10n.materialMixedRoutes;

  /// 所属仓库列桶键 = 仓库名(没登记的落「未登记」一桶), 与单元格显示同一口径,
  /// 取值一律走宿主助手。只读上下文行与取不到货品身份的行不进桶——桶里没有的
  /// 值, 筛选也选不出来。
  String? _materialTableOwningWarehouseFacetKey(_MaterialTableRow row) {
    if (row.contextOnly) return null;
    final owning = _materialTableOwningWarehouseRef(row);
    final goodsId = owning.goodsId;
    if (goodsId == null || goodsId.isEmpty) return null;
    return owningWarehouseFilterValue(goodsId, owning.owningWarehouseName);
  }

  /// 进度列桶键与标签（与 [_materialTableStatusText]/[_materialTableStatusCell]
  /// 同一分支顺序，只是把文案换成有限枚举键）。
  ({String key, String label})? _materialTableStatusFacet(
    _MaterialTableRow row,
  ) {
    ({String key, String label}) fixed(String key) =>
        (key: key, label: _materialStatusFacetLabels[key] ?? key);
    if (row.contextOnly) return null;
    final block = row.group == null
        ? _analysis?.planningBlockedReason(
            row.product?.analysisLineId ?? row.material?.analysisLineId ?? '',
          )
        : _planningBlockForGroup(row.group!);
    if (block != null) return fixed('blocked');
    if (_tableRowBomMissingLabel(row) != null) {
      return (key: 'bomMissing', label: '缺 BOM·已通知研发');
    }
    if (_rootExternalSupplyRow(row) && (row.product?.remainingQty ?? 1) <= 0) {
      return fixed('covered');
    }
    final product = row.product;
    if (product != null && !_rootExternalSupplyRow(row)) {
      final stage = _productExecutionStage(product);
      if (stage != null) return (key: stage.key, label: stage.label);
      if (_canSelectProduct(product)) return fixed('pendingIssue');
      if (_rootRoutePending(product)) return fixed('routePending');
      return fixed('blocked');
    }
    final aggregate = row.aggregate;
    if (aggregate != null) {
      if (aggregate.totalDemandSupplyGap <= 0) return fixed('aggregateCovered');
      if (aggregate.coverageRatio <= 0) return fixed('aggregateUncovered');
      return fixed('aggregatePartial');
    }
    final group = row.group;
    if (group == null) return null;
    final status = _materialStatus(Theme.of(context), group);
    final key = status.facetKey;
    if (key == null) return null;
    return (
      key: key,
      label:
          status.facetLabel ?? _materialStatusFacetLabels[key] ?? status.label,
    );
  }

  bool _rowHasDirtyRoute(_MaterialTableRow row) => _materialRowGroups(
    row,
  ).any((group) => _dirtyRouteGroups.contains(group.key));

  /// 路线筛选对正在编辑（脏组）的行豁免：改了下拉的行保持可见直到确认，
  /// 否则下单按钮会计入无法解释的隐藏来源。
  @override
  bool _headerFilterMatchesRow(_MaterialTableRow row) {
    final routeFilter = _materialTableFilterValue('route');
    if (routeFilter != null &&
        _materialTableRouteFacetKey(row) != routeFilter &&
        !_rowHasDirtyRoute(row)) {
      return false;
    }
    final statusFilter = _materialTableFilterValue('status');
    if (statusFilter != null &&
        _materialTableStatusFacet(row)?.key != statusFilter) {
      return false;
    }
    final owningWarehouseFilter = _materialTableFilterValue('owningWarehouse');
    if (owningWarehouseFilter != null &&
        _materialTableOwningWarehouseFacetKey(row) != owningWarehouseFilter) {
      return false;
    }
    for (final entry in _materialTableGenericFacetExtractors.entries) {
      final selected = _materialTableFilterValue(entry.key);
      if (selected != null && entry.value(row) != selected) return false;
    }
    return true;
  }

  /// 通用表头筛选取值器(ADR-102「能加筛选的列全部加上」)。
  ///
  /// 在这里加一条，建桶、匹配与失效清理三处自动跟上——老写法是三处各写一遍，
  /// 加列必漏其中一处。路线 / 进度 / 所属仓库三列因为各有特例
  /// (路线要放行改过下拉的脏行、进度要带中文标签、仓库列有「未登记」沉底
  /// 规则)仍单独处理，不进这张表。
  ///
  /// 没有筛选的列有六个：树形的「物料名称」——它已经有关键词搜索框，再挂一个
  /// 几百个值的下拉没有意义；以及 2026-09-22 用户口径「表头就只要那几个字」的
  /// 「物料办理 / 编号 / 需要数量 / 还缺数量 / 下单数量」——这五列不进这张表，
  /// 列头就没有桶、没有下拉(它们的 ⓘ 也一并撤了，见 [_materialTableColumns])。
  Map<String, String? Function(_MaterialTableRow)>
  get _materialTableGenericFacetExtractors => {
    'colorName': (row) => _blankFacet(_materialTableColorText(row)),
    'unitName': (row) => _blankFacet(_materialTableUnitText(row)),
    // 下面两个一律复用列自己的取值函数, 不另写一份判据。
    // 2026-09-22 对抗复查: 原先各写各的, 于是「筛生产车间=二车间」会筛出一屏
    // 生产车间列显示横杠的采购行——筛选值与眼睛看到的对不上。
    'productionWorkshop': (row) =>
        _blankFacet(_materialTableProductionWorkshopText(row)),
    'responsible': (row) => _blankFacet(_materialTableResponsibleText(row)),
    'appendQty': (row) {
      final group = _tableEditableGroup(row);
      if (group == null || !_tableGroupIssued(group)) return null;
      final text = _tableAppendQtyControllers[group.key]?.text.trim() ?? '0';
      return (double.tryParse(text) ?? 0) > 0 ? '已填追加' : '未填追加';
    },
  };

  /// 空串/横杠都是「没有值」，不进桶——否则筛选下拉里会冒出一个空白项。
  static String? _blankFacet(String? raw) {
    final text = raw?.trim() ?? '';
    return text.isEmpty || text == '—' ? null : text;
  }

  /// 进度/路线/所属仓库列的筛选桶：稳定键 + 中文标签 + 计数；空值行不进桶。
  /// 排序：路线按 自制/采购/委外/路线不一；进度按枚举表顺序，流程阶段键在后
  /// 按标签排；所属仓库按仓库名, 「未登记」沉底。
  @override
  Map<String, List<MasterFacetBucket>> _materialTableFacetsOf(
    Iterable<_MaterialTableRow> rows,
  ) {
    final routeCounts = <String, int>{};
    final statusCounts = <String, ({int count, String label})>{};
    final owningWarehouseCounts = <String, int>{};
    for (final row in rows) {
      final routeKey = _materialTableRouteFacetKey(row);
      if (routeKey != null) {
        routeCounts[routeKey] = (routeCounts[routeKey] ?? 0) + 1;
      }
      final owningWarehouseKey = _materialTableOwningWarehouseFacetKey(row);
      if (owningWarehouseKey != null) {
        owningWarehouseCounts[owningWarehouseKey] =
            (owningWarehouseCounts[owningWarehouseKey] ?? 0) + 1;
      }
      final status = _materialTableStatusFacet(row);
      if (status != null) {
        statusCounts.update(
          status.key,
          (current) => (count: current.count + 1, label: current.label),
          ifAbsent: () => (count: 1, label: status.label),
        );
      }
    }
    const routeOrder = ['MAKE', 'BUY', 'SUBCONTRACT', 'MIXED'];
    final statusOrder = _materialStatusFacetLabels.keys.toList();
    int rank(List<String> order, String key) {
      final index = order.indexOf(key);
      return index < 0 ? order.length : index;
    }

    final routeKeys = routeCounts.keys.toList()
      ..sort((a, b) => rank(routeOrder, a).compareTo(rank(routeOrder, b)));
    final statusKeys = statusCounts.keys.toList()
      ..sort((a, b) {
        final byRank = rank(statusOrder, a).compareTo(rank(statusOrder, b));
        if (byRank != 0) return byRank;
        return statusCounts[a]!.label.compareTo(statusCounts[b]!.label);
      });
    const unsetLabel =
        _MaterialAnalysisProductTasksState.owningWarehouseUnsetLabel;
    final owningWarehouseKeys = owningWarehouseCounts.keys.toList()
      ..sort((a, b) {
        // 仓库名按名字排; 「未登记」是缺失态, 永远沉底, 不跟真仓库名混在中间。
        if (a == unsetLabel) return b == unsetLabel ? 0 : 1;
        if (b == unsetLabel) return -1;
        return a.compareTo(b);
      });
    return {
      'route': [
        for (final key in routeKeys)
          MasterFacetBucket(
            value: key,
            count: routeCounts[key]!,
            label: _materialTableRouteFacetLabel(key),
          ),
      ],
      'status': [
        for (final key in statusKeys)
          MasterFacetBucket(
            value: key,
            count: statusCounts[key]!.count,
            label: statusCounts[key]!.label,
          ),
      ],
      // 桶键就是仓库名, 不另给 label(display 会回落到 value)。
      'owningWarehouse': [
        for (final key in owningWarehouseKeys)
          MasterFacetBucket(value: key, count: owningWarehouseCounts[key]!),
      ],
      ..._materialTableGenericFacets(rows),
    };
  }

  /// 通用列的筛选桶：按 [_materialTableGenericFacetExtractors] 一次算完。
  /// 桶键即显示值，按名称排；「待指派」「未填追加」这类缺失态沉底。
  Map<String, List<MasterFacetBucket>> _materialTableGenericFacets(
    Iterable<_MaterialTableRow> rows,
  ) {
    const trailing = {'待指派', '未填追加'};
    final counts = <String, Map<String, int>>{};
    for (final row in rows) {
      for (final entry in _materialTableGenericFacetExtractors.entries) {
        final value = entry.value(row);
        if (value == null) continue;
        final bucket = counts.putIfAbsent(entry.key, () => <String, int>{});
        bucket[value] = (bucket[value] ?? 0) + 1;
      }
    }
    return {
      for (final entry in counts.entries)
        entry.key: [
          for (final key
              in entry.value.keys.toList()..sort((a, b) {
                final aTrailing = trailing.contains(a);
                final bTrailing = trailing.contains(b);
                if (aTrailing != bTrailing) return aTrailing ? 1 : -1;
                return a.compareTo(b);
              }))
            MasterFacetBucket(value: key, count: entry.value[key]!),
        ],
    };
  }

  /// 只移除当前桶里已不存在的筛选值（刷新/轮询/切视图后失效值），仍有效的
  /// 用户筛选保留；无激活筛选时零成本。
  @override
  void _pruneMaterialTableFilters() {
    if (!_hasActiveMaterialTableFilters) return;
    final analysis = _analysis;
    if (analysis == null) {
      _materialTableFilters.clear();
      return;
    }
    _materialTableRows(analysis);
    final facets = _materialRowsFacetsCache;
    _materialTableFilters.removeWhere((key, value) {
      if (value == null || value.isEmpty) return true;
      return !(facets[key] ?? const <MasterFacetBucket>[]).any(
        (bucket) => bucket.value == value,
      );
    });
  }

  /// 主表列定稿(ADR-102 一张表)。
  ///
  /// 列顺序按用户口径：进度 / 待办 最前（2026-10-08「状态或进度列默认放
  /// 最前」，推翻此前「工序长文本进度列不动」的判定），再「这一行我能干
  /// 什么」(物料办理)、身份四列、供应方式，然后四个数量(需要 / 还缺 / 下单 /
  /// 追加)，再是落点与指派(所属仓库 / 生产车间 / 负责人)。原「归属车间」列
  /// 2026-09-29 起并入「生产车间」(同一事实源，默认带出)。
  ///
  /// 退役的四列及去向：
  /// - 「可用数量」「在途未到」「公共认领未实收」——三者都是「还缺多少」的
  ///   分解项，新的「还缺数量」已经把它们全部扣完，并在悬浮里逐项讲清楚；
  ///   2026-09-25 起按用户口径恢复一列「可用数量」，但含义收窄为公共口径
  ///   （主仓公共现货 + 公共在途可认领），不再是各路径求和的仓库余量；
  /// - 「在途调拨」——并进「物料办理」列的调拨按钮与其悬浮说明。
  ///
  /// 这里不给任何列开点击排序：本表是树，按列重排会把层级打散。列的顺序与
  /// 显隐仍由表头设置(拖拽换位 / 竖拖隐藏)控制，那才是用户要的「表头排序
  /// 或者添加删除」。
  ///
  /// 2026-09-22 用户口径：「物料办理 / 编号 / 需要数量 / 还缺数量 / 下单数量」
  /// 五列的表头只显示那几个字——不挂 ⓘ 说明，也不出筛选下拉。列头出不出
  /// 下拉由有没有筛选桶决定(见 [_materialTableGenericFacetExtractors])，这里
  /// 只负责不给 info；这几列的解释仍在单元格自己的悬浮里(调拨按钮为什么灰、
  /// 「还缺数量」怎么扣的、「下单数量」填的是要覆盖的总量)。
  List<MasterColumnDef<_MaterialTableRow>> _materialTableColumns(
    ThemeData theme, {
    bool revealAssignmentKeys = true,
  }) => [
    // 2026-10-08 用户口径「状态或进度列默认放最前」：进度 / 待办 列移到首位
    //（推翻 2026-10-06 批次「工序长文本进度列不动」的判定）。本表无 compactCards
    // 卡片形态，不需要给原首列钉 cardRole。
    MasterColumnDef(
      key: 'status',
      label: _l10n.materialProgress,
      width: 230,
      info:
          '这行物料现在走到哪一步（等待下单 → 下单 → 财务审批 → 收货 → 检验 → '
          '入库)；点击状态可看全程明细。还没确认供应方式的行显示「待选供应方式」。',
      value: _materialTableStatusText,
      cellBuilderHandlesSemantics: true,
      cellColor: (context, row) {
        if (row.contextOnly) return null;
        // 按物料汇总行的「合格库存保障」走显式三档（绿/紫/琥珀），与
        // completed/pending 两相相位脱钩——部分覆盖原与未覆盖同色，分不出。
        final aggregate = row.aggregate;
        if (aggregate != null) {
          final type = _materialAggregateCoverageBadgeType(aggregate);
          return type == null ? null : utenStatusBadgeCellColor(type);
        }
        return _materialTableStatusStyle(Theme.of(context), row).background;
      },
      cellBuilder: (_, row) => _materialTableStatusCell(theme, row),
    ),
    MasterColumnDef(
      key: 'handle',
      label: _l10n.materialHandle,
      width: 110,
      value: _materialTableHandleText,
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => _materialTableHandleCell(theme, row),
    ),
    MasterColumnDef(
      key: 'treeIdentity',
      label: _bomAggregateByMaterial
          ? _l10n.materialIdentityByMaterial
          : _l10n.materialIdentityByProduct,
      width: 360,
      value: _materialTableIdentityText,
      cellBuilderHandlesSemantics: true,
      // 树列自己吃满整行高度：同一行里只要别的列换了两行，这一格若被竖向
      // 居中收缩，层级竖线就接不到上下行（2026-09-15）。
      fillsCellHeight: true,
      cellBuilder: (_, row) => _materialTableIdentityCell(theme, row),
    ),
    // 2026-09-14 用户口径：编号 / 颜色 / 单位从身份格副行提升为独立列，
    // 紧跟「物料名称」。同名不同色/不同单位的行在这里一眼分得开，也能各自
    // 筛选、导出(原副行只是一串 · 连起来的文本)。
    MasterColumnDef(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: _materialTableCodeText,
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 96,
      value: _materialTableColorText,
    ),
    MasterColumnDef(
      key: 'unitName',
      label: '单位',
      width: 76,
      value: _materialTableUnitText,
    ),
    MasterColumnDef(
      key: 'route',
      label: _l10n.materialRoute,
      width: 140,
      value: _materialTableRouteText,
      info:
          '这批物料怎么准备：采购 = 向供应商买；委外 = 发给加工商加工；'
          '自制 = 自己车间生产。带下层物料的可选路线更多。'
          '未选供应方式的行显示红框，选好即自动保存后才能下单；'
          '确认之后仍可随时改，三个下达桶的行与计数会跟着变，'
          '但已经下达过的行要先撤回才能改。',
      cellBuilder: (_, row) => _materialTableRouteCell(theme, row),
    ),
    MasterColumnDef(
      key: 'requiredQty',
      label: _l10n.materialRequired,
      width: 100,
      type: 'number',
      value: (row) => _materialTableRequiredText(row) ?? '—',
      exactValueOf: _materialTableRequiredText,
      // 不给 info：ADR-102 §12.8（2026-09-22 用户口径）——本列与「物料办理/
      // 编号/还缺数量/下单数量」同属「表头只显示那几个字」的五列。2026-09-23
      // 并行会话 WIP 曾带回一条 info，因非交互列不渲染而沉睡；列头 ⓘ 机制
      // 补齐非交互列后会真的显示，与该口径冲突，故移除。
      // ADR-129 §2.11：本行按哪个用量算(真实/设计、几批、设计值)放在单元格悬停里。
      cellBuilder: (_, row) {
        final quantity = Text(
          _materialTableRequiredText(row) ?? '—',
          key: ValueKey('material-analysis-source-required-${row.key}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
        final material = row.material;
        final usage = material == null
            ? null
            : materialAnalysisUsageBasisText(_l10n, material);
        return usage == null
            ? quantity
            : Tooltip(
                key: ValueKey('material-analysis-usage-basis-${row.key}'),
                message: usage,
                child: quantity,
              );
      },
    ),
    // 可用只含公共余量；优先使用余量时，有效选中输入临时预占公共部分。
    // 正式下达后的库存、已下单和在途事实仍由服务端返回。
    MasterColumnDef(
      key: 'publicAvailableQty',
      label: _l10n.materialPublicAvailable,
      width: 100,
      type: 'number',
      value: (row) => _materialTablePublicAvailableQty(row) ?? '—',
      exactValueOf: _materialTablePublicAvailableText,
      exactListenableOf: (_) => _tableEstimateTick,
      cellBuilder: (_, row) => ValueListenableBuilder<int>(
        valueListenable: _tableEstimateTick,
        builder: (_, _, _) {
          if (row.isAggregateSource) {
            return Tooltip(
              key: ValueKey(
                'material-analysis-public-available-${row.material!.materialLineId}',
              ),
              message: '与其它来源共用同一供给池，数量只在上方物料汇总行显示；不是本产品独占，也不表示已经入库。',
              child: const Text('—'),
            );
          }
          final parts = _materialTablePublicAvailableParts(row);
          final text = _materialTablePublicAvailableQty(row) ?? '—';
          final material = row.material ?? row.aggregate?.representative;
          final budget = _tableBudgetOf(row);
          final tooltip = budget != null
              ? '${_preparationUseAvailableQty == false ? '本次保留余量、额外下单，不预扣公共可用量。' : '本次选中量预占后，'}公共可用余额 $text。'
                    '本行本次预占 ${_qty(budget.reservedSharedQty)}；取消勾选即恢复。已归属各订单的私有份额不再加入公共可用。'
                    '这是本次编辑预算，正式下达后按实际结果更新。'
              : material?.preparationAvailableQty != null
              ? '当前可采用 $text，包含仓库现货、已下单待办理和在途供给。'
                    '已被其它订单占用的部分不重复计入；入库前不能作为可领料现货。'
              : parts.stock <= 0 && parts.future <= 0
              ? '这一行没有可用的公共现货或公共在途。'
              : '公共现货 ${_qty(parts.stock)} + 公共在途可认领 ${_qty(parts.future)}'
                    '（含晚到部分）。下单时服务端会从「下单数量」里自动认领公共在途，'
                    '「还缺数量」也已把这部分扣掉。';
          return Tooltip(
            key: ValueKey(
              'material-analysis-public-available-'
              '${row.material?.materialLineId ?? row.key}',
            ),
            message: tooltip,
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
        },
      ),
    ),
    // 有明确供给池时展示本次选择预算；旧响应回退到服务端净缺口。
    MasterColumnDef(
      key: 'netShortageQty',
      label: _l10n.materialShortage,
      width: 112,
      type: 'number',
      value: (row) => _materialTableNetShortageText(row) ?? '—',
      exactValueOf: _materialTableNetShortageText,
      exactListenableOf: (_) => _tableEstimateTick,
      cellBuilderHandlesSemantics: true,
      // 数字随估算 tick 当场变；底色(cellColor)由表格在整页重建时算，停手 200ms
      // 后跟上——每敲一下都整页重建是 260-450ms 一帧，见 _tableEstimateTick。
      cellBuilder: (_, row) => ValueListenableBuilder<int>(
        valueListenable: _tableEstimateTick,
        builder: (_, _, _) => _materialTableNetShortageCell(theme, row),
      ),
      cellColor: (_, row) =>
          _shortageCellColor(theme, _materialTableNetShortageQty(row)),
    ),
    MasterColumnDef(
      key: 'orderQty',
      label: _l10n.materialToSupply,
      width: 132,
      type: 'number',
      value: _materialTableOrderQtyText,
      exactValueOf: (row) => _materialTableOrderRaw(row, append: false),
      exactListenableOf: (_) => _tableEstimateTick,
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => _materialTableOrderQtyCell(theme, row),
    ),
    MasterColumnDef(
      key: 'allowedOverproductionRate',
      label: '允许超产比例',
      width: 152,
      info:
          '本次下达允许的超产比例：制造底层默认 10%，上层 0%；改过的按最近一次确认的比例记住。'
          '已下达工单的比例修改仍须计划部审批。',
      value: (row) {
        if (row.aggregate case final aggregate?) {
          return _aggregateTable.rateText(aggregate);
        }
        final group = _tableEditableGroup(row);
        return group == null || !_tableIssueTarget(group).viaWorkshop
            ? '—'
            : '${_overproductionPercentController(materialLineId: group.representative.materialLineId).text}%';
      },
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) {
        if (row.aggregate case final aggregate?) {
          return _aggregateTable.rateCell(aggregate);
        }
        final group = _tableEditableGroup(row);
        if (group == null || !_tableIssueTarget(group).viaWorkshop) {
          return const Text('—');
        }
        if (row.isAggregateSource ||
            _aggregateTable.ownsLine(group.representative.materialLineId)) {
          return Text(
            '${_overproductionPercentController(materialLineId: group.representative.materialLineId).text}%',
          );
        }
        // 已下达比例随工单锁定，新增来源尚未下达时仍可设置；快照刷新不改它的显示值。
        if (_tableGroupIssued(group)) {
          return Tooltip(
            message: '这一行已下达，允许超产比例随工单锁定；要改已下达工单的比例须计划部审批。',
            child: Text(
              '${_overproductionPercentController(materialLineId: group.representative.materialLineId, issued: true).text}%',
            ),
          );
        }
        return ProductionOverproductionRateField(
          key: ValueKey('material-analysis-overproduction-rate-${group.key}'),
          controller: _overproductionPercentController(
            materialLineId: group.representative.materialLineId,
          ),
          enabled: _canGenerate && !_busy && !_tableSubmitting,
        );
      },
    ),
    MasterColumnDef(
      key: 'appendQty',
      label: _l10n.materialAdditionalOrder,
      width: 124,
      type: 'number',
      info:
          '已经下达过的行要再下多少。默认 0 = 本次不动它，填成正数才追加。'
          '追加只能增不能减：原申请还没被采购 / 委外做成订货单时直接改大那张申请，'
          '已经做成订货单的另立新单。要改小只能撤回重下。'
          '追加成功后它会并进左边的「下单数量」，这一格回到 0。',
      value: _materialTableAppendQtyText,
      exactValueOf: (row) => _materialTableOrderRaw(row, append: true),
      exactListenableOf: (_) => _tableEstimateTick,
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => _materialTableAppendQtyCell(theme, row),
    ),
    // 2026-09-15 用户口径（V590 收敛）: 所属仓库 = 货品主档 goods.
    // owning_warehouse_id 的**单一事实源**——任何入库(采购/委外/完工/调拨/退料/
    // 盘盈/手工单)自动回写为最新入库仓(StockService 内核收口), Excel 回填只填
    // 空; 全站展示(物料分析/即时库存/货品资料)一律读它。点单元格可直接改主档。
    MasterColumnDef(
      key: 'owningWarehouse',
      label: '所属仓库',
      width: 132,
      value: _materialTableOwningWarehouseText,
      info:
          '这个货品归哪个仓管。任何入库都会自动把它更新为最新入库仓（与即时库存'
          '同一事实源）；点单元格可直接改主档。',
      cellBuilder: (_, row) => _materialTableOwningWarehouseCell(theme, row),
    ),
    // 2026-09-29 用户口径：货品主档的学习车间(原「归属车间」列)与本列是同一个东西，
    // 列只留本列——默认值就是主档学习值(_materialTableProductionWorkshopCell 的
    // autofill 链)，排产确认/车间改派继续自动学习回写主档。
    // ADR-102：下达车间之前就地指派本次的车间与负责人，不必再进分桶页。
    MasterColumnDef(
      key: 'productionWorkshop',
      label: _l10n.materialProductionWorkshop,
      width: 156,
      value: _materialTableProductionWorkshopText,
      cellBuilderHandlesSemantics: true,
      info:
          '本次下达车间要交给哪个车间做。'
          '默认按这个货品上次的排产记住的车间带出，黄框提醒核对，点格子可改。'
          '只对走自制的行有意义，采购 / 委外行显示横杠。',
      cellBuilder: (_, row) => _materialTableProductionWorkshopCell(
        theme,
        row,
        revealKey: revealAssignmentKeys,
      ),
    ),
    MasterColumnDef(
      key: 'responsible',
      label: _l10n.materialResponsible,
      width: 140,
      value: _materialTableResponsibleText,
      cellBuilderHandlesSemantics: true,
      info:
          '本次这批活谁负责。优先带出这个货品上次记住的负责人，'
          '其次是所选车间在组织架构上的负责人，黄框提醒核对，点格子可改。',
      cellBuilder: (_, row) => _materialTableResponsibleCell(
        theme,
        row,
        revealKey: revealAssignmentKeys,
      ),
    ),
  ];

  MaterialFutureTransferProgress _futureProgressFor(_MaterialTableRow row) {
    if (_futureTransferReadScope != _sessionScopeKey()) {
      return MaterialFutureTransferProgress.empty;
    }
    final ids =
        (row.aggregate?.paths.map((path) => path.materialLineId) ??
                [if (row.material != null) row.material!.materialLineId])
            .toSet();
    return MaterialFutureTransferProgress.fromRecords(
      _analysis?.analysisId ?? '',
      ids,
      ids.expand(
        (id) =>
            _futureTransferByMaterial[id] ??
            const <MaterialFutureTransferRecord>[],
      ),
    );
  }

  String _futureProgressText(_MaterialTableRow row) {
    if (row.product != null || row.contextOnly) return '—';
    final progress = _futureProgressFor(row);
    if (!progress.hasRecords) {
      return _futureTransferError != null ? '进度待核对 · 点击重试' : '—';
    }
    final parts = <String>[
      if (progress.hasSupplyWarning) '供给不足 · 请核对',
      if (progress.outgoing > 0)
        '已调出 ${_qty(progress.outgoing)} · 对方已入 ${_qty(progress.receivedOutgoing)} / 未实收 ${_qty(progress.outstandingOutgoing)}',
      if (progress.incoming > 0)
        '已调入 ${_qty(progress.incoming)} · 已入 ${_qty(progress.receivedIncoming)} / 未实收 ${_qty(progress.outstandingIncoming)}',
    ];
    final text = parts.isEmpty ? '在途调拨已撤销' : parts.join('；');
    return _futureTransferError != null ? '$text（上次记录，待核对）' : text;
  }

  Key _materialTableRowWidgetKey(_MaterialTableRow row) {
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
    if (row.product?.sourceType == 'AGGREGATE_MAKE') {
      return '汇总生产用料 · ${row.product?.goodsName ?? row.product?.goodsCode ?? ''}';
    }
    if (row.isAggregateSource && row.material != null) {
      return _aggregateTable.sourceLabel(row.material!);
    }
    final name = switch (row.kind) {
      _MaterialTableRowKind.product =>
        row.product?.goodsName ?? row.product?.goodsCode ?? '未命名产品',
      _MaterialTableRowKind.aggregate =>
        row.aggregate?.goodsName ?? row.aggregate?.goodsCode ?? '未命名物料',
      _MaterialTableRowKind.material || _MaterialTableRowKind.aggregatePath =>
        row.material?.goodsName ?? row.material?.goodsCode ?? '未命名物料',
      _MaterialTableRowKind.orphan => '未归属产品的 BOM 节点',
    };
    // 2026-09-14 用户口径：编号 / 颜色 / 单位拆成独立列（见
    // [_materialTableCodeText] 等），身份列只剩名称——级联号 P1/P1.1 也一并
    // 去掉（层级由缩进 + 连接线表达）。导出仍「看到什么导出什么」：三列各自
    // 有自己的 value，不再挤进这一列。
    final breakdown = row.aggregate == null
        ? null
        : _aggregateTable.issuedBreakdown(row.aggregate!);
    return breakdown == null ? name : '$name · $breakdown';
  }

  // 三列的取值优先级与 2026-09-14 之前身份格副行完全一致：编号/颜色以产品行
  // 自身为准（产品行同时挂着根供给物料），单位以物料行为准（根供给行记的是
  // 基本单位，产品行记的是来源单位——副行一直显示前者，拆列后不能悄悄换口径）。
  String? _materialTableCodeText(_MaterialTableRow row) =>
      (row.product?.goodsCode ??
              row.aggregate?.goodsCode ??
              row.material?.goodsCode)
          ?.trim();

  String? _materialTableColorText(_MaterialTableRow row) =>
      (row.product?.colorName ??
              row.aggregate?.colorName ??
              row.material?.colorName)
          ?.trim();

  String? _materialTableUnitText(_MaterialTableRow row) =>
      (row.material?.unitName ??
              row.product?.unitName ??
              row.aggregate?.unitName)
          ?.trim();

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
      };
    } else if (aggregate != null) {
      expanded = _expandedMaterialAggregates.contains(aggregate.key);
      toggle = () => setState(() {
        if (!_expandedMaterialAggregates.add(aggregate.key)) {
          _expandedMaterialAggregates.remove(aggregate.key);
        }
      });
    } else if (material != null && row.hasChildren) {
      expanded = !_collapsedBomBranches.contains(material.materialLineId);
      toggle = () => setState(() {
        final key = material.materialLineId;
        if (!_collapsedBomBranches.add(key)) {
          _collapsedBomBranches.remove(key);
        }
      });
    }
    // 汇总视图的顶层产品行与按产品视图同名同徽章（2026-10-07：顶层在汇总视图
    // 直接可下单，不再用「产品任务（按产品办理）」前缀指路）。
    final title = product?.sourceType == 'AGGREGATE_MAKE'
        ? '汇总生产用料 · ${product?.goodsName ?? product?.goodsCode ?? ''}'
        : row.isAggregateSource && material != null
        ? _aggregateTable.sourceLabel(material)
        : product?.goodsName ??
              product?.goodsCode ??
              aggregate?.goodsName ??
              aggregate?.goodsCode ??
              material?.goodsName ??
              material?.goodsCode ??
              '未命名物料';
    final breakdown = aggregate == null
        ? null
        : _aggregateTable.issuedBreakdown(aggregate);
    final cell = UtenTreeTableCell(
      key: ValueKey('material-table-tree-${row.key}'),
      toggleKey: ValueKey('material-table-toggle-${row.key}'),
      depth: row.depth,
      // 2026-09-14 用户口径：名称前不再挂级联号，最底层不再画圆点；
      // 编号 / 颜色 / 单位已各自成列（就排在本列右边）。
      sequence: '',
      sequenceInline: true,
      showLeafMarker: false,
      // 2026-10-08 用户口径「按产品看左边加条竖线，分得清产品和子层级两个
      // 部分」：子件行（depth>0）左缘画贯穿竖线；汇总视图不画（聚合行另带
      // 来源展开，左缘线没有「同一棵子树」的语义）。
      subtreeRail: !_bomAggregateByMaterial,
      // 2026-10-08 用户口径：汇总视图顶层产品行永远无下级，48px 展开位空着，
      // 标题（「顶层」徽章+名称）顶到左缘；产品视图产品行可能有下级，不收。
      compactLeading: _bomAggregateByMaterial && product != null,
      // 连线要跨过宿主给每个数据格的纵向内边距，否则行与行之间空出 2×8px，
      // 整列看着像虚线（2026-09-15：这里原来没传，默认 0，与级联页观感不同的
      // 一大来源）。数值取自表格组件自己公开的常量，不在调用点抄魔数。
      guideBleed: MasterDataTableView.cellVerticalPadding,
      title: title,
      titleBadge: _bomAggregateByMaterial && product != null
          ? const MaterialTopLevelBadge()
          : null,
      titleBadgeLabel: _bomAggregateByMaterial && product != null ? '顶层' : null,
      subtitle: aggregate == null
          ? null
          : '${_l10n.materialAggregateSources(aggregate.productCount, _aggregateDisplayPaths(aggregate).length)}${breakdown == null ? '' : ' · $breakdown'}',
      hasChildren: row.hasChildren,
      // 未展开时圆底右下角叠「N」徽章（当前投影可见子件数）；汇总行副标题
      // 已有「N 来源」，不再叠徽章。
      childCount: aggregate == null ? row.childCount : null,
      expanded: expanded,
      onToggle: toggle,
      ancestorContinuations: row.ancestorContinuations,
      isLastChild: row.isLastChild,
    );
    return breakdown == null
        ? cell
        : Tooltip(
            key: ValueKey('material-aggregate-breakdown-${aggregate!.key}'),
            message: breakdown,
            constraints: BoxConstraints(
              maxWidth: math.min(560, MediaQuery.sizeOf(context).width - 32),
            ),
            child: cell,
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
      return group == null ? path.confirmedRoute : _materialDisplayRoute(group);
    }).toSet();
    return routes.length == 1 ? routes.single : null;
  }

  String? _materialTableRouteText(_MaterialTableRow row) => row.contextOnly
      ? '—'
      : _materialTableRoute(row)?.label ??
            (row.aggregate == null && row.group == null
                ? '—'
                : _l10n.materialMixedRoutes);

  Widget _materialTableRouteCell(ThemeData theme, _MaterialTableRow row) {
    final route = _materialTableRoute(row);
    final groups = _materialRowGroups(row);
    final editable = _canRoute && !_busy && groups.isNotEmpty;
    final foreground = _materialTableForeground(theme);
    if (!editable) {
      return Text(
        _materialTableRouteText(row) ?? '—',
        style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
      );
    }
    // 2026-09-16 用户口径：表格内下拉统一用自家 UtenDropdownField（统一弹层/
    // 单行省略号/描边与同行格一致），不再用原生 DropdownButton。
    final dropdown = UtenDropdownField(
      key: ValueKey(
        'material-route-dropdown-${row.material?.materialLineId ?? row.key}',
      ),
      dense: true,
      value: route?.name,
      // 混合路线提示保留（多行不同供应方式的行级事实）；未选时不再复述列头
      // 「供应方式」，空格走组件默认「请选择」（2026-09-27 表格小字清理口径）。
      hintText: route == null ? null : _l10n.materialMixedRoutes,
      items: [
        for (final option in MaterialSupplyRoute.values)
          UtenDropdownItem(value: option.name, label: option.label),
      ],
      onChanged: (chosen) {
        if (chosen == null) return;
        final next = MaterialSupplyRoute.values.byName(chosen);
        if (groups.every(
          (group) => group.representative.confirmedRoute == next,
        )) {
          return;
        }
        unawaited(
          _confirmRouteChanges(
            groups,
            next,
            forAggregate: row.aggregate != null,
          ),
        );
      },
    );
    // ADR-102（2026-09-25 确认路线退役修订）：还没确认供应方式的行把这一格
    // 框成红的、下拉留空。货品档案里能定路线的行由服务端在建分析 / 刷新时
    // 已自动确认 (2026-09-27)，红框只剩「主档来源为空且无 BOM」的叶子行——
    // 选好即自动保存，这一行才能下单。
    final pending = groups.any(
      (group) => group.representative.confirmedRoute == null,
    );
    if (!pending) return dropdown;
    return Tooltip(
      message: '这一行还没选供应方式，选好后立即保存并确认，它才能下单。',
      child: DecoratedBox(
        key: ValueKey(
          'material-route-pending-${row.material?.materialLineId ?? row.key}',
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(UtenRadius.control),
          border: Border.all(color: theme.colorScheme.error, width: 1.5),
        ),
        child: dropdown,
      ),
    );
  }

  // ===== 所属仓库列(V587) =====

  /// 本行代表的货品身份与它在快照里的所属仓库。
  ///
  /// 优先级与编号/颜色列一致(产品行以产品自身为准, 汇总行取代表路径, 其余取物料
  /// 行); **三个值必须取自同一个对象**——分开各取各的, 就会出现「A 货的 id 配
  /// B 货的仓库名」, 点一下改到别的货品头上。
  ({String? goodsId, String? owningWarehouseId, String? owningWarehouseName})
  _materialTableOwningWarehouseRef(_MaterialTableRow row) {
    final product = row.product;
    if (product != null) {
      return (
        goodsId: product.goodsId,
        owningWarehouseId: product.owningWarehouseId,
        owningWarehouseName: product.owningWarehouseName,
      );
    }
    final material = row.aggregate?.representative ?? row.material;
    return (
      goodsId: material?.goodsId,
      owningWarehouseId: material?.owningWarehouseId,
      owningWarehouseName: material?.owningWarehouseName,
    );
  }

  /// 列文本(也是列宽测算/导出/无障碍的回退真值): 本次会话改过的值优先于快照,
  /// 没登记归属显示「—」。V590 起归属仓由任何入库自动回写(单一事实源)。
  String? _materialTableOwningWarehouseText(_MaterialTableRow row) {
    final owning = _materialTableOwningWarehouseRef(row);
    final snapshot = owning.owningWarehouseName;
    final name = owningWarehouseNameOf(owning.goodsId, snapshot)?.trim();
    return name == null || name.isEmpty ? '—' : name;
  }

  /// 所属仓库格: 有货品身份的行点开仓库面板直接改主档; 只读上下文行与取不到
  /// 货品的行(孤儿节点、缺 goodsId 的聚合行)退化为纯文本, 不做成点不动的假按钮。
  /// V590 起改完之外的每一次入库也会自动把它回写成最新入库仓。
  Widget _materialTableOwningWarehouseCell(
    ThemeData theme,
    _MaterialTableRow row,
  ) {
    final foreground = _materialTableForeground(theme);
    final text = _materialTableOwningWarehouseText(row) ?? '—';
    // 2026-10-06 行高统一口径：格内文本单行省略号，全名走 Tooltip。
    final label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
    );
    final goodsId = _materialTableOwningWarehouseRef(row).goodsId;
    if (row.contextOnly ||
        row.isAggregateSource ||
        goodsId == null ||
        goodsId.isEmpty) {
      return Tooltip(message: text, child: label);
    }
    return Tooltip(
      message: '$text\n点击改这个货品的所属仓库(货品主档归属, 不是本次分析范围仓, 也不是入库落点仓)',
      child: InkWell(
        key: ValueKey('material-owning-warehouse-${row.key}'),
        onTap: _busy ? null : () => unawaited(_editOwningWarehouse(row)),
        child: Semantics(
          label: '所属仓库 $text',
          button: true,
          child: Row(
            children: [
              Expanded(child: label),
              Icon(
                Icons.edit_outlined,
                size: 16,
                color: foreground.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 点格子改所属仓库: 面板与写回都在宿主助手里(它自己 setState 并落覆盖表),
  /// 本页只负责把行换算成货品身份。
  ///
  /// 传宿主 State 的 context 而不是单元格的 —— 面板开着时这一行可能因翻页/
  /// 虚拟滚动被回收, 那时再拿单元格的 context 弹提示就炸了。
  Future<void> _editOwningWarehouse(_MaterialTableRow row) async {
    final owning = _materialTableOwningWarehouseRef(row);
    final goodsId = owning.goodsId;
    if (goodsId == null || goodsId.isEmpty) return;
    final current = owningWarehouseIdOf(goodsId, owning.owningWarehouseId);
    await pickOwningWarehouse(
      context,
      goodsId: goodsId,
      currentWarehouseId: current,
    );
  }

  /// 原始需求只读正式快照中的来源基线，不参与输入估算或模拟备料快照。
  /// 旧服务端缺失基线时显示横杠，不能拿动态备料量冒充原始需求。
  String? _materialTableRequiredText(_MaterialTableRow row) {
    if (row.contextOnly) return null;
    if (row.aggregate case final aggregate?) {
      return materialPresentationSum(
        {
          for (final path in aggregate.paths) path.materialLineId: path,
        }.values.map(
          (path) => materialPresentationFact(
            path.quantityFactsExact,
            'sourceRequiredQty',
            path.sourceRequiredQty,
          ),
        ),
      );
    }
    final product = row.product;
    if (_isEmbeddedMakeChildProduct(product)) {
      if (product?.sourceType == 'AGGREGATE_MAKE') return '0';
      final analysis = _analysis;
      final material = analysis == null
          ? null
          : _analysisIndexes(
              analysis,
            ).materialsByAnchorProduct[product!.analysisLineId];
      return material == null
          ? null
          : materialPresentationFact(
              material.quantityFactsExact,
              'sourceRequiredQty',
              material.sourceRequiredQty,
            );
    }
    if (row.material case final material?) {
      return materialPresentationFact(
        material.quantityFactsExact,
        'sourceRequiredQty',
        material.sourceRequiredQty,
      );
    }
    if (product == null) return null;
    return materialPresentationFact(
      product.quantityFactsExact,
      'requestedQty',
      product.requestedQty,
    );
  }

  /// 「可用数量」：该物料此刻在所选仓库还能动用的现货。
  ///
  /// 聚合行（按物料汇总/同货多路径）取代表行的仓库余量而不是各路径求和——
  /// 同一货品在多条 BOM 路径下看到的是**同一个仓库池**，求和会把一份库存
  /// 重复计量成 N 份。产品行没有自己的物料现货，显示「—」。
  double? _materialTableAvailableQty(_MaterialTableRow row) {
    if (row.contextOnly) return null;
    final material = row.material ?? row.aggregate?.representative;
    return material?.availableQty;
  }

  double? _materialTableExactQty(_MaterialTableRow row) => row.contextOnly
      ? null
      : row.aggregate != null
      ? row.aggregate!.paths.fold<double>(
          0,
          (sum, material) => sum + material.exactPeggedQty,
        )
      : row.material?.exactPeggedQty;

  String? _materialTablePublicAvailableQty(_MaterialTableRow row) {
    return _materialTablePublicAvailableText(row) ?? '—';
  }

  String? _materialTablePublicAvailableText(_MaterialTableRow row) {
    if (row.contextOnly || row.isAggregateSource) return null;
    // 预算优先（HEAD 同口径）：共享池余量的实时投影——选中预占、取消/清空
    // 恢复、供给片可用性都在这里体现；来源行已在上面按「共享池只在汇总行
    // 显示一次」返回 '—'，不与预算分支冲突。
    final budget = _tableBudgetOf(row);
    if (budget != null) {
      return materialPresentationFact(
        const {},
        'available',
        budget.availableQty,
      );
    }
    final paths =
        row.aggregate?.paths ?? [if (row.material != null) row.material!];
    final pools = <String, String?>{};
    for (final original in paths) {
      final material = _tablePreviewed(original);
      final key = material.preparationPoolKey ?? _aggregateKeyOf(material);
      final quantity = material.preparationAvailableQty != null
          ? materialPresentationFact(
              material.quantityFactsExact,
              'preparationAvailableQty',
              material.preparationAvailableQty,
            )
          : material.preparationPoolKey != null
          ? materialPresentationFact(
              material.quantityFactsExact,
              'preparationSharedAvailableQty',
              material.preparationSharedAvailableQty,
            )
          : materialPresentationSum([
              materialPresentationFact(
                material.quantityFactsExact,
                'mainWarehousePublicAvailableQty',
                material.mainWarehousePublicAvailableQty,
              ),
              materialPresentationFact(
                material.quantityFactsExact,
                'sharedFutureClaimableQty',
                material.sharedFutureClaimableQty,
              ),
            ]);
      if (pools.containsKey(key) && pools[key] != quantity) return null;
      pools[key] = quantity;
    }
    return paths.isEmpty ? null : materialPresentationSum(pools.values);
  }

  /// 「可用数量」的两段分解(悬浮说明用)：公共现货 / 公共在途可认领。
  ({double stock, double future}) _materialTablePublicAvailableParts(
    _MaterialTableRow row,
  ) {
    final material = row.material ?? row.aggregate?.representative;
    if (row.contextOnly || material == null) return (stock: 0, future: 0);
    return (
      stock: material.mainWarehousePublicAvailableQty,
      future: material.sharedFutureClaimableQty,
    );
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

  /// Four-place source facts stay unchanged; aggregate totals use BigInt sums.
  String? _tableShownQtyText(
    ProductionMaterialAnalysisMaterial material, {
    required bool net,
  }) {
    final estimate = _tableEstimatedQty[material.materialLineId];
    if (estimate != null) {
      return materialPresentationFact(
        const {},
        'estimate',
        net ? estimate.net : estimate.residual,
      );
    }
    final shown = _tablePreviewed(material);
    if (shown.hasPriorityMakeSupplement) {
      return materialPresentationFact(
        shown.quantityFactsExact,
        'priorityMakeSupplementQty',
        shown.priorityMakeSupplementQty,
      );
    }
    final preparation = shown.aggregatePreparation;
    if (preparation != null) {
      return materialPresentationFact(
        preparation.quantityFactsExact,
        net ? 'netShortageQty' : 'planningUncoveredQty',
        net ? preparation.netShortageQty : preparation.planningUncoveredQty,
      );
    }
    if (!net) {
      final group = _analysis == null
          ? null
          : _analysisIndexes(_analysis!).groupsByLine[material.materialLineId];
      if (group != null) {
        try {
          return _tableGroupResidualText(group);
        } on FormatException {
          return null;
        }
      }
    }
    final projected = _tablePreviewedQty(material);
    if (net && projected.net != shown.netShortageQty) {
      return materialPresentationFact(const {}, 'projected', projected.net);
    }
    return materialPresentationFact(
      shown.quantityFactsExact,
      net ? 'netShortageQty' : 'additionalSupplyRecommendedQty',
      net ? shown.netShortageQty : shown.additionalSupplyRecommendedQty,
    );
  }

  String? _aggregateShownQtyText(
    _MaterialAggregate aggregate, {
    required bool net,
  }) {
    // 2026-10-06「优先整数」× 2026-10-07「真实分数不得取整」：先按最粗守恒
    // 整分（噪声预算 = 来源数个 10^-4，只盖服务端定点分摊尾巴 83.3334×3 →
    // 1000；0.5×3=1.5 预算外保持精确）；整分不可解析退回逐路径精确合计。
    final coalesced = coalescedAggregateTotalText([
      for (final path in aggregate.paths)
        _tableShownQtyText(path, net: net) ?? '',
    ]);
    if (coalesced != null) return coalesced;
    return materialPresentationSum(
      {
        for (final path in aggregate.paths) path.materialLineId: path,
      }.values.map((path) => _tableShownQtyText(path, net: net)),
    );
  }

  double? _aggregateShownTotal(
    _MaterialAggregate aggregate, {
    required bool net,
  }) => double.tryParse(_aggregateShownQtyText(aggregate, net: net) ?? '');

  double? _aggregatePathShownQty(
    ProductionMaterialAnalysisMaterial material, {
    required bool net,
  }) => double.tryParse(_tableShownQtyText(material, net: net) ?? '');

  String? _materialTableNetShortageText(_MaterialTableRow row) {
    if (row.contextOnly || (row.product != null && row.group == null)) {
      return null;
    }
    final budget = _tableBudgetOf(row);
    if (budget != null) {
      return materialPresentationFact(
        const {},
        'budget',
        budget.netShortageQty,
      );
    }
    if (row.aggregate case final aggregate?) {
      return _aggregateShownQtyText(aggregate, net: true);
    }
    return row.material == null
        ? null
        // 汇总视图路径行的还缺数量取组内最粗守恒整分份额（父行=各路径之和）；
        // 组未建好或整分不可解析时退回该行自身的精确文本。
        : row.kind == _MaterialTableRowKind.aggregatePath
        ? (_aggregatePathShareText(row.material!, net: true) ??
              _tableShownQtyText(row.material!, net: true))
        : _tableShownQtyText(row.material!, net: true);
  }

  /// 汇总视图路径行在其组内的最粗守恒整分份额文本；组投影未建好或整分
  /// 不可解析返回 null（调用方退回精确口径）。
  String? _aggregatePathShareText(
    ProductionMaterialAnalysisMaterial material, {
    required bool net,
  }) {
    final aggregate = _aggregateByLineId[material.materialLineId];
    if (aggregate == null) return null;
    try {
      final shares = coalescedAggregateShareTexts([
        for (final path in aggregate.paths)
          _tableShownQtyText(path, net: net) ?? '',
      ]);
      final index = aggregate.paths.indexWhere(
        (path) => path.materialLineId == material.materialLineId,
      );
      return index < 0 ? null : shares[index];
    } on FormatException {
      return null;
    }
  }

  double? _materialTableAdditionalRecommendedQty(_MaterialTableRow row) =>
      row.contextOnly
      ? null
      // 顶层直购/直委外产品行（ROOT_SUPPLY 外部路线）沿用根供料行的建议量
      //（2026-09-06 用户口径：顶层待补数量不再显示「—」）；顶层自制产品
      // 的补货走「下达车间」，不在此列。
      : row.product != null && !_rootExternalSupplyRow(row)
      ? null
      // 汇总与各来源保留四位精确数量，不把合法小数粗化。
      : row.aggregate != null
      ? _aggregateShownTotal(row.aggregate!, net: false)
      : row.material == null
      ? null
      // 汇总视图的路径行显示组内整分份额，父行 = 各路径之和；
      // 与「还缺数量」「下单数量」同一份来源：父行改量之后三列必须一起变。
      : row.kind == _MaterialTableRowKind.aggregatePath
      ? _aggregatePathShownQty(row.material!, net: false)
      : _tableShownQty(row.material!).residual;

  // ==================== ADR-102 一张表：数量、办理与指派 ====================
  //
  // 这一段把原先分散在三个分桶详情页与「父件 + 下层一起下单」弹窗里的能力
  // 收进主表：行内填「下单数量 / 追加下单」、按行办理(调拨 / 下达)、下达车间
  // 前就地指派生产车间与负责人。容器仍是 MasterDataTableView——分桶详情页
  // 已经证明它能在 cellBuilder 里放输入框、控制器交给宿主 State 托管，
  // 因此列显隐/列序/列宽/表头筛选这些主表既有能力一个都不用丢。

  /// 行内「下单数量」输入(键 = [_MaterialGroup.key]，即服务端的提交单元身份)。
  ///
  /// 控制器由宿主 State 持有而不是挂在行对象上：主表的行每次投影都会重建，
  /// 且带客户端分页，挂在行上会翻一页就丢一次用户填的数。
  final Map<String, TextEditingController> _tableOrderQtyControllers = {};

  /// 行内「追加下单」输入(键同上)。已下达的行填这里，填 0 = 本次不动它；
  /// 预填 = 这一行此刻的缺口(还需安排)，父行追加把缺口抬起来时跟着回填。
  final Map<String, TextEditingController> _tableAppendQtyControllers = {};

  /// 父行改量 / 亲手填数时**替用户勾上**的行(键 = [_MaterialGroup.key])。
  /// 只有这里记着的行会在数量回落到 0 时自动撤勾——用户亲手勾的不动。
  final Set<String> _tableAutoSelectedKeys = {};

  /// 用户亲手撤过勾的行：父行再改量也不替他勾回来，直到他自己再勾上 / 再填数。
  final Set<String> _tableUserDeselectedKeys = {};

  /// 亲手填了数却勾不上的行, 已经当场说过的原因(键 = 行 key)：同一行同一原因只说一次,
  /// 逐位敲数不刷屏; 原因变了(比如刚指了车间还缺负责人)再说一次。
  final Map<String, String> _tableTypedBlockedNotices = {};

  /// 系统预填过的文本快照：轮询刷新只回填「用户没动过」的格子，
  /// 已经被人改过的一律保留，不让后台刷新吃掉手输的数。
  final Map<String, String> _tableSeededQtyTexts = {};

  /// 用户**亲手填过**的数量(键 = materialLineId)。
  ///
  /// 送给服务端重算的只能是这一份，绝不能送界面显示值：服务端那侧按
  /// 计划产出量单调向上取 max，把回显值送回去会把整棵子树钉在旧数上。
  /// 清空输入框 = 从这里移除 = 把这一行交还给系统算。
  final Map<String, double> _tableUserTypedQty = {};

  /// 父行改量之后，服务端算出的「下达之后」快照(ADR-099；ADR-116 起为只读投影)。
  ///
  /// **只用于展示子层数量，绝不替换权威快照 [_analysis]**：它是「假如按这些数下达」
  /// 的投影，库里并没有这些计划。提交一律按 [_analysis] 走，否则就是拿假设当依据下单。
  ProductionMaterialAnalysisView? _tableCascadePreview;
  int _tableCascadeGeneration = 0;
  Timer? _tableCascadeDebounce;
  bool _tableCascadePreviewing = false;

  /// 预览单飞 + 尾随(ADR-116)：同一时刻最多 1 个预览在途；在途期间又改了数只记
  /// [_tableCascadeTrailing]，这一趟回来后按**最新**填数补发一次(中间那些填数不发)。
  bool _tableCascadeInFlight = false;
  bool _tableCascadeTrailing = false;
  CancelToken? _tableCascadeCancelToken;

  /// [_tableCascadePreview] 是按哪一份「用户亲手填的数」算出来的(键 = materialLineId)；
  /// 权威快照对应空表。当场换算下层的**分母**必须按它算：那份快照里子层的数字是
  /// 按这些数展开的，不是按此刻框里的数——服务端那趟在路上时用户又改了数，
  /// 回来以后也要拿它把这期间多改的那部分就地补算，屏幕才不会先跳回旧数字。
  Map<String, double> _tableCascadePreviewTyped = const {};

  /// 服务端只读预览返回前的即时估算，按物料行保存。预览覆盖估算，
  /// 真实提交仍由服务端核对数量和来源；估算不是库存或下单事实。
  final Map<String, _TableQty> _tableEstimatedQty = {};

  /// 「敲一下当场变」只通知**依赖估算值的那几个格子**自己重建(还缺数量 /
  /// 下单数量的红框)，不整页 setState。实测(debug, 300 行)整页重建一帧 260-450ms，
  /// 而只重绘输入框那一帧 13-20ms——整页重建就是「速度不够快」的全部成本。
  /// 依赖估算但不逐格监听的东西(还缺数量的底色、表头筛选桶、底部按钮)由
  /// [_tableEstimateRebuild] 在停手 200ms 后一次性刷新。
  final ValueNotifier<int> _tableEstimateTick = ValueNotifier<int>(0);
  Timer? _tableEstimateRebuild;

  @override
  void dispose() {
    _tableEstimateRebuild?.cancel();
    _tableEstimateTick.dispose();
    _tableAssignmentTick.dispose();
    super.dispose();
  }

  /// 批量可调拨量(materialLineId -> 可调入数量)。空表示还没取到或无可调。
  Map<String, double> _tableTransferableIn = const {};

  /// 与 [_tableTransferableIn] 同生命周期的会话作用域键：切账号后丢弃迟到响应。
  String? _tableTransferableInScope;
  bool _tableTransferableInLoading = false;

  /// 下达车间前的就地指派草稿(键 = [_MaterialGroup.key])。
  final Map<String, ({String? id, String? name})> _tableWorkshopDraft = {};
  final Map<String, ({String? id, String? name})> _tableWorkerDraft = {};

  /// 页面销毁时统一释放行内输入控制器。
  @override
  void _disposeMaterialTableInputs() {
    _aggregateTable.dispose();
    _tableCascadeDebounce?.cancel();
    _tableCascadeDebounce = null;
    // 离开页面 / 换分析：在途的那份预览直接丢掉，也不再补发。
    _tableCascadeTrailing = false;
    _tableCascadeCancelToken?.cancel('material table preview disposed');
    _tableCascadeCancelToken = null;
    _tableEstimateRebuild?.cancel();
    _tableEstimateRebuild = null;
    for (final controller in _tableOrderQtyControllers.values) {
      controller.dispose();
    }
    for (final controller in _tableAppendQtyControllers.values) {
      controller.dispose();
    }
    _tableOrderQtyControllers.clear();
    _tableAppendQtyControllers.clear();
  }

  @override
  void _resetMaterialTableInputsForNewAnalysis() {
    _disposeMaterialTableInputs();
    _preparationPlanResults.clear();
    _preparationApproveChoice = null;
    _preparationUseAvailableQty = null;
    _tableSeededQtyTexts.clear();
    _tableUserTypedQty.clear();
    _tableAutoSelectedKeys.clear();
    _tableUserDeselectedKeys.clear();
    _tableCascadePreview = null;
    _tableCascadePreviewTyped = const {};
    _tableEstimatedQty.clear();
    _tableCascadeGeneration++;
    // 在途那份已被取消且代际作废，不会再走到复位预览态的 finally。
    _tableCascadePreviewing = false;
    _tableWorkshopDraft.clear();
    _tableLastReseedRoots.clear();
    _tableWorkerDraft.clear();
    _tableTransferableIn = const {};
    _tableTransferableInScope = null;
    _tableAssignmentScope = null;
    _tableAssignmentGeneration++;
  }

  /// 这一行是不是「持有输入框」的行：只有恰好对应一个提交单元的物料行才可填。
  /// 汇总视图的聚合行、分页补的上下文行、产品行都只作展示。
  ///
  /// **可勾判据必须与它对齐**：聚合行这五列全是横杠，却照样能勾、能计进
  /// 「下单(N)」的话，提交用的就是界面上从没显示过的隐藏默认值——直接违反
  /// 「看到的勾选 = 提交的内容」。2026-09-22 对抗复查抓出来的真缺陷。
  /// 这一行是不是「持有输入框、能被办理」的行。
  ///
  /// **2026-09-22 修订：顶层产品行不再一律排除。** V478 之后产品行直接承载真实的
  /// ROOT_SUPPLY 节点(建行时就挂了 `material: rootMaterial` 与根供给 `group`，
  /// 并把根物料行从子行里剔掉不再单独渲染)，它恰恰是「这个产品到底自己做、还是买、
  /// 还是外发」的那一行。原来在这里一律返回 null，导致顶层的物料办理 / 下单数量 /
  /// 追加下单 / 生产车间 / 负责人五列全是横杠，而「还缺数量」走的是另一套判据、
  /// 对已确认采购或委外的顶层行**会显示真实数字** —— 于是同一行左边看得见
  /// 缺口、右边办不了事。这条排除没有 ADR 依据也没有用例覆盖，是 ADR-102 之前的
  /// 实现惯性，与「把顶层父件 + 下层一起下单搬进这张表」的立意相反。
  ///
  /// 仍然排除的两类没变：分页补的只读上下文行、汇总视图的聚合行(它五列全横杠，
  /// 可勾会让人提交界面上从没显示过的默认值)；没有根供给组的产品行由
  /// [_materialRowAllGroups] 返回空列表自然落空。
  _MaterialGroup? _tableEditableGroup(_MaterialTableRow row) {
    if (row.contextOnly || row.aggregate != null) return null;
    // 用「全部操作组」而不是「可改路线的组」：已下达的行照样要能填追加。
    final groups = _materialRowAllGroups(row);
    return groups.length == 1 ? groups.first : null;
  }

  /// 还缺数量优先使用本次有效选择的临时预算。其共享池和私有覆盖均来自服务端，
  /// 不从仓库合计反推；无明确池信息时仍展示服务端净缺口。
  ///
  /// 2026-09-22：顶层放开办理后，这一列与办理/下单两列收口到同一条判据 ——
  /// 有根供给组的产品行照常显示它自己的缺口，没有的才是横杠。原来只对
  /// 「已确认非自制路线」的顶层行显示，顶层自制明明也能下达车间却看不到缺口。
  ///
  /// 数值投影供颜色/状态使用；文字、列计算与导出共用原文精确合计。
  double? _materialTableNetShortageQty(_MaterialTableRow row) => row.contextOnly
      ? null
      : row.product != null && row.group == null
      ? null
      : _tableBudgetOf(row)?.netShortageQty ??
            (row.aggregate != null
                ? _aggregateShownTotal(row.aggregate!, net: true)
                : row.material == null
                ? null
                : row.kind == _MaterialTableRowKind.aggregatePath
                ? _aggregatePathShownQty(row.material!, net: true)
                : _tableShownQty(row.material!).net);

  /// 本提交单元累计已下单量。
  ///
  /// 三条来源不是随便选的：顶层自制行的计划挂在产品行自己身上(它本身就是排产对象，
  /// 没有锚点——2026-09-23 前这里漏了它：顶层下了 2000 的计划，主表照旧给它一个可填
  /// 的「下单数量」，再全选下单就把它当新计划重下，服务端 409 整批停在第一步)；
  /// 其余已建自制锚点的行，真实已下达量在锚点产品的计划总量上(含公共备货产出)；
  /// 采购 / 委外的行在申请明细上 = 归本需求的分摊量 + 同一条行动记的
  /// 公共备货份。一行只可能是其中一种，不会同时成立。
  ///
  /// [authoritative] = 只看权威快照(下单后比对「这次刚下了什么」用，ADR-117)：模拟快照里
  /// 的锚点计划量已经按「假如下达」放大过，拿它当基线会把没下的量算成已下。
  double _tableGroupIssuedQty(
    _MaterialGroup group, {
    bool authoritative = false,
  }) {
    final preparation = _tablePreviewed(
      group.representative,
      authoritative: authoritative,
    ).aggregatePreparation;
    if (preparation != null) return preparation.allocatedOrderedQty;
    final route = _draftRoute(group);
    // 自制行按锚点产品的计划总量(含计划多下的公共备货产出)。委外与采购一样按
    // 申请明细算(ADR-143：委外节点只下达委外申请，没有车间锚点)。
    if (_tableUsesMakeAnchor(group)) {
      final anchor = _tableMakeAnchorOf(group, authoritative: authoritative);
      return anchor == null
          ? 0
          : anchor.issuedPlanQty * _tableAnchorUnitRate(group, anchor);
    }
    final legacyAnchor = _tableLegacyAnchorWithSharedSupply(
      group,
      authoritative: authoritative,
    );
    var ordered = legacyAnchor == null
        ? 0.0
        : legacyAnchor.issuedPlanQty *
              _tableAnchorUnitRate(group, legacyAnchor);
    for (final path in group.paths) {
      for (final target in path.notifiedTargets) {
        if (target.target != route ||
            target.isRootOutput ||
            target.status == 'CANCELLED') {
          continue;
        }
        // 跨计划调拨与公共在途认领也会投影进 downstreamReferences, 而且服务端按
        // **目标行的确认路线**归位, 所以路线过滤拦不住它们。它们只是把别处的在途
        // 份额搬过来, 本行一张订货单都没下——算成「已下单」会让这一行的下单数量
        // 格被锁死、追加默认 0、批量下单静默跳过它。这是 2026-09-22 对抗复查抓出
        // 来的真缺陷: 调拨恰恰是主表「物料办理」列主推的第一个动作。
        if (const {
          'FUTURE_TRANSFER',
          'SHARED_FUTURE_CLAIM',
        }.contains(_supplyOperationType(target.actionId))) {
          continue;
        }
        if (legacyAnchor != null &&
            _supplyOperationType(target.actionId) != 'AGGREGATE_SUPPLY') {
          continue;
        }
        final allocated = target.allocatedQty ?? 0;
        ordered += allocated;
        // 填得比当时需求多的部分，服务端记在同一条行动的公共备货份上(V577/V589)，
        // 申请明细上就是两者的合计。它同样是这一行下出去的单——不算的话，填 5000
        // 下成「需求 2000 + 公共 3000」的行会显示成「累计已下单 2000」，用户实机
        // 看到的就是「我填了 5000 怎么只下了 2000」(2026-09-23)。
        // 一条行动可能分摊到多条物料行(各一条 allocation)，公共份按本行分摊量占行动
        // 需求份的比例摊，几条行加起来正好是整条行动的公共份，不会每行都算一遍。
        final action = _supplyActionOf(target.actionId);
        if (action != null &&
            action.publicSurplusQty > 0 &&
            _supplyOperationType(target.actionId) != 'AGGREGATE_SUPPLY') {
          final share = action.requestedQty > 0.0001
              ? (allocated / action.requestedQty).clamp(0.0, 1.0)
              : 1.0;
          ordered += action.publicSurplusQty * share;
        }
      }
    }
    return ordered;
  }

  /// 顶层产品行的计划量是来源单位(销售单位)，物料行是基本单位，两边差一个
  /// 单位换算率；锚点子件行与物料行同单位，换算率为 1。
  double _tableAnchorUnitRate(
    _MaterialGroup group,
    ProductionMaterialAnalysisProduct anchor,
  ) => _tableIsRootSupply(group.representative) ? (anchor.unitRate ?? 1) : 1;

  bool _tableIsRootSupply(ProductionMaterialAnalysisMaterial material) {
    if (material.isRootSupply) return true;
    final analysis = _analysis;
    return analysis != null &&
        _analysisIndexes(
              analysis,
            ).productsById[material.analysisLineId]?.rootMaterialLineId ==
            material.materialLineId;
  }

  /// 自制行的计划锚点产品：顶层自制行就是产品行自己(它本身是排产对象，没有锚点)，
  /// 其余自制行是 planAnchorAnalysisLineId 指向的子件任务行；没建过锚点返回 null。
  ///
  /// 有模拟快照(父行改量后服务端算好的「下达之后」)时读它里面那一份：锚点的剩余
  /// 可排量已随父件长大，与物料行取 [_tablePreviewed] 是同一口径。
  /// [authoritative] = 只看权威快照(自动勾选判基线用)，与 [_tablePreviewed] 同一开关。
  ProductionMaterialAnalysisProduct? _tableMakeAnchorOf(
    _MaterialGroup group, {
    bool authoritative = false,
  }) {
    final analysis = _analysis;
    if (analysis == null) return null;
    final material = group.representative;
    final anchorId = _tableIsRootSupply(material)
        ? material.analysisLineId
        : material.planAnchorAnalysisLineId;
    if (anchorId == null) return null;
    final previewed = authoritative
        ? null
        : _tableCascadePreview?.products
              .where((product) => product.analysisLineId == anchorId)
              .firstOrNull;
    return previewed ?? _analysisIndexes(analysis).productsById[anchorId];
  }

  /// 已下过单的自制行(含顶层)的锚点产品；不是这类行返回 null。
  ProductionMaterialAnalysisProduct? _tableIssuedMakeAnchorOf(
    _MaterialGroup group, {
    bool authoritative = false,
  }) {
    if (!_tableUsesMakeAnchor(group)) return null;
    final anchor = _tableMakeAnchorOf(group, authoritative: authoritative);
    return anchor != null && anchor.issuedPlanQty > 0 ? anchor : null;
  }

  /// 残差是否精确为零（10^-4 tick 口径）。来源不可核对时返回 false：
  /// 没有证据就不把这一行当「无剩余、纯公共备货」。
  bool _tableExactResidualZero(_MaterialGroup group) {
    try {
      final text = _tableGroupResidualText(group);
      if (text == 'NaN') return false;
      return materialQuantityUnits(text) == BigInt.zero;
    } on FormatException {
      return false;
    }
  }

  /// 这一行的「已下达 / 还需安排 / 能不能再追加」是不是按计划锚点判：只有自制行
  /// (它的下达是 issue-plans 出计划, 锚点产品才是事实源)。与级联页
  /// `preparationAnchor` 同一口径。
  bool _tableUsesMakeAnchor(_MaterialGroup group) =>
      group.representative.aggregatePreparation == null &&
      !group.paths.any(
        (path) => path.notifiedTargets.any(
          (target) =>
              target.status != 'CANCELLED' &&
              _supplyOperationType(target.actionId) == 'AGGREGATE_SUPPLY',
        ),
      ) &&
      _draftRoute(group) == MaterialSupplyRoute.make;

  ProductionMaterialAnalysisProduct? _tableLegacyAnchorWithSharedSupply(
    _MaterialGroup group, {
    bool authoritative = false,
  }) {
    if (!group.paths.any(
      (path) => path.notifiedTargets.any(
        (target) =>
            target.status != 'CANCELLED' &&
            _supplyOperationType(target.actionId) == 'AGGREGATE_SUPPLY',
      ),
    )) {
      return null;
    }
    final anchor = _tableMakeAnchorOf(group, authoritative: authoritative);
    if (anchor == null || anchor.sourceType == 'AGGREGATE_MAKE') return null;
    return _draftRoute(group) == MaterialSupplyRoute.make ? anchor : null;
  }

  /// 这一行下过单没有(下过 = 下单数量列锁死、改填追加下单列)。
  bool _tableGroupIssued(_MaterialGroup group) =>
      _tableGroupDisplayedIssuedQty(group) > 0 ||
      group.paths.any((path) => path.preparationAdoptedQty > 0) ||
      (group.representative.aggregatePreparation?.totalOrderedQty ?? 0) > 0;

  double _tableGroupDisplayedIssuedQty(_MaterialGroup group) =>
      group.representative.aggregatePreparation?.orderedQty ??
      _tableGroupIssuedQty(group, authoritative: true);

  /// 同料合并共享批次的转交份额：这一行的需求**整体**转入共享制造批次时返回
  /// 正数；部分需求仍在本行、或没有转交时返回 null。
  ///
  /// 需求转走后本行 requiredQty 归零、也没有自己的下单引用——没有这一支，
  /// 产品视图只能把这些行显示成「可填的 0」(2026-09-26 用户实机「下单数量
  /// 大部分是 0、超量下的也没锁」)。份额来自服务端逐来源行累计的别名量，
  /// 各行份额加起来正好是共享批次的总量。
  double? _tableAggregateDelegatedShare(_MaterialGroup group) {
    var share = 0.0;
    for (final path in group.paths) {
      if (path.requiredQty > 0.0001) return null;
      share += path.aggregateDelegatedQty;
    }
    return share > 0.0001 ? share : null;
  }

  /// 本提交单元本次要**覆盖**的量 = 「下单数量」列的预填值与提交值。
  ///
  /// **必须用毛口径 additionalSupplyRecommendedQty, 不能用「还缺数量」那个净数。**
  /// 服务端下达时是 demandQty = requested.min(delta) 之后再从中减掉自动认领的公共
  /// 在途——认领是从你填的这个数里切走的, 不是在它之上另加。填净数的话, 需求 1000、
  /// 可认领 300 时填 700 只换来「认领 300 + 新单 400 = 700」, 对着 1000 仍差 300,
  /// 每一行都少下一个认领量。这是 2026-09-22 对抗复查抓出来的真缺陷。
  ///
  /// 父行改量之后取当场换算的估算值，服务端那份重算回来再整体覆盖；
  /// [authoritative] = 只看权威快照(不看模拟快照与估算)，自动勾选拿它当基线。
  /// 已下过单的自制行(含顶层)按锚点产品的剩余可排量，见 [_tableAnchorResidual]。
  double _tableGroupResidual(
    _MaterialGroup group, {
    bool authoritative = false,
  }) => group.paths.fold<double>(
    0,
    (sum, material) =>
        sum + _tableShownQty(material, authoritative: authoritative).residual,
  );

  /// 顶层自制行要走的「产品行排产」通道的 analysisLineId；不是这类行就返回 null。
  ///
  /// 顶层自制不是车间候选、也不该走 notify(自制路线在 notifySupply 开头就被拒),
  /// 它本身就是排产对象, 要按产品的 analysisLineId 送进 issue-plans 的 planDrafts。
  /// 顶层委外与其它委外行一样走 notify 下达委外申请(ADR-143)。
  String? _tableRootMakePlanLineId(_MaterialGroup group) {
    final material = group.representative;
    if (!_tableIsRootSupply(material)) return null;
    if (_draftRoute(group) != MaterialSupplyRoute.make) return null;
    return material.analysisLineId;
  }

  /// 自制行这次填的数比本行「还需安排」少多少；不少就返回 null。
  ///
  /// **只提示，不拦提交。** 填少了并不会丢东西：没下的那部分仍旧留在这一行的
  /// 「还需安排」里，下一轮接着下，分批下达本来就是合法用法。真正「不能少」的是
  /// 「父件 + 下层一起下单」那个页面 —— 那里是同一次提交里子件必须盖住父件本批，
  /// 与主表逐行下单不是一回事，别把那条下限照搬过来把分批堵死。
  ({String shortBy, String typed, String floor})? _tableBelowMinimumBy(
    _MaterialGroup group,
  ) {
    if (_draftRoute(group) != MaterialSupplyRoute.make) return null;
    if (_tableGroupIssued(group)) return null;
    final text = _tableOrderQtyControllers[group.key]?.text;
    if (text == null || text.trim().isEmpty) return null;
    // 精确十进制口径：0.5 − 0.4999 的浮点差是 9.999…e-5，旧行为被 0.0001
    // 容差吞掉；按 10^-4 tick 相减，差一个 tick 也照实提示「少 0.0001」。
    try {
      final floor = _tableGroupResidualText(group);
      if (floor == 'NaN') return null;
      final typedUnits = materialQuantityUnits(text.trim());
      final floorUnits = materialQuantityUnits(floor);
      if (typedUnits >= floorUnits) return null;
      return (
        shortBy: materialQuantityText(floorUnits - typedUnits),
        typed: text.trim(),
        floor: floor,
      );
    } on FormatException {
      return null;
    }
  }

  TextEditingController _tableOrderQtyController(_MaterialGroup group) {
    final raw = _tableDefaultSubmitQtyText(group);
    final seeded = raw == 'NaN' ? '' : raw;
    return _tableOrderQtyControllers.putIfAbsent(group.key, () {
      _tableSeededQtyTexts['ORDER|${group.key}'] = seeded;
      return TextEditingController(text: seeded);
    });
  }

  /// 「追加下单」格：预填 = 这一行此刻的缺口(还需安排)。缺口为 0 的行就是 0
  /// (用户口径 2026-09-21：勾着不动 = 本次不下它，要追加才改成正数；0 是合法值，
  /// 不是「没填」)。父行追加把这一行的缺口抬起来时，没被人动过的格子跟着回填新
  /// 缺口(见 [_reseedTableQtyInputs])——用户口径 2026-09-22「父组件追加 200，
  /// 子组件追加那里也自动追加 200；子组件之前多下了的就不用追加」。
  TextEditingController _tableAppendQtyController(_MaterialGroup group) =>
      _tableAppendQtyControllers.putIfAbsent(group.key, () {
        final raw = _tableDefaultSubmitQtyText(group);
        final seeded = raw == 'NaN' ? '' : raw;
        _tableSeededQtyTexts['APPEND|${group.key}'] = seeded;
        return TextEditingController(text: seeded);
      });

  double _tableDefaultSubmitQty(
    _MaterialGroup group, {
    bool authoritative = false,
  }) {
    final quantity = _tableGroupResidual(group, authoritative: authoritative);
    final route = _draftRoute(group);
    return route == null
        ? quantity
        : _submitQtyWithOrderPolicy(group, route, quantity);
  }

  String _quantityFact(String? exact, double legacy) {
    return materialQuantityFact(exact, legacy);
  }

  String _tableGroupResidualText(
    _MaterialGroup group, {
    bool authoritative = false,
  }) {
    if (!authoritative &&
        group.paths.any(
          (path) => _tableEstimatedQty.containsKey(path.materialLineId),
        )) {
      return _qty(_tableGroupResidual(group)); // display-only local cascade
    }
    final parts = <String>[];
    for (final material in group.paths) {
      final shown = _tablePreviewed(material, authoritative: authoritative);
      if (shown.hasPriorityMakeSupplement) {
        parts.add(
          _quantityFact(
            shown.quantityFactsExact['priorityMakeSupplementQty'],
            shown.priorityMakeSupplementQty,
          ),
        );
      } else if (shown.aggregatePreparation case final preparation?) {
        parts.add(
          _quantityFact(
            preparation.planningUncoveredQtyExact,
            preparation.planningUncoveredQty,
          ),
        );
      } else {
        final anchor = _tableIssuedMakeAnchorOf(
          group,
          authoritative: authoritative,
        );
        if (anchor != null) {
          if (!anchor.canSchedule) {
            parts.add('0');
            continue;
          }
          final remaining = _quantityFact(
            anchor.quantityFactsExact['remainingQty'],
            anchor.remainingQty,
          );
          final rate = _tableIsRootSupply(group.representative)
              ? materialUnitRateFact(
                  anchor.quantityFactsExact['unitRate'],
                  anchor.unitRate,
                )
              : '1';
          if (remaining == 'NaN') return 'NaN';
          parts.add(materialQuantityProduct(remaining, rate));
        } else {
          parts.add(
            _quantityFact(
              shown.quantityFactsExact['additionalSupplyRecommendedQty'],
              shown.additionalSupplyRecommendedQty,
            ),
          );
        }
      }
    }
    return _aggregateTable.sumQuantityTexts(parts);
  }

  String _tableDefaultSubmitQtyText(
    _MaterialGroup group, {
    bool authoritative = false,
  }) {
    try {
      final quantity = _tableGroupResidualText(
        group,
        authoritative: authoritative,
      );
      if (quantity == 'NaN') return quantity;
      if (_draftRoute(group) != MaterialSupplyRoute.buy || !_canOverSupply) {
        return quantity;
      }
      final material = group.representative;
      return materialQuantityWithOrderPolicy(
        quantity,
        _quantityFact(
          material.quantityFactsExact['minOrderQty'],
          material.minOrderQty ?? 0,
        ),
        _quantityFact(
          material.quantityFactsExact['orderMultipleQty'],
          material.orderMultipleQty ?? 0,
        ),
      );
    } on FormatException {
      return 'NaN';
    }
  }

  /// 新快照回来后把系统预填值刷新一遍，但只覆盖「仍等于旧预填值」的格子。
  ///
  /// 这是主表铺开输入框之后必须补的一课：轮询与 409 恢复都会整树换快照，
  /// 不做这一步，用户填了一屏的数会被后台刷新静默吃掉。
  @override
  void _reseedMaterialTableQtyInputs() =>
      _reseedTableQtyInputs(autoSelect: false);

  /// 把系统预填值刷新一遍，但只覆盖「仍等于旧预填值」的格子——下单格与追加格
  /// 都是。
  ///
  /// [autoSelect] = 这次回填是父行改量带出来的(敲键当场换算 / 服务端那份预览
  /// 回来)：被换算到的行回填后有数就替用户勾上、回落到 0 就撤掉替他勾的那个勾
  /// (用户口径 2026-09-22「有数值的都自动选中；子组件之前已经下单了 2000 那么
  /// 子组件就不用追加了」)。权威快照的例行刷新(轮询 / 别人下达后)不自动勾——
  /// 那不是这位用户的决定，勾选集必须只反映他自己的动作。
  void _reseedTableQtyInputs({required bool autoSelect}) {
    final analysis = _analysis;
    if (analysis == null) return;
    var selectionChanged = false;
    _draftBudget.invalidate();
    final activeTyped = _selectedTableTypedOutputs();
    final presentation = _bomPresentation(analysis);
    final activeRoots = {
      for (final id in activeTyped.keys)
        presentation.rootIdsByMaterial[id] ?? id,
    };
    final pendingRoots = {
      ...activeRoots,
      for (final id in _tableCascadePreviewTyped.keys)
        presentation.rootIdsByMaterial[id] ?? id,
    };
    final affectedRoots = {...pendingRoots, ..._tableLastReseedRoots};
    final parents = presentation.parentIdsByMaterial;
    final affected = <String, bool>{};
    bool hasTypedAncestor(String lineId) {
      final trail = <String>{};
      var parent = parents[lineId];
      var result = false;
      while (parent != null && trail.add(parent)) {
        if ((activeTyped[parent] ?? 0) > 0) {
          result = true;
          break;
        }
        if (affected.containsKey(parent)) {
          result = affected[parent]!;
          break;
        }
        parent = parents[parent];
      }
      affected[lineId] = result;
      return result;
    }

    for (final group in _analysisIndexes(analysis).groupsByKey.values) {
      final typed = _tableUserTypedQty[group.representative.materialLineId];
      final root =
          presentation.rootIdsByMaterial[group.representative.materialLineId] ??
          group.representative.materialLineId;
      if (typed == null && (!autoSelect || affectedRoots.contains(root))) {
        _reseedTableQtyCell(group, append: false);
        _reseedTableQtyCell(group, append: true);
      }
      if (!autoSelect) continue;
      // 勾选跟真实需求走，不依赖某个输入框是否已经渲染。折叠、分页和虚拟滚动
      // 下的子件也参与级联；手填只保护数量，不能使这一行永久脱离选中同步。
      final value = _tableGroupResidual(group);
      final baseline = _tableGroupResidual(group, authoritative: true);
      final driven =
          (value - baseline).abs() > 0.0001 ||
          hasTypedAncestor(group.representative.materialLineId);
      if (_autoSelectTableGroup(
        group,
        select: typed != null ? typed > 0 : driven && value >= 0.00005,
      )) {
        selectionChanged = true;
      }
    }
    _draftBudget.invalidate();
    if (autoSelect) {
      _tableLastReseedRoots
        ..clear()
        ..addAll(pendingRoots);
    }
    if (selectionChanged) _scheduleTableEstimateRebuild();
  }

  /// 回填一格的系统预填值；用户自己的格子返回 null，否则返回回填后的数。
  ///
  /// 一旦发现这一格与上次系统预填值不同，就**永久**判给用户：把 seed 键删掉，
  /// 以后任何一次刷新都不再覆盖它。
  ///
  /// 原先是「不覆盖但把 seed 写成新值」，那样只要系统算出的新预填值某一次
  /// 恰好等于用户手填的数，这一格就被重新归类成「系统预填」，下一次刷新就把
  /// 它冲掉。2026-09-22 对抗复查抓出来的真缺陷。
  double? _reseedTableQtyCell(_MaterialGroup group, {required bool append}) {
    final controller = append
        ? _tableAppendQtyControllers[group.key]
        : _tableOrderQtyControllers[group.key];
    if (controller == null) return null;
    final seededKey = '${append ? 'APPEND' : 'ORDER'}|${group.key}';
    if (controller.text != _tableSeededQtyTexts[seededKey]) {
      _tableSeededQtyTexts.remove(seededKey);
      return null;
    }
    final value = _tableDefaultSubmitQty(group);
    final raw = _tableDefaultSubmitQtyText(group);
    final next = raw == 'NaN' ? '' : raw;
    // 没变就不写：每次赋值都会通知那个 TextField 重建，一屏几十个格子白跑。
    if (controller.text != next) controller.text = next;
    _tableSeededQtyTexts[seededKey] = next;
    return value;
  }

  /// 亲手填了数却勾不上的行(缺车间 / 负责人、已排满、缺权限……)：当场把原因说出来。
  ///
  /// 数量格只要有下达权限就是开着的, 「这一行为什么下不了单」原本只藏在格子的悬浮说明里
  /// ——顶层追加时「子层都勾上了、顶层自己没勾」就是这么来的(2026-09-22 用户实机)：
  /// 顶层缺生产车间 / 负责人的学习默认值, 填了数、子层照带, 自己却静静地勾不上。
  void _noticeTableTypedRowBlocked(_MaterialGroup group) {
    final reason = _tableIssueBlockedReason(group);
    if (reason == null) return;
    if (_tableTypedBlockedNotices[group.key] == reason) return;
    _tableTypedBlockedNotices[group.key] = reason;
    final name =
        group.representative.goodsName ??
        group.representative.goodsCode ??
        '这一行';
    context.appWarning('「$name」填了数但本次还下不了单：$reason');
  }

  /// 车间 / 负责人指好之后, 亲手填过数的行立刻替他勾上——填数在前、指派在后是主表上
  /// 最自然的顺序, 不能让人再回去把数删掉重填一遍才勾得上。
  void _reselectTypedRowAfterAssignment(_MaterialGroup group) {
    final typed = _tableUserTypedQty[group.representative.materialLineId];
    if (typed == null || typed <= 0) return;
    _tableTypedBlockedNotices.remove(group.key);
    if (_autoSelectTableGroup(group, select: true)) {
      _tableSelectionChanged();
    } else if (!_selectedMaterialGroupKeys.contains(group.key)) {
      _noticeTableTypedRowBlocked(group);
    }
  }

  /// 替用户勾上 / 撤掉一行(父行改量带出来的、或他亲手填了数的)。返回勾选集有没有变。
  ///
  /// 只撤本方法自己勾上的行；用户亲手撤过勾的行不再替他勾回来。不可勾的行
  /// (缺权限 / 这一行本次下不了单)一律不碰。
  bool _autoSelectTableGroup(_MaterialGroup group, {required bool select}) {
    final key = group.key;
    if (select) {
      if (_selectedMaterialGroupKeys.contains(key) ||
          _tableUserDeselectedKeys.contains(key) ||
          !_canSelectMaterialRows ||
          _tableIssueBlockedReason(group) != null) {
        return false;
      }
      _selectedMaterialGroupKeys.add(key);
      _tableAutoSelectedKeys.add(key);
      _draftBudget.invalidate();
      return true;
    }
    if (!_tableAutoSelectedKeys.remove(key)) return false;
    final changed = _selectedMaterialGroupKeys.remove(key);
    if (changed) _draftBudget.invalidate();
    return changed;
  }

  /// 依赖估算 / 勾选但不逐格监听的东西(还缺数量底色、表头筛选桶、底部按钮、
  /// 勾选框)停手 200ms 后一次性刷新，不在每一拍敲键上整页重建。
  void _scheduleTableEstimateRebuild() {
    _tableEstimateRebuild?.cancel();
    _tableEstimateRebuild = Timer(const Duration(milliseconds: 200), () {
      _tableEstimateRebuild = null;
      if (mounted) setState(() {});
    });
  }

  /// 「下单数量」格此刻是不是填错了 / 填少了(用户口径 2026-09-22「数量填的不对的
  /// 或者缺的都要输入框冒红……父类下了 1000，子类需要 1000，输入小于 1000 就冒红，
  /// 一输入就冒红直到输入正确」)：空 / 不是数 / 不大于 0 / 小于这一行此刻的
  /// 「还需安排」。还需安排随父行的估算当场变，所以红框同时订阅估算 tick。
  bool _tableOrderQtyInvalid(_MaterialGroup group) {
    final text = _tableOrderQtyControllers[group.key]?.text.trim() ?? '';
    // 2026-10-07 数量完整性：与汇总下单格同一口径的精确十进制下限——差一个
    // 10^-4 tick 也红（0.4999 < 0.5），万亿级大数不进 double（…9998 与 …9999
    // 不再坍缩成同一个数）；来源数量不可核对时 fail closed 冒红拦下。
    if (!_aggregateTable.validText(text)) return true;
    final String floor;
    try {
      floor = _tableGroupResidualText(group);
    } on FormatException {
      return true;
    }
    if (floor == 'NaN') return true;
    try {
      final typedUnits = materialQuantityUnits(text);
      if (typedUnits == BigInt.zero) return true;
      return typedUnits < materialQuantityUnits(floor);
    } on FormatException {
      return true;
    }
  }

  /// 「追加下单」格：0 是合法值(本次不追加)，填多少都行；只有空 / 不是数 / 负数
  /// 才冒红。已下达的行追加的是**额外**的量，不拿它跟还需安排比——用户口径
  /// 2026-09-22「下单后追加的填多少都应该可以，不用冒红」(此前追加量小于还需
  /// 安排也描红，等于逼人每次追加都至少补齐缺口)。
  bool _tableAppendQtyInvalid(_MaterialGroup group) {
    final text = _tableAppendQtyControllers[group.key]?.text.trim() ?? '';
    final typed = double.tryParse(text);
    return text.isEmpty || typed == null || !typed.isFinite || typed < 0;
  }

  /// 权威快照更新后作废旧预览，防止迟到的模拟量覆盖入库/下单回执。
  @override
  void _invalidateMaterialTableCascadePreview() {
    _draftBudget.invalidate();
    if (_tableCascadePreview == null &&
        _tableEstimatedQty.isEmpty &&
        _tableUserTypedQty.isEmpty) {
      return;
    }
    _tableCascadePreview = null;
    _tableCascadePreviewTyped = const {};
    _tableCascadeGeneration++;
    if (_tableSubmitting) {
      // 分段提交进行中：每段成功后的新快照里已经含刚下达的量，而那些行填的数还没
      // 来得及从 _tableUserTypedQty 摘掉——此刻重估会把「已下达 + 本次填的」再叠一遍，
      // 整棵子树翻倍，下一段据此判纯公共备货就错(2026-09-23 对抗复查)。期间一律
      // 只看快照，批完由 _submitMaterialTableRows 统一重估一次。
      _tableEstimatedQty.clear();
      return;
    }
    // 用户填过的数还在：先按新的权威快照就地重估一遍(屏幕不闪回旧数字)，
    // 再要服务端重算一遍下层。
    _recomputeTableEstimates();
    // 一批提交进行中不发预览：每段成功后本方法都会被 _applyAnalysis 叫到，原来接着
    // 就去抖发一次 preview——它带着已经落库那些行填的数(服务端是「已下达 + 本次
    // 填的」，等于把刚下达的量再加一遍)，还与下一段真实提交撞同一把分析锁：等到
    // 锁时来源集合已变，服务端自动重跑一次后又因版本过期 409，只换来一串冲突日志
    // (2026-09-23 实机：一批 5 段提交伴着 4 条 409 的预览)。批完由
    // _submitMaterialTableRows 统一决定要不要补一次。
    if (_selectedTableTypedOutputs().isNotEmpty &&
        !_tableSubmitting &&
        !_preparationSubmissionActive) {
      _tableCascadeDebounce?.cancel();
      _tableCascadeDebounce = Timer(
        const Duration(milliseconds: 300),
        () => unawaited(_refreshTableCascadePreview()),
      );
    }
  }

  /// 主表「下单(N)」的分段编排正在进行：期间不自动发层级预览。
  bool _tableSubmitting = false;

  @override
  void _cancelPreparationEditorPreview() {
    _tableCascadeDebounce?.cancel();
    _tableCascadeTrailing = false;
    _tableCascadeGeneration++;
    _tableCascadeCancelToken?.cancel('submission superseded editor preview');
    _tableCascadeCancelToken = null;
    _tableCascadeInFlight = false;
    _tableCascadePreviewing = false;
  }

  // ---------------- 父行改量带动子层(ADR-116 只读预览) ----------------

  /// 这一行在树上还有没有下层：只有带下层的行改量才值得惊动服务端重算。
  ///
  /// 按**表上画出来的那棵树**判(`_bomPresentation` 的父子链)，不按 `parentNodeKey`
  /// 原始桶：顶层产品行的第 1 层子件 `parentNodeKey` 是空的，按原始桶查顶层
  /// 永远「没有下层」——在顶层产品行改数既不当场换算、也不问服务端，正是用户
  /// 2026-09-22 实机看到的「主表改数值没反应」。
  bool _tableGroupHasChildren(_MaterialGroup group) {
    final analysis = _analysis;
    if (analysis == null) return false;
    final parents = _bomPresentation(analysis).parentIdsByMaterial;
    final ids = {for (final path in group.paths) path.materialLineId};
    return parents.values.any(ids.contains);
  }

  /// 页面级去抖、单飞并尾随最新人工输入，避免每行独立排预览请求。
  void _onTableQtyTyped(_MaterialGroup group, String text) =>
      _recordTableTypedQty(group, orderText: text);

  /// 首次下单与追加共用原行身份，但每次只读取当前有效列。
  void _onTableAppendQtyTyped(_MaterialGroup group, String text) =>
      _recordTableTypedQty(group, appendText: text);

  /// 记下用户**亲手填的值**，并安排一次服务端重算。
  ///
  /// 只读当前可编辑的数量列，与提交使用同一口径。下单成功后旧下单控制器仍会
  /// 保留，不能把它与追加量相加，否则预览会把历史下单量重复展开到子件。
  void _recordTableTypedQty(
    _MaterialGroup group, {
    String? orderText,
    String? appendText,
  }) {
    final lineId = group.representative.materialLineId;
    double? parse(String? text) {
      final trimmed = text?.trim() ?? '';
      if (trimmed.isEmpty) return null;
      final value = double.tryParse(trimmed);
      return value == null || !value.isFinite || value <= 0 ? null : value;
    }

    final issued = _tableGroupIssued(group);
    final total =
        parse(
          issued
              ? appendText ?? _tableAppendQtyControllers[group.key]?.text
              : orderText ?? _tableOrderQtyControllers[group.key]?.text,
        ) ??
        0;
    if (total <= 0) {
      // 两格都空 = 把这一行交还给系统算，不是「填了 0」。
      _tableUserTypedQty.remove(lineId);
    } else {
      _tableUserTypedQty[lineId] = total;
    }
    _draftBudget.invalidate();
    // 亲手填了数的行就是要下的行：有数就替他勾上(亲手填数比之前撤过的勾更新，
    // 所以先把「撤过勾」的记号抹掉)，清成空 / 0 就把替他勾的那个勾撤掉。
    if (total > 0) _tableUserDeselectedKeys.remove(group.key);
    _autoSelectTableGroup(group, select: total > 0);
    if (total > 0 && !_selectedMaterialGroupKeys.contains(group.key)) {
      _noticeTableTypedRowBlocked(group);
    } else if (total <= 0) {
      _tableTypedBlockedNotices.remove(group.key);
    }
    if (!_tableGroupHasChildren(group)) {
      _tableEstimateTick.value++;
      _scheduleTableEstimateRebuild();
      return;
    }
    // 敲一下当场变：先按比例把它下面每一层换算好并回填预填值(有数的子行顺手
    // 勾上)，再去抖要服务端那份权威重算。叶子行改量到不了这里。
    _recomputeTableEstimates();
    _reseedTableQtyInputs(autoSelect: true);
    // 不整页 setState：只让订阅了 tick 的格子(还缺数量 / 红框)重建，
    // 其余依赖估算的东西停手 200ms 后一次刷新。
    _tableEstimateTick.value++;
    _scheduleTableEstimateRebuild();
    _tableCascadeDebounce?.cancel();
    _tableCascadeDebounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_refreshTableCascadePreview()),
    );
  }

  /// 按用户填过的数向服务端要一份「下达之后」的快照，用它显示子层数量。
  ///
  /// 即时父子换算只用于输入反馈；服务端按实际来源覆盖与计划产出重新展开，
  /// 回包成为下一次估算的基线。输入未选中时不参与本次预览。
  Future<void> _refreshTableCascadePreview() async {
    if (_preparationSubmissionActive) return;
    if (_aggregateTable.hasDrafts) {
      await _aggregateTable.refreshPreview();
      return;
    }
    final analysis = _analysis;
    final warehouseId = _warehouseId;
    if (analysis == null || warehouseId == null || !mounted) return;
    final sessionScope = _sessionScopeKey();
    final activeTyped = _selectedTableTypedOutputs();
    if (activeTyped.isNotEmpty && _tableCascadeInFlight) {
      // 单飞：上一份还在路上，只记「回来后按最新填数再要一次」。在途那份照常装上
      // (它的分母是请求时的填数，回来后按此刻的数就地补算)，不作废。
      _tableCascadeTrailing = true;
      return;
    }
    // 代际先推：用户把输入清空时也要占一个代际，否则上一次在途的预览回来时
    // `generation != _tableCascadeGeneration` 判定为假，那份**已被撤销的输入**
    // 派生出来的模拟快照会照样装上去，之后全表的数字与预填都来自它。
    final generation = ++_tableCascadeGeneration;
    if (activeTyped.isEmpty) {
      _tableCascadeTrailing = false;
      if (_tableCascadePreviewing) {
        setState(() => _tableCascadePreviewing = false);
      }
      if (_tableCascadePreview == null && _tableEstimatedQty.isEmpty) return;
      setState(() {
        _tableCascadePreview = null;
        _tableCascadePreviewTyped = const {};
        _recomputeTableEstimates();
      });
      _reseedTableQtyInputs(autoSelect: true);
      return;
    }
    if (_tableCascadePreview != null &&
        mapEquals(activeTyped, _tableCascadePreviewTyped)) {
      return;
    }
    // 记下这一趟是按哪份填数要的：回来时它就是新的换算分母。
    final typedSent = Map<String, double>.unmodifiable(activeTyped);
    setState(() => _tableCascadePreviewing = true);
    _tableCascadeInFlight = true;
    final cancelToken = CancelToken();
    _tableCascadeCancelToken = cancelToken;
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .previewIssuePlans(
            analysis: analysis,
            warehouseId: warehouseId,
            cancelToken: cancelToken,
            // 服务端只读预览已不用幂等键(ADR-116)，字段仍按契约带上。
            idempotencyKey: businessIdempotencyKey(
              'material-analysis-table-cascade-preview',
              [
                analysis.analysisId,
                analysis.version,
                analysis.fingerprint,
                generation,
                for (final entry in typedSent.entries)
                  '${entry.key}:${entry.value}',
              ].join('|'),
            ),
            billDate: _dateText(_billDate)!,
            deliveryDate: _dateText(_deliveryDate),
            // lines 为空 = 只重算、不模拟下达任何一条计划，
            // 因此只要查看权限即可，不需要生成生产计划权限。
            lines: const [],
            typedOutputs: Map<String, double>.from(typedSent),
          );
      // 代际丢弃：用户还在敲，迟到的那一份直接作废。
      if (!mounted ||
          !_sameAnalysisSnapshot(analysis, sessionScope) ||
          generation != _tableCascadeGeneration) {
        return;
      }
      setState(() {
        _tableCascadePreview = view;
        _tableCascadePreviewTyped = typedSent;
        // 服务端那份在路上时用户又改了数：分母摆到「请求时那份填数」上，把这期间
        // 多改的那部分就地补算一次。不补的话屏幕会先跳回旧数字，等下一份重算回来
        // 才跳到新数字。
        _recomputeTableEstimates();
      });
      // 子层的数字变了，没被人动过的「下单数量 / 追加下单」格要跟着回填——否则
      // 父行改成 1500、子行「还缺数量」如期变成 750，可提交的却还是改量前的 500。
      _reseedTableQtyInputs(autoSelect: true);
    } catch (_) {
      // 重算失败不打断填数：退回按权威快照换算的估算值，并停掉预览态。
      if (!mounted ||
          !_sameAnalysisSnapshot(analysis, sessionScope) ||
          generation != _tableCascadeGeneration) {
        return;
      }
      setState(() {
        _tableCascadePreview = null;
        _tableCascadePreviewTyped = const {};
        _recomputeTableEstimates();
      });
      _reseedTableQtyInputs(autoSelect: true);
    } finally {
      if (identical(_tableCascadeCancelToken, cancelToken)) {
        _tableCascadeInFlight = false;
        _tableCascadeCancelToken = null;
      }
      if (mounted && generation == _tableCascadeGeneration) {
        setState(() => _tableCascadePreviewing = false);
      }
      // 尾随：在途期间用户又改过数，按此刻的填数补发一次(提交进行中不发，
      // 批完由 _submitMaterialTableRows 统一决定)。
      if (_tableCascadeTrailing &&
          mounted &&
          _sameAnalysisSnapshot(analysis, sessionScope) &&
          !_tableSubmitting &&
          !_preparationSubmissionActive) {
        _tableCascadeTrailing = false;
        unawaited(_refreshTableCascadePreview());
      }
    }
  }

  /// 展示用的物料行：有预览时取预览里的同一行(子层数量已按父行新量展开)。
  /// 找不到就退回权威快照那一行——预览只能让数字更新，不能让行消失。
  ProductionMaterialAnalysisMaterial _tablePreviewed(
    ProductionMaterialAnalysisMaterial material, {
    bool authoritative = false,
  }) {
    final preview = _tableCascadePreview;
    if (preview == null || authoritative) return material;
    if (!identical(preview, _tablePreviewMaterialsSnapshot)) {
      _tablePreviewMaterialsSnapshot = preview;
      _tablePreviewMaterialsById = {
        for (final candidate in preview.materials)
          candidate.materialLineId: candidate,
      };
    }
    return _tablePreviewMaterialsById[material.materialLineId] ?? material;
  }

  ProductionMaterialAnalysisView? _tablePreviewMaterialsSnapshot;
  Map<String, ProductionMaterialAnalysisMaterial> _tablePreviewMaterialsById =
      const {};

  /// 服务端那份快照(模拟优先、否则权威)给这一行的三个数——当场换算的**分母**。
  _TableQty _tablePreviewedQty(
    ProductionMaterialAnalysisMaterial material, {
    bool authoritative = false,
  }) {
    final shown = _tablePreviewed(material, authoritative: authoritative);
    if (shown.hasPriorityMakeSupplement) {
      return (
        required: shown.priorityMakeSupplementQty,
        residual: shown.priorityMakeSupplementQty,
        net: shown.priorityMakeSupplementQty,
      );
    }
    final preparation = shown.aggregatePreparation;
    if (preparation != null) {
      return (
        required: preparation.requiredQty,
        residual: preparation.planningUncoveredQty,
        net: preparation.netShortageQty,
      );
    }
    final anchorResidual = _tableAnchorResidual(
      material,
      authoritative: authoritative,
    );
    return (
      required: shown.requiredQty,
      residual: anchorResidual ?? shown.additionalSupplyRecommendedQty,
      // Older delegated rows zero their own requirement while an exact existing
      // MAKE anchor still has work to schedule. Its remaining quantity remains
      // the actionable demand; a zero source projection must not hide it.
      net: shown.requiredQty <= 0.0001 && anchorResidual != null
          ? (anchorResidual - shown.sharedFutureClaimableQty).clamp(
              0.0,
              double.infinity,
            )
          : shown.netShortageQty,
    );
  }

  /// 已下过单的自制行(含顶层产品行)的「还需安排」= 锚点产品的剩余可排量(不可排产
  /// 时为 0)；不是这类行返回 null，照旧读服务端给物料行的建议下单量。
  ///
  /// 服务端给物料行的 additionalSupplyRecommendedQty **不扣已下达的自制计划**(那是
  /// internalCommittedOutputQty，契约写明「never subtract it as external finished
  /// supply」)：锚点已排满 2000 的行它照旧给 2000。照它走，主表会把已排满的行显示成
  /// 「还需安排 2000」、追加格 0 恒红、追加时判不出「纯公共备货」而被服务端 409——
  /// 级联页早就是按锚点 remainingQty 算的，主表收成同一口径(2026-09-23 用户实机
  /// 「有一部分没有成功下单」的其中一处)。
  double? _tableAnchorResidual(
    ProductionMaterialAnalysisMaterial material, {
    bool authoritative = false,
  }) {
    final analysis = _analysis;
    if (analysis == null) return null;
    final group = _analysisIndexes(
      analysis,
    ).groupsByLine[material.materialLineId];
    if (group == null) return null;
    final anchor = _tableIssuedMakeAnchorOf(
      group,
      authoritative: authoritative,
    );
    if (anchor == null) return null;
    return anchor.canSchedule
        ? anchor.remainingQty * _tableAnchorUnitRate(group, anchor)
        : 0;
  }

  /// 这一行此刻该显示的三个数：有当场换算的估算值就用它，否则用服务端那份快照。
  /// 「还缺数量」「下单数量」从这里读；「需要数量」另读原始来源基线。
  /// [authoritative] = 只要权威快照那份(自动勾选判「数是不是改量带出来的」用)。
  _TableQty _tableShownQty(
    ProductionMaterialAnalysisMaterial material, {
    bool authoritative = false,
  }) => authoritative
      ? _tablePreviewedQty(material, authoritative: true)
      : _tableEstimatedQty[material.materialLineId] ??
            _tablePreviewedQty(material);

  // ---------------- 敲一下当场变(与级联页共用 material_cascade_math) ----------------

  /// 按此刻的填数把估算值整个重算一遍。
  ///
  /// **从头算、不增量**：分母永远是服务端快照当时的数(权威快照 = 没填过；模拟
  /// 快照 = 它是按 [_tableCascadePreviewTyped] 算出来的)，所以退格、改回、清空都是
  /// 幂等的，中间怎么敲都不影响结果。只有「此刻填数与快照当时不同」的那些树才要算，
  /// 一棵树里所有填过的行一次算齐——父行与它下面被人改过的中间层要按同一份口径走。
  void _recomputeTableEstimates() {
    _draftBudget.invalidate();
    _tableEstimatedQty.clear();
    final analysis = _analysis;
    if (analysis == null) return;
    final typedOutputs = _selectedTableTypedOutputs();
    final changed = <String>{
      for (final entry in typedOutputs.entries)
        if (_tableCascadePreviewTyped[entry.key] != entry.value) entry.key,
      for (final key in _tableCascadePreviewTyped.keys)
        if (!typedOutputs.containsKey(key)) key,
    };
    if (changed.isEmpty) return;
    final presentation = _bomPresentation(analysis);
    final roots = <String?>{
      for (final key in changed) presentation.rootIdsByMaterial[key],
    };
    for (final rootId in roots) {
      _estimateTableTree(analysis, presentation, rootId, typedOutputs);
    }
  }

  /// 把 [rootId] 这一棵树未经投影的全量前序(折叠、表头筛选、分页都不影响它)
  /// 交给共用件换算：屏幕上相邻不等于树上父子，比例只能沿真实父子链传。
  void _estimateTableTree(
    ProductionMaterialAnalysisView analysis,
    _BomPresentation presentation,
    String? rootId,
    Map<String, double> typedOutputs,
  ) {
    final nodes = presentation.nodesByProduct[rootId];
    if (nodes == null || nodes.isEmpty) return;
    final indexes = _analysisIndexes(analysis);
    final byId = {for (final node in nodes) node.materialLineId: node};
    final children = <String?, List<ProductionMaterialAnalysisMaterial>>{};
    for (final node in nodes) {
      final parent = presentation.parentIdsByMaterial[node.materialLineId];
      children
          .putIfAbsent(byId.containsKey(parent) ? parent : null, () => [])
          .add(node);
    }
    // 层级在遍历时重新数(根 = 0)，保证「子 = 父 + 1」——共用件按层级差判子树边界。
    final preorder = <ProductionMaterialAnalysisMaterial>[];
    final depths = <int>[];
    final visited = <String>{};
    void visit(ProductionMaterialAnalysisMaterial node, int depth) {
      if (!visited.add(node.materialLineId)) return;
      preorder.add(node);
      depths.add(depth);
      for (final child
          in children[node.materialLineId] ??
              const <ProductionMaterialAnalysisMaterial>[]) {
        visit(child, depth + 1);
      }
    }

    for (final root
        in children[null] ?? const <ProductionMaterialAnalysisMaterial>[]) {
      visit(root, 0);
    }
    final inputs = <CascadeScaleInput>[];
    final committed = <String, double>{};
    final covered = <String, double>{};
    for (var index = 0; index < preorder.length; index++) {
      final row = _tableScaleInputOf(
        preorder[index],
        indexes,
        depth: depths[index],
        typedOutputs: typedOutputs,
      );
      inputs.add(row.input);
      committed[row.input.key] = row.committed;
      covered[row.input.key] = row.covered;
    }
    for (var index = 0; index < inputs.length; index++) {
      if (depths[index] != 0) continue;
      final root = preorder[index];
      final factor = cascadeFactor(
        baselineOutput: inputs[index].baselineOutput,
        output: _tablePlannedOutput(
          root,
          committedOutput: committed[root.materialLineId] ?? 0,
          server: inputs[index].server,
          typed: typedOutputs[root.materialLineId],
        ),
      );
      // 分母是 0(快照里这一行本来就不下)：比例算不出，这一支交给服务端。
      if (factor == null) continue;
      for (final result in cascadeScaleSubtree(
        preorder: inputs,
        rootIndex: index,
        rootFactor: factor,
        committedOutput: committed,
        coveredOutput: covered,
      )) {
        final snapshot = _tablePreviewedQty(preorder[result.index]);
        // 下达时会自动认领的公共在途是个池子，与父行数量无关：净数 = 毛数 − 它。
        final claimable = snapshot.residual - snapshot.net;
        final net = result.scaled.residual - (claimable > 0 ? claimable : 0);
        _tableEstimatedQty[result.key] = (
          required: result.scaled.required,
          residual: result.scaled.residual,
          net: net > 0 ? net : 0,
        );
      }
    }
  }

  /// 喂给共用件的一行：服务端快照的三个数 + 用户亲手填的数 + 分母，外加这一行
  /// 已下达的量(分子分母都要含它，见 [_tablePlannedOutput])与**不封顶**的覆盖量
  /// (已分配现货 + 已下达 / 在途)。
  ///
  /// 覆盖量为什么要单独算：服务端的「还需安排」封顶在 0，子件之前只需 1000 却下了
  /// 2000 时快照里看不出多下的 1000；父件追加 200 把它的需求抬到 1200，按封顶值算
  /// 会说它还缺 200，实际一颗都不缺(用户口径 2026-09-22)。
  ({CascadeScaleInput input, double committed, double covered})
  _tableScaleInputOf(
    ProductionMaterialAnalysisMaterial material,
    _MaterialAnalysisIndexes indexes, {
    required int depth,
    required Map<String, double> typedOutputs,
  }) {
    final group = indexes.groupsByLine[material.materialLineId];
    final previewed = _tablePreviewed(material);
    final snapshot = _tablePreviewedQty(material);
    final server = (
      required: snapshot.required,
      residual: snapshot.residual,
      suggested: snapshot.residual,
    );
    final committed = group == null ? 0.0 : _tableGroupIssuedQty(group);
    // 现货那一份读服务端明写的两个分配量(本批分到的合格现货 + 精确绑定的到货)，
    // 不用「需求 − 缺口」倒推——倒推会把安全库存保护等别的口径也算成现货。
    // 这是估算：漏算的覆盖来源由 cascadeScaleOne 里与服务端封顶值取大兜底，
    // 剩下的误差 300ms 后服务端那份预览整体覆盖。
    final covered =
        previewed.allocatedAvailableQty + previewed.exactPeggedQty + committed;
    return (
      covered: covered,
      input: (
        key: material.materialLineId,
        depth: depth,
        ownsInput: group != null,
        server: server,
        userTyped: typedOutputs[material.materialLineId],
        // 分母 = 这一行在当前快照里按的产出量 = 用快照当时的填数算出来的计划产出量。
        baselineOutput: _tablePlannedOutput(
          material,
          committedOutput: committed,
          server: server,
          typed: _tableCascadePreviewTyped[material.materialLineId],
        ),
      ),
      committed: committed,
    );
  }

  /// 这一行按 [typed] 这个填数会有的计划产出量(服务端同款口径)。
  ///
  /// 顶层供给行是「来源需求量 与 已下达计划 + 本次填的 取大」——需求量那一项是
  /// 产品的整批需求，不扣现货；其余行是「已下达 + max(本次填的, 还需安排)」，
  /// 还需安排里已经扣过现货与在途。两条都写在服务端 `plannedSourceOutput` /
  /// `withTypedOutput` 的注释里。
  double _tablePlannedOutput(
    ProductionMaterialAnalysisMaterial material, {
    required double committedOutput,
    required CascadeServerQty server,
    required double? typed,
  }) {
    if (_tableIsRootSupply(material)) {
      final planned = committedOutput + (typed ?? 0);
      return planned > server.required ? planned : server.required;
    }
    return cascadePlannedOutput(
      committedOutput: committedOutput,
      server: server,
      userTyped: typed,
    );
  }

  @override
  Future<VoidCallback?> _companionRead(
    _CompanionRead read,
    ProductionMaterialAnalysisView view,
  ) => switch (read) {
    _CompanionRead.transferableIn => _fetchTableTransferableIn(view),
    _CompanionRead.assignmentDefaults => _fetchTableAssignmentDefaults(view),
    _ => super._companionRead(read, view),
  };

  /// 本行此刻可以从别的计划锁定量里调进来多少(0 = 调拨按钮置灰)。
  double _tableTransferableInQty(_MaterialGroup group) {
    if (_tableTransferableIn.isEmpty) return 0;
    var total = 0.0;
    for (final path in group.paths) {
      total += _tableTransferableIn[path.materialLineId] ?? 0;
    }
    return total;
  }

  /// 按需取一次批量可调拨量 (公共装载器的一类读取)。带会话作用域键：切账号后
  /// 丢弃迟到响应，免得把上一个账号可见范围里的量显示给下一个账号。
  Future<VoidCallback?> _fetchTableTransferableIn(
    ProductionMaterialAnalysisView analysis,
  ) async {
    if (!_canCrossReallocate ||
        _tableTransferableInLoading ||
        analysis.materials.isEmpty) {
      return null;
    }
    final sessionKey = _sessionScopeKey();
    final scope = '$sessionKey#${analysis.analysisId}';
    if (_tableTransferableInScope == scope) return null;
    _tableTransferableInLoading = true;
    Map<String, double> summary;
    try {
      summary = await ref
          .read(productionPlanRepositoryProvider)
          .materialTransferableInSummary(analysis.analysisId);
    } catch (_) {
      // 调拨按钮灰不灰是辅助信息，取不到就一律按「无可调拨」置灰，不打断主表。
      summary = const {};
    }
    return () {
      _tableTransferableInLoading = false;
      if (!mounted) return;
      // 切账号后到货的响应直接丢弃：可调拨量随登录人的对象级可见范围变，
      // 把上一个账号看得见的量显示给下一个账号是越权泄露。
      // 会话键**先存下来再比**，不要从拼接串里拆——会话键自身含 '|'。
      if (_sessionScopeKey() != sessionKey ||
          _analysis?.analysisId != analysis.analysisId) {
        // 读取途中换了账号或换了分析：途中提出的新读取被上面的「正在读取」挡掉了，
        // 这里按当前会话与快照补取一次。
        if (_analysis != null) {
          _requestCompanionReads(const [_CompanionRead.transferableIn]);
        }
        return;
      }
      _tableTransferableIn = summary;
      _tableTransferableInScope = scope;
    };
  }

  // ---------------- 下达车间前的就地指派(生产车间 / 负责人) ----------------
  //
  // 这套学习记忆原先只长在分桶详情页里。主表要在行上直接指派，就得把它提到
  // 宿主 State：默认值优先货品学习记忆(V488 连负责人一起记)，否则组织树上
  // 该车间的负责人，都带黄标提醒核对；两者都没有才留空手选。

  Map<
    String,
    ({
      String departmentId,
      String? departmentName,
      String? workerId,
      String? workerName,
    })
  >
  _tableWorkshopDefaults = const {};
  Map<String, ({String? id, String? name})> _tableWorkshopManagers = const {};
  List<DepartmentNode> _tableWorkshopTree = const [];
  String? _tableAssignmentScope;
  bool _tableAssignmentLoading = false;
  Completer<void>? _tableAssignmentCompletion;
  bool _deferredAssignmentRead = false;
  int _tableAssignmentGeneration = 0;

  @override
  void _flushDeferredAssignmentRead() {
    if (!_deferredAssignmentRead || _analysis == null) return;
    _deferredAssignmentRead = false;
    _requestCompanionReads(const [_CompanionRead.assignmentDefaults]);
  }

  Future<void> _ensureTableMandatoryAssignments(
    List<_MaterialGroup> groups,
  ) async {
    bool missing() => groups.any(
      (group) =>
          _tableIssuedAssignmentOf(group) == null &&
          _tableIssueTarget(group).viaWorkshop &&
          (_tableWorkshopFor(group).id?.isNotEmpty != true ||
              _tableWorkerFor(group).id?.isNotEmpty != true),
    );
    if (!missing() || _analysis == null) return;
    await _tableAssignmentCompletion?.future;
    if (!mounted || !missing() || _analysis == null) return;
    await _loadTableAssignmentDefaults(
      _analysis!,
      mandatory: true,
      force: true,
    );
  }

  @override
  void _invalidateOwnerAssignmentDefaults(Set<String> goodsIds) {
    _tableWorkshopDefaults = {..._tableWorkshopDefaults}
      ..removeWhere((goods, _) => goodsIds.contains(goods));
    _tableAssignmentScope = null;
    _tableAssignmentGeneration++;
    if (_preparationSubmissionActive) {
      _deferredAssignmentRead = true;
      return;
    }
    _requestCompanionReads(const [_CompanionRead.assignmentDefaults]);
  }

  /// 必填指派格(生产车间/负责人)的定位键：'W|<组键>' / 'R|<组键>'。
  /// 只给自制行的两个格子挂(那是必填的两种)；下单前发现没填完时用它
  /// [_revealTableAssignmentCell] 滚过去。GlobalKey 跨帧保持；行消失后条目
  /// 留在表里无碍(下次构建同组键复用同一个)。
  final Map<String, GlobalKey> _tableAssignmentCellKeys = {};

  /// 必填指派格实时红框(RequiredCellFrame)的重算源：指派草稿都走 setState，
  /// didUpdateWidget 会重算 isEmpty，这里只需一个稳定的 listenable 占位。
  final ValueNotifier<int> _tableAssignmentTick = ValueNotifier(0);

  GlobalKey _tableAssignmentCellKey(String kind, _MaterialGroup group) =>
      _tableAssignmentCellKeys.putIfAbsent('$kind|${group.key}', GlobalKey.new);

  /// 下单前必须等到车间/负责人默认值的调用方用它 (直接 await)；与进页那一批走
  /// 同一个公共装载器、同一套套用口径。
  Future<void> _loadTableAssignmentDefaults(
    ProductionMaterialAnalysisView analysis, {
    bool mandatory = false,
    bool force = false,
  }) => _runCompanionReads([
    _fetchTableAssignmentDefaults(analysis, mandatory: mandatory, force: force),
  ]);

  /// 车间/负责人默认值 (组织树 + 货品学习记忆) 的一类读取：返回合批套用动作。
  /// 等待者 ([_tableAssignmentCompletion]) 在套用之后才放行——放行时默认值已经
  /// 落到页面状态里。
  Future<VoidCallback?> _fetchTableAssignmentDefaults(
    ProductionMaterialAnalysisView analysis, {
    bool mandatory = false,
    bool force = false,
  }) async {
    if (!_canGenerate) return null;
    final scope = '${_sessionScopeKey()}|${analysis.analysisId}';
    if (!force && _tableAssignmentScope == scope) return null;
    if (_preparationSubmissionActive && !mandatory) {
      _deferredAssignmentRead = true;
      return null;
    }
    if (_tableAssignmentLoading) {
      if (mandatory) await _tableAssignmentCompletion?.future;
      return null;
    }
    final goodsIds = <String>{
      for (final material in analysis.materials)
        if (material.goodsId?.isNotEmpty == true) material.goodsId!,
    };
    if (goodsIds.isEmpty) return null;
    _tableAssignmentLoading = true;
    _deferredAssignmentRead = false;
    final completion = Completer<void>();
    _tableAssignmentCompletion = completion;
    final generation = _tableAssignmentGeneration;
    List<DepartmentNode>? tree;
    Map<
      String,
      ({
        String departmentId,
        String? departmentName,
        String? workerId,
        String? workerName,
      })
    >?
    defaults;
    try {
      tree = await _tableWorkshopTreeOrEmpty();
      defaults = await ref
          .read(productionPlanRepositoryProvider)
          .defaultWorkshops(goodsIds);
    } catch (_) {
      defaults = null;
    }
    return () {
      _tableAssignmentLoading = false;
      _tableAssignmentCompletion = null;
      // 代际、分析、会话三者都没变才算数；途中任一变了，途中提出的新读取已被上面的
      // 「正在读取」挡掉，下面按最新快照补取一次。
      final current =
          mounted &&
          generation == _tableAssignmentGeneration &&
          _analysis?.analysisId == analysis.analysisId &&
          scope == '${_sessionScopeKey()}|${analysis.analysisId}';
      if (current) {
        if (tree != null && defaults != null) {
          _tableWorkshopTree = tree;
          _tableWorkshopDefaults = defaults;
          _tableWorkshopManagers = {
            for (final node in tree)
              if (node.managerId?.isNotEmpty == true)
                node.id: (id: node.managerId, name: node.managerName),
          };
        }
        _tableAssignmentScope = scope;
      }
      completion.complete();
      if (!current && mounted && _analysis != null) {
        _requestCompanionReads(const [_CompanionRead.assignmentDefaults]);
      }
    };
  }

  Future<List<DepartmentNode>> _tableWorkshopTreeOrEmpty() async {
    // 直读稳定的部门仓库而不是 autoDispose provider：后者被一次性 read(.future)
    // 时可能在请求中途回收，Future 永不完成(默认车间带不出的隐患)。
    try {
      final tree = await ref.read(departmentRepositoryProvider).tree();
      return findDepartmentByCode(tree, kDeptCodeProduction)?.children ??
          const [];
    } catch (_) {
      return const [];
    }
  }

  /// 组自身「显示口径已下达量」是否为正：自制锚点行读锚点产品的精确数量
  /// 事实（10^-4 tick），其余分支沿用 double 投影但不再带 0.0001 容差
  ///（0.0001 也是真实已下达量，2026-10-07 数量完整性）。
  bool _tableGroupIssuedPositive(_MaterialGroup group) {
    final preparation = _tablePreviewed(
      group.representative,
      authoritative: true,
    ).aggregatePreparation;
    if (preparation != null) return preparation.orderedQty > 0;
    if (_tableUsesMakeAnchor(group)) {
      final anchor = _tableMakeAnchorOf(group, authoritative: true);
      return anchor != null && _tableIssuedUnitsExact(anchor) > BigInt.zero;
    }
    return _tableGroupIssuedQty(group, authoritative: true) > 0;
  }

  /// 产品的已下达计划量（10^-4 tick）；精确事实缺失或不可解析时回退
  /// legacy > 0 的 0/1 投影。
  BigInt _tableIssuedUnitsExact(ProductionMaterialAnalysisProduct product) {
    final fallback = product.issuedPlanQty > 0 ? BigInt.one : BigInt.zero;
    final fact = materialPresentationFact(
      product.quantityFactsExact,
      'issuedPlanQty',
      product.issuedPlanQty,
    );
    if (fact == null) return fallback;
    try {
      return materialQuantityUnits(fact);
    } on FormatException {
      return fallback;
    }
  }

  ProductionMaterialAnalysisProduct? _tableIssuedAssignmentOf(
    _MaterialGroup group,
  ) {
    if (!_tableAssignable(group)) return null;
    // A delegated child's shared parent has a plan before the child is ordered.
    // Only its own order facts authorize locking that child's assignment.
    // 自身已下达量按 10^-4 tick 精确判零（2026-10-07）：锚点下过 0.0001 也是
    // 真实订单事实，子行指派随之锁定；非自制行不继承父件共享批次的已下达。
    if (!_tableIsRootSupply(group.representative) &&
        !_tableGroupIssuedPositive(group) &&
        (group.representative.aggregatePreparation?.totalOrderedQty ?? 0) <=
            0) {
      return null;
    }
    final plan =
        _tableMakeAnchorOf(group, authoritative: true) ??
        _sharedBatchChildProductOf(group.representative);
    if (plan == null ||
        const {'CANCELLED', 'REVERSED'}.contains(plan.planExecutionStatus)) {
      return null;
    }
    // 已下达的判据按 10^-4 tick 精确：issuedPlanQty = 0.0001 也是一个 tick 的
    // 真实计划量，车间/负责人随之锁定（2026-10-07 数量完整性）；exact 事实
    // 缺失或不可解析时回退 legacy > 0，不再用 0.0001 double 容差吞最小量。
    final issuedFact = materialPresentationFact(
      plan.quantityFactsExact,
      'issuedPlanQty',
      plan.issuedPlanQty,
    );
    var issued = plan.issuedPlanQty > 0;
    if (issuedFact != null) {
      try {
        issued = materialQuantityUnits(issuedFact) > BigInt.zero;
      } on FormatException {
        // keep legacy fallback
      }
    }
    return plan.latestPlanId?.isNotEmpty == true || issued ? plan : null;
  }

  /// 已下达以真实计划指派为准；未下达时保留员工手选，才使用主档默认。
  ({String? id, String? name, bool autofilled}) _tableWorkshopFor(
    _MaterialGroup group,
  ) {
    final actual = _tableIssuedAssignmentOf(group);
    if (actual != null) {
      return (
        id: actual.planExecutionWorkshopId,
        name: actual.planExecutionWorkshopName,
        autofilled: false,
      );
    }
    final draft = _tableWorkshopDraft[group.key];
    if (draft != null) {
      return (id: draft.id, name: draft.name, autofilled: false);
    }
    final goodsId = group.representative.goodsId;
    final material = group.representative;
    if (material.owningWorkshopId?.isNotEmpty == true) {
      return (
        id: material.owningWorkshopId,
        name: material.owningWorkshopName,
        autofilled: true,
      );
    }
    final learned = goodsId == null ? null : _tableWorkshopDefaults[goodsId];
    if (learned != null) {
      return (
        id: learned.departmentId,
        name: learned.departmentName,
        autofilled: true,
      );
    }
    return (id: null, name: null, autofilled: false);
  }

  /// 本行此刻的负责人：手选草稿 > 学习记忆里与本次车间一致的负责人 >
  /// 组织树上该车间的负责人。
  ({String? id, String? name, bool autofilled}) _tableWorkerFor(
    _MaterialGroup group,
  ) {
    final actual = _tableIssuedAssignmentOf(group);
    if (actual != null) {
      return (
        id: actual.planExecutionResponsibleId,
        name: actual.planExecutionResponsibleName,
        autofilled: false,
      );
    }
    final draft = _tableWorkerDraft[group.key];
    if (draft != null) {
      return (id: draft.id, name: draft.name, autofilled: false);
    }
    final workshop = _tableWorkshopFor(group);
    final goodsId = group.representative.goodsId;
    final learned = goodsId == null ? null : _tableWorkshopDefaults[goodsId];
    if (learned?.workerId != null && learned!.departmentId == workshop.id) {
      return (id: learned.workerId, name: learned.workerName, autofilled: true);
    }
    final manager = workshop.id == null
        ? null
        : _tableWorkshopManagers[workshop.id!];
    if (manager != null) {
      return (id: manager.id, name: manager.name, autofilled: true);
    }
    return (id: null, name: null, autofilled: false);
  }

  Future<void> _pickTableWorkshop(_MaterialGroup group) async {
    if (_tableIssuedAssignmentOf(group) != null) return;
    final tree = _tableWorkshopTree.isNotEmpty
        ? _tableWorkshopTree
        : await _tableWorkshopTreeOrEmpty();
    if (!mounted) return;
    final selectable = {for (final node in tree) node.id};
    final current = _tableWorkshopFor(group);
    final picked = await showUtenDepartmentPickerPanel(
      context,
      tree: tree,
      selectablePredicate: (node) => selectable.contains(node.id),
      initialSelection: current.id == null
          ? const []
          : [
              DeptSelection(
                id: current.id!,
                name: current.name ?? '',
                fullPath: '',
                level: '',
              ),
            ],
    );
    final selection = picked == null || picked.isEmpty ? null : picked.first;
    if (selection == null ||
        !mounted ||
        _tableIssuedAssignmentOf(group) != null) {
      return;
    }
    setState(() {
      _tableWorkshopDraft[group.key] = (id: selection.id, name: selection.name);
      // 换车间必须把负责人草稿清掉：留着上一个车间的人是最容易漏掉的错派。
      _tableWorkerDraft.remove(group.key);
      _reselectTypedRowAfterAssignment(group);
    });
  }

  Future<void> _pickTableWorker(_MaterialGroup group) async {
    if (_tableIssuedAssignmentOf(group) != null) return;
    final workshop = _tableWorkshopFor(group);
    final current = _tableWorkerFor(group);
    final picked = await showUtenEmployeePickerPanel(
      context,
      title: '选择生产负责人',
      selectedId: current.id,
      departmentName: workshop.name,
      loader: (keyword) async {
        final result = await ref
            .read(employeeRepositoryProvider)
            .listPickerCandidates(
              size: 30,
              search: keyword,
              departmentId: (keyword?.trim().isEmpty ?? true)
                  ? workshop.id
                  : null,
              includeSubtree: true,
            );
        return [
          for (final employee in result)
            UtenEmployeePickerItem(
              id: employee.id,
              name: employee.fullName,
              employeeCode: employee.code,
              departmentId: employee.departmentId,
              departmentName: employee.departmentName,
            ),
        ];
      },
    );
    if (picked == null ||
        !mounted ||
        _tableIssuedAssignmentOf(group) != null ||
        _tableWorkshopFor(group).id != workshop.id ||
        _tableWorkerFor(group).id != current.id) {
      return;
    }
    setState(() {
      _tableWorkerDraft[group.key] = (id: picked.id, name: picked.name);
      _reselectTypedRowAfterAssignment(group);
    });
  }

  // ------------------------- 物料办理列 -------------------------

  /// 下达去向只看路线：自制下达车间；委外(有无下层都一样，ADR-143)下达委外申请；
  /// 采购下达采购需求。
  ({String label, bool viaWorkshop}) _tableIssueTarget(_MaterialGroup group) =>
      switch (_draftRoute(group)) {
        MaterialSupplyRoute.make => (label: '下达车间', viaWorkshop: true),
        MaterialSupplyRoute.subcontract => (label: '下达委外', viaWorkshop: false),
        _ => (label: '下达采购', viaWorkshop: false),
      };

  /// 委外件缺 BOM(ADR-143 §二.3)：服务端标 [ProductionMaterialAnalysisMaterial.bomMissing]
  /// 并已自动通知研发完善。只在这一行走委外时生效(改成采购就不拦)；返回进度列与
  /// 拦截原因共用的短标签「缺 BOM·已通知研发(研发任务号)」，不缺时返回 null。
  String? _tableBomMissingLabel(_MaterialGroup group) {
    if (_draftRoute(group) != MaterialSupplyRoute.subcontract) return null;
    for (final path in group.paths) {
      if (!path.bomMissing) continue;
      final taskNo = path.rdTaskNo?.trim() ?? '';
      return taskNo.isEmpty ? '缺 BOM·已通知研发' : '缺 BOM·已通知研发($taskNo)';
    }
    return null;
  }

  /// 表格行(原行 / 产品顶层行 / 按物料汇总行)上的缺 BOM 标签。
  String? _tableRowBomMissingLabel(_MaterialTableRow row) {
    if (row.contextOnly) return null;
    if (row.group case final group?) return _tableBomMissingLabel(group);
    if (row.aggregate case final aggregate?) {
      for (final group in _aggregateTable.groupsOf(aggregate)) {
        final label = _tableBomMissingLabel(group);
        if (label != null) return label;
      }
    }
    return null;
  }

  /// 主表里还有用户手填未提交的数量，或还勾着待下单的行。
  @override
  bool get _hasUnsubmittedMaterialTableInput =>
      _aggregateTable.hasDrafts ||
      _selectedMaterialGroupKeys.isNotEmpty ||
      _tableUserTypedQty.isNotEmpty ||
      _tableOrderQtyControllers.entries.any(
        (entry) =>
            _tableSeededQtyTexts['ORDER|${entry.key}'] != entry.value.text,
      ) ||
      _tableAppendQtyControllers.entries.any(
        (entry) =>
            _tableSeededQtyTexts['APPEND|${entry.key}'] != entry.value.text,
      );

  /// 「先指定生产车间」拦截原因的稳定字面量：提交前的就地补派
  /// ([_tableMissingAssignment]) 与汇总表 [selectableForOrder] 都按它识别。
  static const _tableMissingWorkshopReason = '先在「生产车间」列里指定本次交给哪个车间';
  static const _tableMissingWorkerReason = '先在「负责人」列里指定本次谁负责';

  /// 已转交共享制造 / 不再需要备料的来源行说明：灰勾选框悬浮与「没有量可下」
  /// 的数量格提示共用同一句，避免两处各说各话。
  static const _tableTransferredSourceReason = '此来源已转交生产责任或不再需要备料，当前仅保留来源说明';

  /// 这一行现在能不能下达；不能时给出**人话**原因(缺权限要说清缺哪一个)。
  @override
  String? _tableIssueBlockedReason(
    _MaterialGroup group, {
    bool forAggregate = false,
  }) {
    if (_aggregateTable.inactiveSourceContext(group)) {
      return _tableTransferredSourceReason;
    }
    final analysis = _analysis;
    if (analysis != null &&
        !_analysisIndexes(analysis).sourceGraph
            .resolve(group.paths.map((path) => path.materialLineId))
            .complete) {
      return '来源单据关联不完整，请刷新核对后下单';
    }
    if (!forAggregate &&
        _aggregateTable.ownsLine(group.representative.materialLineId) &&
        !_aggregateTable.isProductFlow(group.representative.materialLineId)) {
      return '此来源已有未提交的汇总总量，请到「按物料汇总」修改、下达或撤销该草稿';
    }
    if (group.representative.confirmedRoute == null) {
      return '这一行还没选供应方式，先在「供应方式」列里选好（选好即自动保存）';
    }
    // 路线草稿保存失败时 _routeDraft/_dirtyRouteGroups 会留在页面上，此时
    // _draftRoute 给的是还没落盘的路线：照它选下达通道会直接吃服务端 400，
    // 而且 _notifyRoute 只要页面上还有任一脏组就整段拒绝。所有旧入口都把脏组
    // 当「路线待确认」，主表这个新口子不能漏。
    if (_dirtyRouteGroups.contains(group.key)) {
      return '这一行的供应方式还没保存成功，请重新选一次供应方式';
    }
    final planningBlock = _planningBlockForGroup(group);
    if (planningBlock != null) return planningBlock;
    // 缺 BOM 的委外件不能下达(服务端同样拒绝)，勾选框随之不可勾。
    final bomMissing = _tableBomMissingLabel(group);
    if (bomMissing != null) {
      return '$bomMissing：这个委外件还没有维护直属物料，研发完善 BOM 后物料分析会自动更新，再下达委外';
    }
    if (_tableRootMakePlanLineId(group) != null) {
      final product = _tableMakeAnchorOf(group);
      if (product != null && !product.canSchedule && !product.canIssueSurplus) {
        return product.scheduleBlockedReason ?? '当前产品暂不可下达生产计划，请核对计划状态';
      }
    }
    // 已排满又不能再追加公共备货产出的自制行(含顶层产品行)：服务端 issue-plans 对
    // 「剩余需求 0 且没声明纯公共备货」一律 409「当前分析需求已全部转入生产计划」。
    final issuedAnchor = _tableIssuedMakeAnchorOf(group);
    if (issuedAnchor != null &&
        !group.representative.hasPriorityMakeSupplement &&
        !issuedAnchor.canSchedule &&
        !issuedAnchor.canIssueSurplus) {
      return '这一行的生产计划已排满，当前不能再追加公共备货产出';
    }
    // 服务端会拒的形态在这里就拦掉，别让人勾了、填了数、点了下达才吃 400。
    // 判据复用既有权威谓词的同名分支，不另造一套。走到这里路线必已确认
    // （上方拦截过 confirmedRoute == null）。
    final route = _draftRoute(group)!;
    if (_routeBlockedBySafetyGap(group, route)) {
      return '本版本仅采购路线支持公共安全补库，请改用采购路线下达';
    }
    if (!group.paths.every(_hasResolvedMaterialSource)) {
      return '这一行的物料来源读不出来，请刷新分析后核对';
    }
    final target = _tableIssueTarget(group);
    if (target.viaWorkshop && !_canGenerate) {
      return '你没有「下达车间」的权限，请找管理员开通';
    }
    if (!target.viaWorkshop && !_canNotify) {
      return '你没有「下达采购 / 委外」的权限，请找管理员开通';
    }
    if (target.viaWorkshop) {
      final actual = _tableIssuedAssignmentOf(group);
      if (actual != null &&
          (actual.planExecutionWorkshopId == null ||
              actual.planExecutionResponsibleId == null)) {
        return '已下达计划的实际指派不完整或不唯一，请在计划中核对后再追加';
      }
      final workshop = _tableWorkshopFor(group);
      if (workshop.id == null) return _tableMissingWorkshopReason;
      if (_tableWorkerFor(group).id == null) return _tableMissingWorkerReason;
    } else if (group.representative.aggregatePreparation?.actionable != true &&
        !_isExecutableSupplyGroup(group, route, allowExtra: _canOverSupply)) {
      // 外发段最终由 _notifyRoute 里的 _executableSupplyGroups 把关，它比上面
      // 这些条件严(还要求 actionable、无未挂钩的已下达计划、有可提交量或有超量
      // 权限)。不在这里先拦住的话，被它静默剔掉的行照样会被记成「已完成」：
      // 勾选被撤、追加清零、结果弹「✓ 下达采购(5 行)」，实际只下了 4 行。
      // 2026-09-22 对抗复查抓出来的真缺陷。
      return _canOverSupply
          ? '这一行当前没有可下达的量，请刷新后核对'
          : '这一行已按需求下满，再下属于公共备货，需要超量下达权限';
    }
    return null;
  }

  /// 这一行现在能不能调拨；不能时给出原因。
  String? _tableTransferBlockedReason(_MaterialGroup group) {
    if (!_canCrossReallocate) {
      return '你没有「跨计划调拨」的权限，请找管理员开通';
    }
    if (_tableTransferableInQty(group) <= 0) {
      return '现在没有别的计划锁着这个物料可以调给你';
    }
    return null;
  }

  /// 2026-09-22 用户复核：「物料办理只要调拨, 不需要有下达的按钮」。
  ///
  /// 这一列原本并排画「调拨 + 下达」两个按钮。行内那个下达与悬浮区「下单(N)」是
  /// 同一个 [_submitMaterialTableRows] 的两个入口, 端点、确认框、数量来源、权限门
  /// 全部相同, 且可勾判据 [_materialRowSelectableGroups] 用的正是下达那同一个谓词
  /// —— 凡是行内按钮亮着的行必定有复选框, 所以撤掉它不丢任何能力, 下单统一走
  /// 「勾选 + 下单(N)」。调拨必须留在行内: V311 规定一个物料节点不能同时参与多笔
  /// 未补齐的让料, 多选调拨必然部分失败(ADR-102 §2.8)。
  ///
  /// [_tableIssueBlockedReason] 不能跟着删 —— 它还是可勾判据、悬浮下单集合、
  /// 下单数量/追加下单两格与车间负责人两列的权威判据。它产出的人话原因原本只挂在
  /// 置灰的下达按钮上, 现在改挂到「下单数量」格的悬浮说明里。
  String? _materialTableHandleText(_MaterialTableRow row) {
    final group = _tableEditableGroup(row);
    if (group == null) return '—';
    return _tableTransferBlockedReason(group) == null ? '可调拨' : '暂不可办理';
  }

  Widget _materialTableHandleCell(ThemeData theme, _MaterialTableRow row) {
    if (row.aggregate case final aggregate?) {
      return _aggregateTable.actionCell(aggregate);
    }
    if (row.isAggregateSource) return const Text('—');
    final group = _tableEditableGroup(row);
    if (group != null &&
        _aggregateTable.ownsLine(group.representative.materialLineId)) {
      return _aggregateTable.lockedText('汇总草稿中');
    }
    if (group == null) return const Text('—');
    final transferReason = _tableTransferBlockedReason(group);
    final transferable = _tableTransferableInQty(group);
    return _materialTableHandleButton(
      theme,
      key: 'material-analysis-handle-transfer-${group.key}',
      icon: Icons.swap_horiz_rounded,
      label: '调拨',
      // 退役的「在途调拨」列并到这里：已经调过的进度跟着按钮一起看。
      tooltip: [
        transferReason ?? '可从别的计划调入 ${_qty(transferable)}',
        if (_futureTransferRecords.isNotEmpty) _futureProgressText(row),
      ].where((line) => line != '—').join('\n'),
      onTap: transferReason == null && !_busy
          ? () => unawaited(_showTransferLauncher(group))
          : null,
    );
  }

  Widget _materialTableHandleButton(
    ThemeData theme, {
    required String key,
    required IconData icon,
    required String label,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    final color = enabled
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: ValueKey(key),
        onTap: onTap,
        borderRadius: BorderRadius.circular(UtenRadius.control),
        child: Semantics(
          label: '$label，$tooltip',
          button: true,
          enabled: enabled,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s8,
              vertical: UtenSpacing.s4,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(UtenRadius.control),
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: UtenSpacing.s4),
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------- 还缺数量列 -------------------------

  Widget _materialTableNetShortageCell(ThemeData theme, _MaterialTableRow row) {
    final net = _materialTableNetShortageQty(row);
    final budget = _tableBudgetOf(row);
    final gross = _materialTableAdditionalRecommendedQty(row) ?? net ?? 0;
    final claimed = (gross - (net ?? gross)).clamp(0.0, gross);
    final late = row.aggregate != null
        ? row.aggregate!.paths.fold<double>(
            0,
            (sum, item) => sum + item.lateSharedFutureAvailableQty,
          )
        : row.material?.lateSharedFutureAvailableQty ?? 0;
    // 补充仓库实物和在途事实，区分本次编辑预算与已经发生的采用。
    final available = _materialTableAvailableQty(row);
    final inbound = _materialTableInboundQty(row);
    final physical = _materialTableShortageQty(row);
    final pendingShared = row.aggregate != null
        ? row.aggregate!.paths.fold<double>(
            0,
            (total, path) => total + (path.sharedFuturePendingQty ?? 0),
          )
        : row.material?.sharedFuturePendingQty ?? 0;
    // 顶层自制产品行没有「还要另外下多少」这个数(它的补货走下达车间)，
    // 但仓库可用与在途这些事实照样要有落点——格子显示横杠，说明照给。
    final buffer = StringBuffer(
      net == null
          ? '这一行的补货走「下达车间」，没有单独的下单缺口。'
          : budget != null
          ? '按本次选中填写的数量预留后，这一行还缺 ${_qty(net)}。'
                '\n本次为该行预留 ${_qty(budget.reservedSharedQty)}，共同可用余量 ${_qty(budget.remainingSharedQty)}。'
                '\n能用于本行的供给才抵扣缺口。'
                '\n这是本次编辑预算，取消勾选即恢复；实际采用和下单在提交时复核。'
          : '扣掉公共的量之后，这一行还要另外下 ${_qty(net)}。',
    );
    if (available != null && available > 0) {
      buffer.write('\n仓库现在可用 ${_qty(available)}。');
    }
    if (inbound != null && inbound > 0) {
      buffer.write('\n已安排但还没合格入库 ${_qty(inbound)}。');
    }
    if (pendingShared > 0) {
      buffer.write('\n公共已认领未实收 ${_qty(pendingShared)}；尚未实收入库，不能作为可领料现货。');
    }
    if (claimed > 0 && budget == null) {
      buffer.write('\n其中已按公共在途扣减 ${_qty(claimed)}，下达时服务端会自动认领。');
      // ADR-070 要求晚到供给让人看得见自己接受了什么：不混进一个数里。
      if (late > 0) buffer.write('\n(含晚到来源 ${_qty(late)}，交期晚于本批需要的日子。)');
      // 认领是从「下单数量」里切走的，不是在它之上另加——所以右边那一格填的是
      // 没扣公共量的毛数，两个数字不一样是对的。
      buffer.write(
        '\n右边「下单数量」填的是本次要覆盖的总量 ${_qty(gross)}，'
        '服务端会从中认领 ${_qty(claimed)}、只为余下部分开新单。',
      );
    }
    if (physical != null && physical > 0) {
      buffer.write('\n实物缺口仍是 ${_qty(physical)}——下单不会让它变小，合格入库才会。');
    }
    if (_tableCascadePreviewing) {
      buffer.write('\n(正在按你刚填的数重算下层，稍候刷新。)');
    }
    return Tooltip(
      key: ValueKey(
        'material-analysis-net-shortage-'
        '${row.material?.materialLineId ?? row.key}',
      ),
      message: buffer.toString(),
      child: net == null
          ? const Text('—')
          : Text(
              _materialTableNetShortageText(row) ?? '—',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _shortageTextColor(theme, net),
                fontWeight: FontWeight.w800,
              ),
            ),
    );
  }

  // ------------------------- 下单数量 / 追加下单 -------------------------

  /// Calculations use authoritative quantities or current input, never rounded
  /// display text. Context-only rows deliberately have no numeric facts.
  String? _materialTableOrderRaw(
    _MaterialTableRow row, {
    required bool append,
  }) {
    if (row.contextOnly) return null;
    if (row.aggregate case final aggregate?) {
      return _aggregateTable.quantityRaw(aggregate, append: append);
    }
    final group = _tableEditableGroup(row);
    if (group == null) return null;
    final issued = _tableGroupIssued(group);
    if (append && !issued) return null;
    if (!append && issued) {
      final preparation = group.representative.aggregatePreparation;
      if (row.isAggregateSource && preparation != null) {
        return materialPresentationFact(
          preparation.quantityFactsExact,
          'allocatedOrderedQty',
          preparation.allocatedOrderedQty,
        );
      }
      return _tableGroupDisplayedIssuedQty(group).toString();
    }
    if (!append &&
        _tableAggregateDelegatedShare(group) != null &&
        group.representative.aggregatePreparation == null) {
      return null;
    }
    return (append
                ? _tableAppendQtyControllers
                : _tableOrderQtyControllers)[group.key]
            ?.text ??
        _tableDefaultSubmitQty(group).toString();
  }

  String? _materialTableOrderQtyText(_MaterialTableRow row) {
    if (row.aggregate case final aggregate?) {
      return _aggregateTable.orderText(aggregate);
    }
    final preparation = row.material?.aggregatePreparation;
    if (row.isAggregateSource && preparation != null) {
      return materialPresentationFact(
            preparation.quantityFactsExact,
            'allocatedOrderedQty',
            preparation.allocatedOrderedQty,
          ) ??
          '无法确认';
    }
    final group = _tableEditableGroup(row);
    if (group == null) return '—';
    if (_tableGroupIssued(group)) {
      return _qty(_tableGroupDisplayedIssuedQty(group));
    }
    final delegatedShare = _tableAggregateDelegatedShare(group);
    if (delegatedShare != null &&
        group.representative.aggregatePreparation == null) {
      return '—';
    }
    return _tableOrderQtyControllers[group.key]?.text ??
        _qty(_tableDefaultSubmitQty(group));
  }

  Widget _materialTableOrderQtyCell(ThemeData theme, _MaterialTableRow row) {
    if (row.aggregate case final aggregate?) {
      return _aggregateTable.quantityCell(theme, aggregate, append: false);
    }
    if (row.isAggregateSource) {
      return Text(_materialTableOrderQtyText(row) ?? '—');
    }
    final group = _tableEditableGroup(row);
    if (group == null) return const Text('—');
    if (_aggregateTable.ownsLine(group.representative.materialLineId)) {
      return _aggregateTable.lockedText(_materialTableOrderQtyText(row) ?? '—');
    }
    // 已下达：这一格锁住并改成显示累计已下单量，本次要再下就填右边的追加。
    if (_tableGroupIssued(group)) {
      final preparation = group.representative.aggregatePreparation;
      final adopted = group.paths.fold<double>(
        0,
        (total, path) => total + path.preparationAdoptedQty,
      );
      return Tooltip(
        message:
            '累计已下单 ${_qty(_tableGroupDisplayedIssuedQty(group))}。'
            '下达之后这一格不可改，要再下请填右边的「追加下单」。'
            '${adopted > 0.0001 ? '本行另外已采用供给 ${_qty(adopted)}，采用不计入新增下单量。' : ''}'
            '${preparation?.orderedQtyExact == false ? '历史记录未保留逐行发出量，这里显示可核对的本行份额；关联单据总量 ${_qty(preparation!.totalOrderedQty)}。' : ''}',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s4),
            Flexible(
              child: Text(
                _qty(_tableGroupDisplayedIssuedQty(group)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (adopted > 0.0001) ...[
              const SizedBox(width: UtenSpacing.s4),
              Flexible(
                child: Text(
                  '采用 ${_qty(adopted)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      );
    }
    final delegatedShare = _tableAggregateDelegatedShare(group);
    if (delegatedShare != null &&
        group.representative.aggregatePreparation == null) {
      return const Tooltip(
        message: '这一行的下单来源信息尚未完整返回，请刷新后重试。',
        child: Text('—'),
      );
    }
    if (group.representative.confirmedRoute == null) {
      return Tooltip(
        message: '先确认供应方式，这一行才能填下单数量。',
        child: Text('—', style: theme.textTheme.bodySmall),
      );
    }
    // 没有量可下的行(需要数量 0 的同料兄弟行、缺口已由现货 / 别行下单覆盖)：
    // 不再给红框输入框。2026-09-26 用户实机「全选下单结束后，中间很多行下单数量
    // 变成 0 还能输入、没有锁」——那些是同一物料挂在别棵产品树上的 0 需求实例
    // (真实需求量的那一行已经锁成累计已下单)，满屏「可编辑的红 0」看起来就是
    // 「没下成」。亲手填了数的格子保持可编辑，不打断输入。
    final typedOrder = double.tryParse(
      _tableOrderQtyControllers[group.key]?.text.trim() ?? '',
    );
    if ((typedOrder == null || typedOrder <= 0) &&
        _tableGroupResidual(group) < 0.00005) {
      final route = _draftRoute(group);
      if (route != null && _hasRootStockToAllocate(group, route)) {
        return const Tooltip(
          message: '本次无需新增下单；勾选下单后交接已分配的现货，仍保留原订单来源。',
          child: Text('0（现货交接）'),
        );
      }
      // 已转交的行先说清「为什么不可下达」再补「没有量」：转交是这些行的首要
      // 事实，通用零量文案会把它盖住(2026-10-07 用户实机：汇总视图下满后回到
      // 按产品视图，子行追加全 0、灰框勾不上，悬浮只说「没有要下单的量」)。
      if (_aggregateTable.inactiveSourceContext(group)) {
        return Tooltip(
          message: '$_tableTransferredSourceReason\n这一行已没有要下单的量。',
          child: Text(
            '0',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      }
      return Tooltip(
        message:
            '这一行没有要下单的量：需要数量与还缺数量都是 0'
            '（同物料的需求记在它的需求行上，缺口也已覆盖）。要额外备货请在有缺口的行上填数。',
        child: Text(
          '0',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    // 行内「下达」按钮撤掉后(2026-09-22 用户口径「物料办理只要调拨」)，
    // 「这一行为什么下不了单」的人话原因改挂在这一格上 —— 原来它只挂在那个
    // 置灰按钮的悬浮里，是全表唯一常驻的解释面，不能跟着按钮一起消失。
    final blocked = _tableIssueBlockedReason(group);
    final shortBy = _tableBelowMinimumBy(group);
    final field = _materialTableQtyField(
      theme,
      key: 'material-analysis-order-qty-${group.key}',
      controller: _tableOrderQtyController(group),
      enabled: !_busy && (_canNotify || _canGenerate),
      hintText: _qty(_tableGroupResidual(group)),
      // 带下层的行改量要带动子层：记下用户亲手填的数，去抖后向服务端要重算。
      onTyped: (text) => _onTableQtyTyped(group, text),
      invalid: () => _tableOrderQtyInvalid(group),
    );
    final hint = [
      if (shortBy != null)
        '本次只下 ${shortBy.typed}，'
            '比这一行的「还需安排」${shortBy.floor} 少 ${shortBy.shortBy}。'
            '没下的部分仍留在这一行，下一轮可以接着下。',
      if (blocked != null) '这一行本次下不了单：$blocked',
      if (blocked == null && shortBy == null)
        '填多少下多少。超出需求的部分归公共备货；下层按实际新增制造量重算，缺料时自动预填并勾选。',
      if (_draftRoute(group) case final route?) ?_orderPolicyHint(group, route),
    ].join('\n');
    return Tooltip(message: hint, child: field);
  }

  String? _materialTableAppendQtyText(_MaterialTableRow row) {
    if (row.aggregate case final aggregate?) {
      return _aggregateTable.appendText(aggregate);
    }
    final group = _tableEditableGroup(row);
    if (group == null || !_tableGroupIssued(group)) return '—';
    return _tableAppendQtyControllers[group.key]?.text ??
        _qty(_tableDefaultSubmitQty(group));
  }

  Widget _materialTableAppendQtyCell(ThemeData theme, _MaterialTableRow row) {
    if (row.aggregate case final aggregate?) {
      return _aggregateTable.quantityCell(theme, aggregate, append: true);
    }
    if (row.isAggregateSource) {
      return Text(_materialTableAppendQtyText(row) ?? '—');
    }
    final group = _tableEditableGroup(row);
    if (group == null) return const Text('—');
    if (_aggregateTable.ownsLine(group.representative.materialLineId)) {
      return _aggregateTable.lockedText(
        _materialTableAppendQtyText(row) ?? '—',
      );
    }
    if (_tableAggregateDelegatedShare(group) != null &&
        group.representative.aggregatePreparation == null) {
      return Tooltip(
        message: '这一行的下单来源信息尚未完整返回，请刷新后重试。',
        child: Text(
          '—',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    // 还没下达过的行没有「追加」可言：这一格恒为 0 且不可填，避免两列都能填
    // 造成「到底该填哪个」的歧义。
    if (!_tableGroupIssued(group)) {
      return Tooltip(
        message: '这一行还没下达过，本次要下多少请填左边的「下单数量」。',
        child: Text(
          '0',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return _materialTableQtyField(
      theme,
      key: 'material-analysis-append-qty-${group.key}',
      controller: _tableAppendQtyController(group),
      enabled: !_busy && (_canNotify || _canGenerate),
      hintText: '0',
      // 追加格也要带动子层(用户口径 2026-09-21：「追加对应的子层级也要追加数量」)。
      // 少这一句时，「还需安排为 0 的已下达中间层」只能在这一格填数，填了却既不
      // 进 _tableUserTypedQty、也不触发重算——子层纹丝不动，提交时还因为提交量
      // 读不到而被静默剔掉。两格共用同一个提交单元键，所以这里必须走
      // _onTableAppendQtyTyped，让它按「下单格 + 追加格」的合计写那一个键。
      onTyped: (text) => _onTableAppendQtyTyped(group, text),
      onFinished: _finishPreparationQuantityEditing,
      invalid: () => _tableAppendQtyInvalid(group),
    );
  }

  /// 数量输入框：填错 / 填少了当场描红(RequiredCellFrame 订阅控制器 + 估算 tick，
  /// 父行改大让这一行的还需安排涨上去时红框也立刻出现)。
  Widget _materialTableQtyField(
    ThemeData theme, {
    required String key,
    required TextEditingController controller,
    required bool enabled,
    required String hintText,
    required bool Function() invalid,
    ValueChanged<String>? onTyped,
    ValueChanged<BuildContext>? onFinished,
  }) => Builder(
    builder: (fieldContext) => Focus(
      skipTraversal: true,
      onFocusChange: (focused) {
        if (!focused && fieldContext.mounted) onFinished?.call(fieldContext);
      },
      child: RequiredCellFrame(
        listenable: Listenable.merge([controller, _tableEstimateTick]),
        isEmpty: invalid,
        child: TextField(
          key: ValueKey(key),
          controller: controller,
          enabled: enabled,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: theme.textTheme.bodySmall,
          decoration: UtenInputDecoration(
            InputDecoration(isDense: true, hintText: hintText),
          ),
          // 敲键不 setState：整张表几百行，每敲一下重建一次树会卡。数量本身由
          // controller 驱动重绘，依赖数量的列(办理可办性、筛选桶)在失焦/提交时重算。
          onChanged: onTyped,
          onSubmitted: (_) {
            setState(() {});
            onFinished?.call(fieldContext);
          },
        ),
      ),
    ),
  );

  // ------------------------- 生产车间 / 负责人 -------------------------

  /// 只有实际需要车间生产的行(自制)要求指派。采购、委外不需要。
  bool _tableAssignable(_MaterialGroup? group) =>
      group != null && _tableIssueTarget(group).viaWorkshop;

  String? _materialTableProductionWorkshopText(_MaterialTableRow row) {
    if (row.aggregate case final aggregate?) {
      return _aggregateTable.workshopText(aggregate);
    }
    final group = _tableEditableGroup(row);
    if (!_tableAssignable(group)) return '—';
    return _tableWorkshopFor(group!).name ?? '待指派';
  }

  Widget _materialTableProductionWorkshopCell(
    ThemeData theme,
    _MaterialTableRow row, {
    bool revealKey = true,
  }) {
    if (row.aggregate case final aggregate?) {
      return _aggregateTable.assignmentCell(theme, aggregate, worker: false);
    }
    if (row.isAggregateSource) {
      return Text(_materialTableProductionWorkshopText(row) ?? '—');
    }
    final group = _tableEditableGroup(row);
    if (!_tableAssignable(group)) return const Text('—');
    if (_aggregateTable.ownsLine(group!.representative.materialLineId)) {
      return _aggregateTable.lockedText(
        _materialTableProductionWorkshopText(row) ?? '—',
      );
    }
    // 已下达行展示其实际工单指派；追加仍使用同一来源身份。
    final sharedBatch = _tableIssuedAssignmentOf(group);
    if (sharedBatch != null) {
      return Tooltip(
        key: ValueKey('material-analysis-workshop-${group.key}'),
        message: sharedBatch.planExecutionWorkshopName == null
            ? '生产车间以已下达工单为准'
            : '生产车间：${sharedBatch.planExecutionWorkshopName}',
        child: Text(sharedBatch.planExecutionWorkshopName ?? '—'),
      );
    }
    final current = _tableWorkshopFor(group);
    // 滚动定位 GlobalKey 只在主表挂一份: 补下层物料页与主表同时在树里,
    // 同组同 Key 双挂会触发 Duplicate GlobalKeys 崩帧。
    final cell = _materialTableAssignmentCell(
      theme,
      key: 'material-analysis-workshop-${group.key}',
      text: current.name ?? '点击选择',
      autofilled: current.autofilled && current.id != null,
      empty: current.id == null,
      semanticsLabel: '生产车间 ${current.name ?? "待指派"}',
      onTap: _canGenerate && !_busy
          ? () => unawaited(_pickTableWorkshop(group))
          : null,
    );
    return revealKey
        ? KeyedSubtree(key: _tableAssignmentCellKey('W', group), child: cell)
        : cell;
  }

  String? _materialTableResponsibleText(_MaterialTableRow row) {
    if (row.aggregate case final aggregate?) {
      return _aggregateTable.workerText(aggregate);
    }
    final group = _tableEditableGroup(row);
    if (!_tableAssignable(group)) return '—';
    return _tableWorkerFor(group!).name ?? '待指派';
  }

  Widget _materialTableResponsibleCell(
    ThemeData theme,
    _MaterialTableRow row, {
    bool revealKey = true,
  }) {
    if (row.aggregate case final aggregate?) {
      return _aggregateTable.assignmentCell(theme, aggregate, worker: true);
    }
    if (row.isAggregateSource) {
      return Text(_materialTableResponsibleText(row) ?? '—');
    }
    final group = _tableEditableGroup(row);
    if (!_tableAssignable(group)) return const Text('—');
    if (_aggregateTable.ownsLine(group!.representative.materialLineId)) {
      return _aggregateTable.lockedText(
        _materialTableResponsibleText(row) ?? '—',
      );
    }
    // 已下达行展示其实际工单负责人。
    final sharedBatch = _tableIssuedAssignmentOf(group);
    if (sharedBatch != null) {
      return Tooltip(
        key: ValueKey('material-analysis-worker-${group.key}'),
        message: sharedBatch.planExecutionResponsibleName == null
            ? '负责人以已下达工单为准'
            : '负责人：${sharedBatch.planExecutionResponsibleName}',
        child: Text(sharedBatch.planExecutionResponsibleName ?? '—'),
      );
    }
    final current = _tableWorkerFor(group);
    // 与生产车间格同规则: 定位键只在主表挂, 补料页复用格子时不再双挂 GlobalKey。
    final cell = _materialTableAssignmentCell(
      theme,
      key: 'material-analysis-worker-${group.key}',
      text: current.name ?? '点击选择',
      autofilled: current.autofilled && current.id != null,
      empty: current.id == null,
      semanticsLabel: '负责人 ${current.name ?? "待指派"}',
      onTap: _canGenerate && !_busy
          ? () => unawaited(_pickTableWorker(group))
          : null,
    );
    return revealKey
        ? KeyedSubtree(key: _tableAssignmentCellKey('R', group), child: cell)
        : cell;
  }

  // ------------------------- 一张表的下达编排 -------------------------

  String _tableGroupLabel(_MaterialGroup group) {
    final material = group.representative;
    final name = material.goodsName?.trim();
    if (name?.isNotEmpty == true) return name!;
    return material.goodsCode?.trim().isNotEmpty == true
        ? material.goodsCode!.trim()
        : '未命名物料';
  }

  /// 本次这一行要提交的数量：下达过的行取「追加下单」，没下过的取「下单数量」。
  String _tableSubmitQtyTextOf(_MaterialGroup group) {
    final append = _tableGroupIssued(group);
    final controller = append
        ? _tableAppendQtyControllers[group.key]
        : _tableOrderQtyControllers[group.key];
    if (controller == null ||
        controller.text ==
            _tableSeededQtyTexts['${append ? 'APPEND' : 'ORDER'}|${group.key}']) {
      return _tableDefaultSubmitQtyText(group, authoritative: true);
    }
    return controller.text.trim();
  }

  double _tableSubmitQtyOf(_MaterialGroup group) {
    // 尚未渲染的行也用同一系统默认量；已有输入框被清空不是“从未填写”。
    return double.tryParse(_tableSubmitQtyTextOf(group)) ?? double.nan;
  }

  /// 用未被本轮输入预扣的公共余额判断，不能拿编辑后变成 0 的余额反过来
  /// 隐藏选择。新服务端的共享池同时覆盖现货、待办理、自制和外部在途。
  double _tableSharedAvailableBeforeEditing(_MaterialGroup group) {
    final material = group.representative;
    return material.preparationSharedAvailableQty ??
        material.preparationAvailableQty ??
        (material.mainWarehousePublicAvailableQty +
            material.sharedFutureClaimableQty);
  }

  bool _tableClaimChoiceMatters(_MaterialGroup group, double? typedQty) {
    final draft =
        _aggregateTable.drafts[_aggregateTable._draftByLine[group
            .representative
            .materialLineId]];
    final quantity =
        typedQty ??
        (draft == null
            ? _tableSubmitQtyOf(group)
            : double.tryParse(draft.totalText) ?? 0);
    return quantity.isFinite &&
        quantity > 0 &&
        _tableSharedAvailableBeforeEditing(group) > 0;
  }

  /// 完成追加输入后询问；失焦和提交按钮可能同帧发生，提交器接管时不另开弹窗。
  void _finishPreparationQuantityEditing(BuildContext fieldContext) {
    final analysisId = _analysis?.analysisId;
    final route = ModalRoute.of(fieldContext);
    unawaited(
      Future<void>(() async {
        if (!mounted ||
            !fieldContext.mounted ||
            route?.isCurrent == false ||
            _analysis?.analysisId != analysisId ||
            _busy ||
            _preparationSubmissionActive ||
            _preparationUseAvailableQty != null) {
          return;
        }
        await _askClaimableSupplyUsage(_selectedIssuableGroups().visible, null);
      }),
    );
  }

  void _setPreparationSupplyUsage(bool? useAvailable) {
    if (!mounted) return;
    setState(() {
      _preparationUseAvailableQty = useAvailable;
      _draftBudget.invalidate();
      _tableEstimateTick.value++;
      _aggregateTable._revision++;
    });
    if (!_preparationSubmissionActive) _aggregateTable.schedulePreview();
  }

  @override
  void _completePreparationSupplyUsage() => _setPreparationSupplyUsage(null);

  /// 一次编辑/提交共用一个选择；取消不发单，失败保留选择，成功后下一轮重新问。
  @override
  Future<bool?> _askClaimableSupplyUsage(
    Iterable<_MaterialGroup> groups,
    Map<_MaterialGroup, double>? pending, {
    bool forceChoice = false,
  }) {
    final active = _preparationUsageQuestion;
    if (active != null) return active;
    if (_aggregateTable.uncertain) {
      return Future.value(
        !(_aggregateTable._submittedRequest?.skipAutoClaim ?? false),
      );
    }
    if (!forceChoice && _preparationUseAvailableQty != null) {
      return Future.value(_preparationUseAvailableQty);
    }
    final relevant = [
      for (final group in groups)
        if (_tableClaimChoiceMatters(group, pending?[group])) group,
    ];
    if (relevant.isEmpty && !forceChoice) return Future.value(true);
    late final Future<bool?> question;
    question = _showPreparationSupplyUsageChoice().whenComplete(() {
      if (identical(_preparationUsageQuestion, question)) {
        _preparationUsageQuestion = null;
      }
    });
    _preparationUsageQuestion = question;
    return question;
  }

  Future<bool?> _showPreparationSupplyUsageChoice() async {
    final analysisId = _analysis?.analysisId;
    var useAvailable = _preparationUseAvailableQty ?? true;
    final confirmed = await UtenDialog.show(
      context,
      title: '本次下单是否使用可用数量抵扣？',
      content: StatefulBuilder(
        builder: (dialogContext, setDialogState) => RadioGroup<bool>(
          groupValue: useAvailable,
          onChanged: (value) =>
              setDialogState(() => useAvailable = value ?? true),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('所选物料有可用余量。本次是先使用这些余量，还是保留余量、继续下单备货？'),
              SizedBox(height: 12),
              RadioListTile<bool>(
                value: true,
                title: Text('优先使用可用余量'),
                subtitle: Text('按本次需求使用可采用的余量，不足部分再下单；页面继续按选中数量预扣可用量。'),
              ),
              RadioListTile<bool>(
                value: false,
                title: Text('保留余量，额外下单'),
                subtitle: Text('不预扣现有余量，按填写数量新增下单；超出需求的部分成为公共备货，增加计划可用量。'),
              ),
              SizedBox(height: 4),
              Text(
                '应用于本次所选行，可在表格上方切换。需求已满足的追加量按公共备货办理，不重复占用需求。正式可用量以下单结果为准，未入库的备货不能直接领用。',
              ),
            ],
          ),
        ),
      ),
      confirmLabel: '继续',
    );
    if (confirmed != true || !mounted || _analysis?.analysisId != analysisId) {
      return null;
    }
    _setPreparationSupplyUsage(useAvailable);
    return useAvailable;
  }

  /// 收集当前产品/来源选择下可办理的原始物料身份。产品选择覆盖完整 BOM，
  /// 折叠和分页不撤销其后代选择；不再属于当前来源投影的旧选择另行提示。
  /// 提交器先办理顶层产品，再按父子依赖分轮办理组件；每轮互不依赖的组件
  /// 共用 aggregate 接口自动合单。前一轮成功后，用回执重算下一层自动建议，
  /// 保留人工填写；任一轮失败则停下，保留未完成输入供重试。
  @override
  ({List<_MaterialGroup> visible, int hidden}) _selectedIssuableGroups() {
    final analysis = _analysis;
    if (analysis == null || _selectedMaterialGroupKeys.isEmpty) {
      return (visible: const [], hidden: 0);
    }
    final onScreen = <String, _MaterialGroup>{};
    for (final row in _materialTableRows(analysis)) {
      if (row.contextOnly) continue;
      for (final group
          in row.product != null
              ? _aggregateTable.selectionScope(row)
              : _materialRowAllGroups(row)) {
        onScreen[group.key] = group;
      }
    }
    final visible = <_MaterialGroup>[];
    var hidden = 0;
    for (final key in _selectedMaterialGroupKeys) {
      final group = onScreen[key];
      if (group == null) {
        hidden++;
        continue;
      }
      // 2026-10-07：汇总视图的顶层产品行同样可下单，不再静默丢弃根组——
      // 否则表头全选会把顶层一起勾上、却在「下单(N)」里凭空消失。
      if (_aggregateTable.selectableForOrder(group)) visible.add(group);
    }
    return (visible: visible, hidden: hidden);
  }

  /// [fromShortagePage] = 从「补下层物料」页提交(ADR-117)：不再弹下单后的子层检查
  /// (那一页自己会按新快照列出下一层)，确认框也不提主表里藏起来的勾选行。
  @override
  Future<bool> _submitMaterialTableRows(
    List<_MaterialGroup> groups, {
    bool fromShortagePage = false,
  }) => _withPreparationSubmissionScope(
    () => _submitMaterialTableRowsInScope(
      groups,
      fromShortagePage: fromShortagePage,
    ),
  );

  Future<bool> _submitMaterialTableRowsInScope(
    List<_MaterialGroup> groups, {
    required bool fromShortagePage,
  }) async {
    if (_bomAggregateByMaterial && !fromShortagePage) {
      // 2026-10-07 用户口径「汇总视图顶层也能下单」：本批只要勾了顶层产品行，
      // 就与按产品视图共用同一套编排（一次确认；根行先经 issue-plans/notify
      // 逐产品下达、保留销售来源，其余组件由 [_splitMergeableSupplyGroups] 分流
      // 进汇总通道 merged 段）。顶层永不进 aggregate-orders 请求——服务端对
      // level==0 的拒绝是来源守恒的闸门，保留不动。纯组件批次维持汇总视图自己
      // 的确认框与依赖分轮编排（[_MaterialAggregateSubmission]）。
      final hasRoot = groups.any(
        (group) =>
            _tableIsRootSupply(group.representative) ||
            group.representative.level <= 0,
      );
      if (!hasRoot) return _aggregateTable.submit(groups);
    }
    final analysis = _analysis;
    if (analysis == null || _busy || groups.isEmpty) return false;
    final sessionScope = _sessionScopeKey();
    await _ensureTableMandatoryAssignments(groups);
    if (!mounted ||
        !_sameAnalysisSnapshot(analysis, sessionScope) ||
        !_preparationSubmissionStillCurrent) {
      return false;
    }

    final pending = <_MaterialGroup, double>{};
    final blocked = <String>[];
    // 勾了但本次没有量的行(追加留 0)：批成功后一并撤勾，否则「下单(N)」一直挂着它，
    // _hasUnsubmittedMaterialTableInput 永真、45 秒轮询也不再跑。
    final skipped = <String>{};
    // 只缺「生产车间/负责人」的行先摘出来：这是当场能修好的拦截——新建档货品没有
    // 学习记忆、主档也没写生产车间，首次下达必缺；原来只把它写进确认框的跳过清单，
    // 用户实机(2026-09-25)「全选全部下单，两个顶层没下成」里就是它。提交前就地
    // 弹补派面板，补上就照常进本批，不补才落回跳过清单。
    final needAssignment = <_MaterialGroup>[];
    // [reason] 传 null 以外的值时跳过重复计算。返回 false = 这一行使整批停下。
    bool enrol(_MaterialGroup group, String? reason) {
      if (reason != null) {
        blocked.add('${_tableGroupLabel(group)}：$reason');
        return true;
      }
      final qty = _tableSubmitQtyOf(group);
      if (_tableRootMakePlanLineId(group) != null &&
          _tableRootPlanQty(group, qty) == null) {
        context.appWarning('根产品数量无法按来源单位精确换算，请按来源单位核对数量后再下单');
        return false;
      }
      if (!qty.isFinite || qty < 0) {
        context.appWarning(
          _tableDefaultSubmitQtyText(group, authoritative: true) == 'NaN'
              ? '「${_tableGroupLabel(group)}」缺少精确数量，请刷新或更新服务端后再下单。'
              : '「${_tableGroupLabel(group)}」请填写有效的非负数量；本次不下可填 0。',
        );
        return false;
      }
      // 追加填 0 = 本次不动这一行，不进提交集合(服务端把「给了身份却不给数量」
      // 当成全量剩余下达，漏掉这一步会凭空多下一单)。
      final route = _draftRoute(group);
      final stockHandoff =
          route != null && _hasRootStockToAllocate(group, route);
      if (qty <= 0 &&
          !stockHandoff &&
          !(_draftRoute(group) == MaterialSupplyRoute.buy &&
              _groupSafetyReplenishmentGapQty(group) > 0.0001)) {
        skipped.add(group.key);
        return true;
      }
      if (_tableIssueTarget(group).viaWorkshop &&
          parseProductionOverproductionPercent(
                _overproductionPercentController(
                  materialLineId: group.representative.materialLineId,
                ).text,
              ) ==
              null) {
        context.appWarning(
          '「${_tableGroupLabel(group)}」允许超产比例填写有误，请填不小于 0 的百分比，最多 4 位小数',
        );
        return false;
      }
      pending[group] = qty;
      return true;
    }

    for (final group in groups) {
      // 汇总视图混批（顶层 + 组件）走本编排时按汇总口径判资格：被汇总草稿
      // 接管的组件行不弹「去按物料汇总」——用户本来就在那里。
      final reason = _tableIssueBlockedReason(
        group,
        forAggregate: _bomAggregateByMaterial,
      );
      if (reason == _tableMissingWorkshopReason ||
          reason == _tableMissingWorkerReason) {
        needAssignment.add(group);
        continue;
      }
      if (!enrol(group, reason)) return false;
    }
    if (needAssignment.isNotEmpty) {
      // 必填没填完不给下(用户口径 2026-09-25「下单前检测是不是真的填完，不然就
      // 不给下单；表格自动滑到那个必填位置」)：自动把表格滚到第一处缺填的格子
      // (上下 + 左右都到位，格子实时红框指路)，补齐后再点下单。行可能藏在别的
      // 分页或横向滚出视口——不能只弹一句话让人自己找。
      await _revealTableAssignmentCell(needAssignment.first);
      if (!mounted || !_preparationSubmissionStillCurrent) return false;
      context.appWarning(
        '还有 ${needAssignment.length} 行没填生产车间/负责人'
        '（自制行必填），已滚动到第一处红框格，请补齐后再下单',
      );
      return false;
    }
    if (pending.isEmpty) {
      if (!mounted || !_preparationSubmissionStillCurrent) return false;
      context.appInfo(
        blocked.isEmpty ? '所选的行本次都没有要下的数量，请先在「下单数量」或「追加下单」里填数' : blocked.first,
      );
      return false;
    }
    // 编辑时未选择的在此补问；额外下单贯穿车间、委外、采购和汇总各段。
    final claimUsage = await _askClaimableSupplyUsage(pending.keys, pending);
    if (claimUsage == null) return false;
    final skipAutoClaim = !claimUsage;
    if (!mounted || !_preparationSubmissionStillCurrent) return false;
    // 根产品保持来源计划；全部组件按同一依赖图先父后子，同料自动合单。
    final split = _splitMergeableSupplyGroups(
      pending.keys.toList(growable: false),
    );
    if (!await _confirmMaterialTableSubmit(
      pending,
      blocked,
      hiddenSelected: fromShortagePage ? 0 : _selectedIssuableGroups().hidden,
    )) {
      return false;
    }
    if (!mounted ||
        !_sameAnalysisSnapshot(analysis, sessionScope) ||
        !_preparationSubmissionStillCurrent) {
      return false;
    }
    // ADR-117：下单前记下每件的累计已下单量，下完比一比就知道这次刚下了什么。
    final issuedBefore = _issuedQtySnapshot();

    final steps = <({String label, bool ok, String? note})>[];
    final done = <String>{};
    const haltNote = '已停在这一步，后面的段没有提交';
    // 一段成功后：记下这些行，并把它们从「用户亲手填的数」里摘掉。服务端那一侧是
    // **加进**计划产出量，留着它下一次重算就把刚下达的量再加一遍；而且
    // _hasUnsubmittedMaterialTableInput 会永远为真，45 秒轮询再也不跑。
    // 注意两套键空间：done 装的是操作组键，填数那张表按物料行 id 记。
    void settle(List<_MaterialGroup> batch) {
      for (final group in batch) {
        done.add(group.key);
        _tableUserTypedQty.remove(group.representative.materialLineId);
      }
    }

    // 提交期间不再自动发层级预览(见 _invalidateMaterialTableCascadePreview)；
    // 正在路上的那一份也作废——它带的填数马上就有一部分落库了。
    _tableSubmitting = true;
    _tableCascadeDebounce?.cancel();
    _tableCascadeTrailing = false;
    _tableCascadeGeneration++;
    // 在路上的那份预览被代际作废后不会再走到它的 finally，预览态要在这里复位，
    // 否则「还缺数量」悬浮一直挂着「正在重算」。
    _tableCascadePreviewing = false;
    // 默认段(按产品通道)有没有中途停住——停住就不走后面的同料合并段。
    var halted = false;
    try {
      // 提交顺序 = **父先子后，跨路线**。一行的需求由它上面每一层的计划产出量决定，
      // 含父件超出需求的公共备货产出(V577/V589「顶层做 5000，委外件就要加工 5000」)。
      // 父件的计划 / 委外申请还没落地时，子件按父件新数量填的量会被服务端当成超出
      // 当时需求的部分、记成公共备货；随后父件的超量把子件需求抬上去，子件行就留下
      // 一截「已经下了却还缺」的幽灵缺口，而且认不回来(公共在途认领不含本分析自己的)。
      // 2026-09-23 实机：委外件「E极插套(酸洗)」的我方供料子件先按采购 5000 提交，
      // 记成需求 2000 + 公共 3000；委外 5000 随后下达把子件需求抬到 5000，子件行
      // 留下 3000 缺口——原来「采购 → 委外」的顺序正好反了。
      // 于是：逐层自上而下，同一层先下达车间(自制)、再下达委外；采购件没有下层，
      // 等全部父件落地后最后一次提交。
      final levels = {
        for (final group in split.separate) group.representative.level,
      }.toList()..sort();
      for (final level in levels) {
        if (!mounted || !_preparationSubmissionStillCurrent) return false;
        final atLevel = split.separate
            .where((group) => group.representative.level == level)
            .toList(growable: false);
        final workshop = atLevel
            .where((group) => _tableIssueTarget(group).viaWorkshop)
            .toList(growable: false);
        if (workshop.isNotEmpty) {
          _lastIssuedPlans = const [];
          final ok = await _issueMaterialTableWorkshopBatch(
            workshop,
            pending,
            skipAutoClaim: skipAutoClaim,
          );
          if (!mounted || !_preparationSubmissionStillCurrent) return false;
          // ADR-104：追加并入了还没开工的原计划(同一单号)时如实说出来，免得用户去
          // 生产计划列表找一张不存在的新单。
          final merged = _lastIssuedPlans
              .where((plan) => plan.mergedIntoExisting)
              .length;
          steps.add((
            label:
                '下达车间(第 $level 层，${workshop.length} 行'
                '${merged > 0 ? '，其中 $merged 张并入原计划' : ''})',
            ok: ok,
            note: ok ? null : haltNote,
          ));
          if (!ok) {
            halted = true;
            break;
          }
          settle(workshop);
        }
        final subcontract = atLevel
            .where(
              (group) =>
                  !_tableIssueTarget(group).viaWorkshop &&
                  _draftRoute(group) == MaterialSupplyRoute.subcontract,
            )
            .toList(growable: false);
        if (subcontract.isNotEmpty) {
          final ok = await _notifyMaterialTableBatch(
            MaterialSupplyRoute.subcontract,
            subcontract,
            pending,
            skipAutoClaim: skipAutoClaim,
          );
          if (!mounted || !_preparationSubmissionStillCurrent) return false;
          steps.add((
            label: '下达委外(第 $level 层，${subcontract.length} 行)',
            ok: ok,
            note: ok ? null : haltNote,
          ));
          if (!ok) {
            halted = true;
            break;
          }
          settle(subcontract);
        }
      }
      if (!halted) {
        final buy = split.separate
            .where(
              (group) =>
                  !_tableIssueTarget(group).viaWorkshop &&
                  _draftRoute(group) == MaterialSupplyRoute.buy,
            )
            .toList(growable: false);
        if (buy.isNotEmpty) {
          final ok = await _notifyMaterialTableBatch(
            MaterialSupplyRoute.buy,
            buy,
            pending,
            skipAutoClaim: skipAutoClaim,
          );
          if (!mounted || !_preparationSubmissionStillCurrent) return false;
          steps.add((
            label: '下达采购(${buy.length} 行)',
            ok: ok,
            note: ok ? null : haltNote,
          ));
          if (ok) {
            settle(buy);
          } else {
            halted = true;
          }
        }
      }
    } finally {
      _tableSubmitting = false;
    }

    // 汇总段：默认段(根产品计划 + 不合并的行)全部落地后再走。父子顺序由
    // 「根产品先出计划」保证，汇总预览/提交也按每段结束后的最新快照核对。
    if (!mounted || !_preparationSubmissionStillCurrent) return false;
    if (!halted && split.merged.isNotEmpty && mounted) {
      final aggregateOk = await _aggregateTable.submit(
        split.merged,
        confirmed: true,
        skipAutoClaim: skipAutoClaim,
      );
      steps.add((
        label:
            '同料合并下达(${split.merged.length} 行 → '
            '${split.merged.map((group) => _aggregateKeyOf(group.representative)).toSet().length} 种物料)',
        ok: aggregateOk,
        note: aggregateOk ? null : '未完成的行保留本次数量，可在当前页面继续下单',
      ));
    }

    if (!mounted || !_preparationSubmissionStillCurrent) return false;
    // 成功下达的行：追加格回 0、勾选撤掉；失败的保留，让人原地重试。
    setState(() {
      if (steps.every((step) => step.ok)) {
        _selectedMaterialGroupKeys.removeAll(skipped);
      }
      for (final key in done) {
        _tableAppendQtyControllers[key]?.text = '0';
        _tableSeededQtyTexts['APPEND|$key'] = '0';
        _selectedMaterialGroupKeys.remove(key);
        _tableAutoSelectedKeys.remove(key);
        _tableUserDeselectedKeys.remove(key);
        // 下单格里用户填的数已经落库：把它交还给系统(记成当前系统预填值)，紧接着的
        // 回填就会换成新快照的值。不交还的话这一格永远算「有未提交的手填」，
        // 45 秒轮询再也不跑。
        final order = _tableOrderQtyControllers[key];
        if (order != null) _tableSeededQtyTexts['ORDER|$key'] = order.text;
      }
      // 刚落库的那批已经进了权威快照，上一份模拟快照连同它派生的预填一并作废；
      // 没下成的行填的数还在，按权威快照就地重估，并且只在这时才补一次服务端重算。
      _invalidateMaterialTableCascadePreview();
      _reseedMaterialTableQtyInputs();
      // 可调拨量随下达变化：作用域作废，由公共装载器重取。
      _tableTransferableInScope = null;
      _requestCompanionReads(const [_CompanionRead.transferableIn]);
    });
    _reportMaterialTableSubmit(steps, blocked);
    final allOk = steps.isNotEmpty && steps.every((step) => step.ok);
    if (allOk) _setPreparationSupplyUsage(null);
    // 下达成功事实与整轮结果分开：根计划或聚合内部前层已经落地时，后层失败
    // 仍须核对剩余子料和催办。完全失败则不触发；失败通知、输入和返回值保留。
    if (_orderedSince(issuedBefore)) {
      if (fromShortagePage) {
        // 补料页下成了：马上核对车间催办(补料页被关掉也照样办结撤卡)。
        unawaited(_reconcileWorkshopUrgesAfterOrder());
      } else {
        unawaited(_checkChildShortagesAfterOrder(issuedBefore));
      }
    }
    return allOk;
  }

  /// 车间段的一层：顶层自制走 planDrafts、其余候选走 candidateInputs，一次 issue-plans。
  ///
  /// 顶层自制与其它自制行走的是**两条不同的通道**：服务端
  /// candidateRoutesByMaterialLine 明确把 ROOT_SUPPLY 排除在候选之外，
  /// 顶层产品行本身就是排产对象，要按 analysisLineId 走 planDrafts。
  /// 当成候选按 materialLineId 提交的话服务端解析不出候选、整批失败。
  Future<bool> _issueMaterialTableWorkshopBatch(
    List<_MaterialGroup> batch,
    Map<_MaterialGroup, double> pending, {
    bool skipAutoClaim = false,
  }) {
    final inputs = <_BucketCandidatePlanInput>[];
    final drafts = <_BucketPlanDraft>[];
    for (final group in batch) {
      // 锚点(顶层 = 产品行自己)已无剩余需求时，本次填的全是追加的公共备货产出。
      // 自制行直接按锚点产品判(服务端同一判据 canSchedule / canIssueSurplus)，不经
      // 估算值——估算值在分段提交期间是清空的，别的时候也可能还带着父行的比例。
      final anchor = _tableIssuedMakeAnchorOf(group);
      // 残差按 10^-4 tick 精确判零：剩余 0.0001 也是私有需求，不能被
      // 0.0001 容差当成「无剩余、纯公共备货」（2026-10-07 数量完整性）。
      final publicSurplusOnly = anchor != null
          ? !anchor.canSchedule && anchor.canIssueSurplus
          : _tableGroupIssued(group) && _tableExactResidualZero(group);
      final rootMakeLineId = _tableRootMakePlanLineId(group);
      if (rootMakeLineId != null) {
        final exact = _tableRootPlanQtyText(group);
        drafts.add(
          _BucketPlanDraft(
            analysisLineId: rootMakeLineId,
            qty: _tableRootPlanQty(group, pending[group]!)!,
            qtyExact: double.parse(exact).abs() >= 10000000000 ? exact : null,
            allowedOverproductionRate: _submittedOverproductionRate(
              materialLineId: group.representative.materialLineId,
            ),
            departmentId: _tableWorkshopFor(group).id,
            workshopName: _tableWorkshopFor(group).name,
            workerId: _tableWorkerFor(group).id,
            publicSurplusOnly: publicSurplusOnly,
          ),
        );
        continue;
      }
      inputs.add(
        _BucketCandidatePlanInput(
          materialLineId: group.representative.materialLineId,
          qty: pending[group]!,
          qtyExact: pending[group]!.abs() >= 10000000000
              ? _tableSubmitQtyTextOf(group)
              : null,
          allowedOverproductionRate: _submittedOverproductionRate(
            materialLineId: group.representative.materialLineId,
          ),
          departmentId: _tableWorkshopFor(group).id,
          workshopName: _tableWorkshopFor(group).name,
          workerId: _tableWorkerFor(group).id,
          publicSurplusOnly: publicSurplusOnly,
        ),
      );
    }
    return _issueWorkshopPlans(
      candidateInputs: inputs,
      planDrafts: drafts,
      silent: true,
      skipAutoClaim: skipAutoClaim,
    );
  }

  /// 主表使用基本单位，根产品计划接口使用原来源单位。不能把200件直接发成200箱。
  double? _tableRootPlanQty(_MaterialGroup group, double baseQty) {
    if (!baseQty.isFinite) return null;
    try {
      return double.parse(_tableRootPlanQtyText(group));
    } on FormatException {
      return null;
    }
  }

  String _tableRootPlanQtyText(_MaterialGroup group) {
    final product = _analysisIndexes(
      _analysis!,
    ).productsById[_tableRootMakePlanLineId(group)];
    return materialQuantityQuotient(
      _tableSubmitQtyTextOf(group),
      materialUnitRateFact(
        product?.quantityFactsExact['unitRate'],
        product?.unitRate,
      ),
    );
  }

  /// 根产品先下达，所有组件统一由来源依赖图调度。不能先提交单来源子件，
  /// 再提交合单父件，否则父件新增产量尚未落地，子件会被错误记成超量。
  ({List<_MaterialGroup> merged, List<_MaterialGroup> separate})
  _splitMergeableSupplyGroups(List<_MaterialGroup> groups) {
    bool root(_MaterialGroup group) =>
        _tableIsRootSupply(group.representative) ||
        group.representative.level <= 0;
    return (
      merged: [
        for (final group in groups)
          if (!root(group)) group,
      ],
      separate: [
        for (final group in groups)
          if (root(group)) group,
      ],
    );
  }

  /// 把表格滚到这一行缺填的「生产车间/负责人」格：必填拦截时定位指路用。
  ///
  /// 行集单页直下(2026-09-27 去分页)，行总在滚动范围内；格子的 GlobalKey 由
  /// [_tableAssignmentCellKey] 在构建时挂上。Scrollable.ensureVisible 会把
  /// 纵向(表体滚动/联动滚动)和横向(表体横滚区)两向的滚动容器都带过去，
  /// 被"上下挡住/左右挡住"都能滑到位。
  Future<void> _revealTableAssignmentCell(_MaterialGroup group) async {
    // 先滚缺的那个格：车间空先滚车间格，车间有了缺负责人再点会滚负责人格。
    final kind = _tableWorkshopFor(group).id == null ? 'W' : 'R';
    final target =
        _tableAssignmentCellKeys['$kind|${group.key}']?.currentContext;
    // 折叠/虚拟化下格子可能还没挂上(列被藏)：定位不到就不硬滚。
    if (target == null || !target.mounted) return;
    await Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: 0.15,
    );
  }

  /// 外发段的一批：采购 / 委外各走既有的 _notifyRoute 链路(裁决 / 分块 /
  /// 幂等 / 409 恢复都在那里)，成功与否以它返回的新快照为准。
  Future<bool> _notifyMaterialTableBatch(
    MaterialSupplyRoute route,
    List<_MaterialGroup> batch,
    Map<_MaterialGroup, double> pending, {
    bool skipAutoClaim = false,
  }) async {
    final view = await _notifyRoute(
      route,
      onlyGroupKeys: batch.map((group) => group.key).toSet(),
      qtyByActionGroupKey: {
        for (final group in batch)
          ?group.representative.actionGroupKey: _tableSubmitQtyTextOf(group),
      },
      silent: true,
      allowExtra: _canOverSupply,
      skipAutoClaim: skipAutoClaim,
    );
    return view != null;
  }

  /// 下单确认弹窗（2026-10-06 用户口径）：不逐行罗列——明细和数量在表格里
  /// 核对，弹窗只做最后一道闸：有问题的行红色点名（本次下不成/与所见不一致
  /// 的事实），没问题就只给「几种 + 共多少」的汇总。
  Future<bool> _confirmMaterialTableSubmit(
    Map<_MaterialGroup, double> pending,
    List<String> blocked, {
    required int hiddenSelected,
  }) async {
    final includedHidden = _aggregateTable.includedOutsideCurrentRows(
      pending.keys,
    );
    final safetyByMaterial = <String, double>{};
    for (final group in pending.keys) {
      if (_draftRoute(group) == MaterialSupplyRoute.buy) {
        safetyByMaterial[_aggregateKeyOf(group.representative)] =
            _groupSafetyReplenishmentGapQty(group);
      }
    }
    final safety = safetyByMaterial.values.fold<double>(
      0,
      (sum, value) => sum + value,
    );
    final totalText = _aggregateTable.sumQuantityTexts([
      for (final group in pending.keys) _tableSubmitQtyTextOf(group),
      _qty(safety),
    ]);
    // 品种数按 goods/color/unit 身份去重（与「按物料汇总」同一把键）：同料多
    // 来源算一种。路线分账一行带过，扫一眼下单去向；顺序即提交顺序。
    final routeKinds = <String, Set<String>>{};
    final routeQty = <String, double>{};
    var handoffOnlyRows = 0;
    for (final entry in pending.entries) {
      final label = _tableIssueTarget(entry.key).label;
      routeKinds
          .putIfAbsent(label, () => <String>{})
          .add(_aggregateKeyOf(entry.key.representative));
      routeQty[label] = (routeQty[label] ?? 0) + entry.value;
      final route = _draftRoute(entry.key);
      if (entry.value <= 0 &&
          route != null &&
          _hasRootStockToAllocate(entry.key, route)) {
        handoffOnlyRows++;
      }
    }
    // 品种数全局去重：同料跨路线（不同来源选了不同路线）也只算一种，
    // 路线分账里的种数各自计各自的，两边不必相等。
    final kinds = <String>{
      for (final group in pending.keys) _aggregateKeyOf(group.representative),
    }.length;
    final routeLine = [
      for (final label in const ['下达车间', '下达委外', '下达采购'])
        if (routeKinds[label] != null)
          '${label.replaceFirst('下达', '')} ${routeKinds[label]!.length} 种'
              ' ${_qty(routeQty[label] ?? 0)}',
    ].join(' · ');
    // 红色问题区：只放「本次下不成」或「和你在表格里看到的不一样」的事实；
    // 检查全部通过时整块不出现。
    final warnings = <String>[
      if (blocked.isNotEmpty) ...[
        '${blocked.length} 行本次不会下单：',
        ...blocked.take(5).map((reason) => '· $reason'),
        if (blocked.length > 5) '…… 以及其余 ${blocked.length - 5} 行',
      ],
      if (handoffOnlyRows > 0) '$handoffOnlyRows 行数量为 0，只交接已分配现货，不新增订货',
      if (includedHidden > 0) '$includedHidden 行在折叠分支或筛选之外，会随本次一起下单',
      // 只排除不再属于当前来源投影的选择；完整产品树中的折叠/跨页行已计入。
      if (hiddenSelected > 0) '$hiddenSelected 行勾选已不在当前产品/来源范围，本次不提交',
    ];
    final theme = Theme.of(context);
    final confirmed = await UtenDialog.show(
      context,
      title: '确认下单 $kinds 种？',
      // Text.rich 而非拼 Column：ADR-150 弹窗正文保持纯文本可被 AI 助手读到。
      content: Text.rich(
        key: const Key('material-submit-confirm-body'),
        TextSpan(
          children: [
            TextSpan(
              text:
                  '共 $kinds 种，合计 $totalText'
                  '${safety > 0.0001 ? '（含公共安全补库 ${_qty(safety)}）' : ''}。',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (routeLine.isNotEmpty)
              TextSpan(
                text: '\n$routeLine',
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (warnings.isNotEmpty)
              TextSpan(
                text: '\n\n${warnings.join('\n')}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
      ),
      confirmLabel: '确认下单',
    );
    return confirmed == true;
  }

  void _reportMaterialTableSubmit(
    List<({String label, bool ok, String? note})> steps,
    List<String> blocked,
  ) {
    if (steps.isEmpty) return;
    final failed = steps.where((step) => !step.ok).toList();
    final summary = steps
        .map((step) => '${step.ok ? "✓" : "✗"} ${step.label}')
        .join('\n');
    if (failed.isEmpty) {
      if (blocked.isEmpty) {
        context.appSuccess('已下达：\n$summary');
        return;
      }
      // 有行被跳过就不能叫纯成功：2026-09-25 用户实机「全选全部下单，两个顶层
      // 没下成」——旧文案把跳过清单折成一句括号挂在成功绿条后面，根本没人看见。
      context.appWarning(
        '已下达：\n$summary\n'
        '另有 ${blocked.length} 行本次没下：\n'
        '${blocked.take(3).map((reason) => '· $reason').join('\n')}'
        '${blocked.length > 3 ? '\n…… 以及其余 ${blocked.length - 3} 行' : ''}',
      );
      return;
    }
    // 如实回报：说清哪几段成了、停在哪一步，别把半截状态说成成功。
    context.appError('下达没有全部完成：\n$summary\n未完成的行仍然勾着，可以修改后重试。');
  }

  /// 必填指派格：空 = 实时红框(自制行这两格必填，2026-09-25 用户口径「必填的框
  /// 要冒红」)；学习默认带出 = 黄框提醒核对，手选后清除(与计划向导同口径)。
  Widget _materialTableAssignmentCell(
    ThemeData theme, {
    required String key,
    required String text,
    required bool autofilled,
    required bool empty,
    required String semanticsLabel,
    VoidCallback? onTap,
  }) => RequiredCellFrame(
    listenable: _tableAssignmentTick,
    isEmpty: () => empty,
    child: Semantics(
      label: semanticsLabel,
      button: onTap != null,
      child: InkWell(
        key: ValueKey(key),
        onTap: onTap,
        borderRadius: BorderRadius.circular(UtenRadius.control),
        child: InputDecorator(
          decoration: applyAutofillHint(
            InputDecoration(
              isDense: true,
              suffixIcon: Icon(
                empty ? Icons.search_rounded : Icons.unfold_more_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              suffixIconConstraints: const BoxConstraints(minWidth: 18),
            ),
            theme,
            autofilled: autofilled,
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: empty
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    ),
  );

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
    final pending = row.aggregate == null
        ? material?.sharedFuturePendingQty
        : row.aggregate!.paths.every(
            (path) => path.sharedFuturePendingQty != null,
          )
        ? row.aggregate!.paths.fold<double>(
            0,
            (sum, path) => sum + path.sharedFuturePendingQty!,
          )
        : null;
    final late = row.aggregate == null
        ? material?.lateSharedFutureAvailableQty ?? 0
        : row.aggregate!.paths.fold<double>(
            0,
            (max, path) => path.lateSharedFutureAvailableQty > max
                ? path.lateSharedFutureAvailableQty
                : max,
          );
    final message = pending != null && pending > 0
        ? '公共已认领未实收 ${_qty(pending)}；尚需下达 ${_qty(recommended)}'
        : recommended <= 0
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
        : late > 0
        ? '晚到/交期未明确供给 ${_qty(late)}（默认接受）；当前尚需下达 ${_qty(recommended)}'
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
    final bomMissing = _tableRowBomMissingLabel(row);
    if (bomMissing != null) return bomMissing;
    if (_rootExternalSupplyRow(row) && (row.product?.remainingQty ?? 1) <= 0) {
      return _l10n.materialRootSupplyCompleted;
    }
    if (row.product != null && !_rootExternalSupplyRow(row)) {
      return _productExecutionStage(row.product!)?.displayLabel ??
          _materialProductStatus(row.product!);
    }
    if (row.aggregate != null) {
      final coverage = row.aggregate!.coverage;
      return coverage.requiredText == null
          ? '合格库存保障待核对'
          : '合格库存保障 ${coverage.coveredText}/${coverage.requiredText}';
    }
    final group = row.group;
    return group == null
        ? null
        : _materialStatus(Theme.of(context), group).label;
  }

  /// 按物料汇总行的「合格库存保障」显式档位（ADR-169，与进度列头筛选的
  /// aggregateCovered/Partial/Uncovered 三桶同一判据）：已覆盖=绿（齐套）、
  /// 部分覆盖=紫（部分就绪）、未覆盖=琥珀（等自己下单，与「未下达」同族）；
  /// 保障待核对不映射，保持无色纯文本。
  UtenStatusBadgeType? _materialAggregateCoverageBadgeType(
    _MaterialAggregate aggregate,
  ) {
    if (aggregate.coverage.requiredText == null ||
        aggregate.coverage.coveredText == null) {
      return null;
    }
    if (aggregate.totalDemandSupplyGap <= 0) {
      return UtenStatusBadgeType.success;
    }
    if (aggregate.coverageRatio <= 0) {
      return UtenStatusBadgeType.warning;
    }
    return UtenStatusBadgeType.violet;
  }

  MaterialPreparationStatusStyle _materialTableStatusStyle(
    ThemeData theme,
    _MaterialTableRow row,
  ) {
    final block = row.group == null
        ? _analysis?.planningBlockedReason(
            row.product?.analysisLineId ?? row.material?.analysisLineId ?? '',
          )
        : _planningBlockForGroup(row.group!);
    if (block != null || _tableRowBomMissingLabel(row) != null) {
      return MaterialPreparationStatusStyle.resolve(
        phase: MaterialPreparationStatusPhase.blocked,
      );
    }
    if (_rootExternalSupplyRow(row) && (row.product?.remainingQty ?? 1) <= 0) {
      return MaterialPreparationStatusStyle.resolve(
        phase: MaterialPreparationStatusPhase.completed,
      );
    }
    if (row.product != null && !_rootExternalSupplyRow(row)) {
      final product = row.product!;
      final stage = _productExecutionStage(product);
      return MaterialPreparationStatusStyle.resolve(
        stage: stage,
        actualState: product.planExecutionStatus,
        facetKey: stage == null
            ? (product.canSchedule ? 'pendingIssue' : 'blocked')
            : null,
      );
    }
    // 按物料汇总行不走相位解析：底色由列 cellColor 的
    // [_materialAggregateCoverageBadgeType] 显式定档（绿/紫/琥珀），
    // 文字前景同取该档的成套前景。
    return row.group == null
        ? MaterialPreparationStatusStyle.resolve()
        : _preparationMaterialStatusStyle(theme, row.group!);
  }

  Widget _materialTableStatusCell(ThemeData theme, _MaterialTableRow row) {
    final colors = _materialTableStatusStyle(theme, row);
    // 2026-10-08 状态色改版：格内文字/图标一律继承表格注入的
    // DefaultTextStyle（深底切白、亮琥珀底切深字、选中行回落常态字色），
    // 相位图标取同一份样式——不在 builder 里写死颜色。
    Widget label(_StatusView status) => MaterialAnalysisPreparationCell(
      key: ValueKey('material-preparation-status-${row.key}'),
      label: status.label,
      style: colors,
    );
    final planningBlock = row.group == null
        ? _analysis?.planningBlockedReason(
            row.product?.analysisLineId ?? row.material?.analysisLineId ?? '',
          )
        : _planningBlockForGroup(row.group!);
    if (!row.contextOnly && planningBlock != null) {
      return label(_StatusView(planningBlock));
    }
    final bomMissing = _tableRowBomMissingLabel(row);
    if (bomMissing != null) {
      return Tooltip(
        message:
            '这个委外件还没有维护直属物料，系统已通知研发完善 BOM；'
            '研发保存后物料分析会自动更新，再下达委外',
        child: label(_StatusView(bomMissing)),
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
      return label(_StatusView(_l10n.materialRootSupplyCompleted));
    }
    if (row.product != null && !_rootExternalSupplyRow(row)) {
      final stage = _productExecutionStage(row.product!);
      return label(
        _StatusView(
          stage == null ? _materialProductStatus(row.product!) : stage.label,
        ),
      );
    }
    if (row.aggregate != null) {
      final aggregate = row.aggregate!;
      final coverage = aggregate.coverage;
      if (coverage.requiredText == null || coverage.coveredText == null) {
        return const Tooltip(
          message: '来源或合格库存数量缺少可核实的精确事实，请刷新后核对；在途供给不计作合格库存。',
          child: Text('保障待核对'),
        );
      }
      final ratio = aggregate.coverageRatio;
      // 2026-10-08 状态色改版收尾：底色在列 cellColor（同一档），文字不写死
      // 成套前景——继承表格 DefaultTextStyle 的双向对比度（深底切白/琥珀底
      // 切深字），选中行 cellColor 让位时回落常态字色。
      return Semantics(
        container: true,
        label:
            '合格库存保障 ${coverage.coveredText}/${coverage.requiredText}，百分之 ${(ratio * 100).toStringAsFixed(0)}',
        child: ExcludeSemantics(
          // 2026-10-06 行高统一口径：进度形态改单层 Row（参考
          // ProductionFlowProgress 的「进度条 + 文字」横排），不再上下两层。
          child: Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 8,
                  // 2026-09-27 用户口径：进度条颜色全站统一主题主色，不随状态色变。
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              // 文字与进度条分剩余宽度：窄列/放大字号时省略号截断，全量数字由
              // 上面 Semantics 的 label 播报。
              Flexible(
                child: Text(
                  '保障 ${coverage.coveredText}/'
                  '${coverage.requiredText} '
                  '(${(ratio * 100).toStringAsFixed(0)}%)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // 字号随进度条收小、字重保持加粗；颜色继承（见上方注释）。
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
        return label(_StatusView(_l10n.materialRootRoutePending));
      }
      return Text(_materialTableStatusText(row) ?? '—');
    }
    final status = _materialStatus(theme, group);
    Widget result = label(status);
    if (_notifiedTargetOf(group.representative) != null) {
      // 2026-10-06 行高统一口径：去掉格内 minHeight 48 定高与竖向内边距，
      // 点击区由整格（InkWell 撑满单元格）提供。
      result = InkWell(
        key: ValueKey(
          'material-table-supply-progress-${group.representative.materialLineId}',
        ),
        onTap: _busy ? null : () => _showSupplyProgress(group),
        child: Align(alignment: Alignment.centerLeft, child: result),
      );
    }
    // 借用徽章与状态文字同一行（2026-10-06 行高统一口径：徽章单行省略号，
    // 全量明细在行详情与悬浮里）。
    return Row(
      children: [
        Flexible(child: result),
        Expanded(child: _borrowBadges(theme, group.representative)),
      ],
    );
  }

  List<UtenContextMenuEntry> _materialTableRowMenu(_MaterialTableRow row) {
    final actions = _materialTableRowMenuActions(row);
    // 行级动作为空的行也挂整树展开/收起（2026-10-08 用户口径）：汇总视图的
    // 顶层产品行（无根供料组）与聚合物料行没有行级动作，但在哪行右键都该
    // 顺手收/放整棵树。孤儿警示头行（无组无产品无聚合）两者皆空，不弹菜单。
    if (actions.isEmpty) {
      return row.aggregate != null || row.product != null
          ? _bomExpansionMenuEntries()
          : const [];
    }
    return [...actions, const UtenMenuDivider(), ..._bomExpansionMenuEntries()];
  }

  List<UtenContextMenuEntry> _materialTableRowMenuActions(
    _MaterialTableRow row,
  ) {
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
        row.material?.hasPriorityMakeSupplement != true &&
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
        if (group.representative.hasPriorityMakeSupplement && _canGenerate)
          UtenMenuItem(
            label: '让料后补自制',
            icon: Icons.factory_outlined,
            enabled:
                !_busy &&
                _isExecutableSupplyGroup(group, MaterialSupplyRoute.make),
            onTap: () async {
              setState(
                () => _selectedPlanLineIds.add(
                  group.representative.materialLineId,
                ),
              );
              await _openBucketDetail(_AnalysisBucket.workshop);
            },
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
      MaterialSupplyRoute.subcontract => '下达委外',
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
          final before = _issuedQtySnapshot();
          var ordered = false;
          switch (route) {
            case MaterialSupplyRoute.buy:
            case MaterialSupplyRoute.subcontract:
              ordered =
                  await _notifyRoute(route, onlyGroupKeys: {group.key}) != null;
            case MaterialSupplyRoute.make:
              break;
          }
          // ADR-117：委外件下单后同样查一遍下层(采购件没有下层，查了也是空)。
          if (ordered && mounted) {
            unawaited(_checkChildShortagesAfterOrder(before));
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
    builder: (dialogContext) => ValueListenableBuilder<int>(
      valueListenable: materialDetailRevision,
      builder: (dialogContext, _, _) {
        final theme = Theme.of(dialogContext);
        final currentGroup = _analysis == null
            ? null
            : _analysisIndexes(
                _analysis!,
              ).groupsByLine[group.representative.materialLineId];
        final displayedGroup = currentGroup ?? group;
        final material = displayedGroup.representative;
        final row = _MaterialTableRow(
          kind: _MaterialTableRowKind.material,
          key: group.key,
          sequence: '',
          depth: 0,
          material: material,
          group: displayedGroup,
        );
        return AlertDialog(
          title: Text(material.goodsName ?? material.goodsCode ?? '物料详情'),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _nodeDetails(theme, displayedGroup),
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
                  if (_canClaimMaterialSharedFuture(displayedGroup))
                    UtenButton(
                      key: ValueKey(
                        'material-detail-claim-shared-${material.materialLineId}',
                      ),
                      type: UtenButtonType.tonal,
                      icon: Icons.call_received_rounded,
                      onPressed: _busy
                          ? null
                          : () => _claimSharedFuture({displayedGroup.key}),
                      child: const Text('采用公共在途'),
                    ),
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
    ),
  );

  /// 「物料 / 调拨」的简化选择器入口：三个调入按钮 + 完整详情。
  /// 子弹窗返回后由选择器自行刷新可调来源数量。
  @override
  Future<void> _showTransferLauncher(_MaterialGroup group) async {
    final analysis = _analysis;
    if (analysis == null) return;
    final material = group.representative;
    await showMaterialTransferLauncher(
      context: context,
      repository: ref.read(productionPlanRepositoryProvider),
      analysis: analysis,
      material: material,
      qtyText: _qty,
      spotEnabled: !_busy && _canCrossReallocateIn(material),
      futureEnabled: !_busy && _canFutureTransferIn(material),
      claimEnabled: !_busy && _canClaimMaterialSharedFuture(group),
      sharedSourceCount: () {
        final current = _analysis;
        if (current == null) return 0;
        final indexes = _analysisIndexes(current);
        final fresh = indexes.groupsByLine[material.materialLineId];
        final representative = (fresh ?? group).representative;
        final refCount = representative.sharedFutureSupplyRefs
            .where((ref) => ref.availableToClaimQty > 0)
            .length;
        if (refCount > 0) return refCount;
        // 明细来源受权限保护或未展开时，按公共余量/晚到池是否有量兜底为 1，
        // 避免把可用入口误置灰。
        final pool =
            representative.publicSurplusRemainingQty +
            representative.lateSharedFutureAvailableQty;
        return pool > 0 ? 1 : 0;
      },
      onSpotReceive: () =>
          _showCrossReallocationDialog(material, receiveIntoCurrent: true),
      onFutureReceive: () => _showCrossReallocationDialog(
        material,
        receiveIntoCurrent: true,
        futureTransfer: true,
      ),
      onClaimShared: () => _claimSharedFuture({group.key}),
      onOpenFullDetails: () => _showMaterialTableDetails(group),
    );
  }

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
    final sessionScope = _sessionScopeKey();
    final reason = await _promptCancellationReason(
      _l10n.materialRevokeRootStock,
      confirmLabel: '确认撤回',
      dismissLabel: '暂不撤回',
    );
    if (!mounted || reason == null) return false;
    if (_busy ||
        !_canRevokeRootOutput ||
        !_sameAnalysisSnapshot(analysis, sessionScope)) {
      context.appWarning('分析状态或撤回权限已变化，请按最新资料重新核对撤回');
      return false;
    }
    final key = businessIdempotencyKey(
      'material-root-output-revoke',
      '${analysis.analysisId}|$eventId|${analysis.version}|${analysis.fingerprint}|$reason',
    );
    setState(() => _cancellingAction = true);
    // 与取消分析同款的页面级遮罩(只跟网络段)。
    bucketActionBusyMessage.value = '正在撤回现货交接';
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .revokeMaterialRootStockOutput(
            analysis: analysis,
            eventId: eventId,
            idempotencyKey: key,
            reason: reason,
          );
      bucketActionBusyMessage.value = null;
      if (!mounted) return false;
      if (!_sameAnalysisSnapshot(analysis, sessionScope)) {
        setState(() => _cancellingAction = false);
        return false;
      }
      setState(() {
        _cancellingAction = false;
        _applyAnalysis(view);
      });
      context.appSuccess(_l10n.materialRootOutputReversed);
      return true;
    } catch (error) {
      bucketActionBusyMessage.value = null;
      if (!mounted) return false;
      if (!_sameAnalysisSnapshot(analysis, sessionScope)) {
        setState(() => _cancellingAction = false);
        return false;
      }
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

  MaterialAnalysisSupplyAction? _supplyActionOf(String? actionId) =>
      actionId == null
      ? null
      : _analysis?.supplyActions
            .where((action) => action.actionId == actionId)
            .firstOrNull;

  String? _supplyOperationType(String? actionId) =>
      _supplyActionOf(actionId)?.operationType;

  bool _isSharedFutureClaimAction(String? actionId) =>
      _supplyOperationType(actionId) == 'SHARED_FUTURE_CLAIM';

  bool _canCancelSpecificAction(String? actionId) {
    if (!_canCancelAction || actionId == null) return false;
    final action = _supplyActionOf(actionId);
    if (action == null) return false;
    if (const {
      'CANCELLED',
      'WITHDRAWN',
      'REVERSED',
      'DONE',
    }.contains(action.status)) {
      final pendingReversal =
          _analysis?.materials.any(
            (material) => material.notifiedTargets.any(
              (target) =>
                  target.actionId == actionId &&
                  target.notificationReversalPending,
            ),
          ) ??
          false;
      if (!pendingReversal) return false;
    }
    final operation = action.operationType;
    if (operation == 'FUTURE_TRANSFER') return false;
    if (operation == 'AGGREGATE_SUPPLY') {
      final action = _supplyActionOf(actionId);
      return _permissions.contains(
        action?.route == MaterialSupplyRoute.make
            ? Perm.productionMaterialAnalysisGenerate
            : Perm.productionMaterialAnalysisNotify,
      );
    }
    return _permissions.contains(
      operation == 'SHARED_FUTURE_CLAIM'
          ? Perm.productionMaterialAnalysisClaimSharedFuture
          : Perm.productionMaterialAnalysisNotify,
    );
  }

  Widget _cancellableActionsPanel(
    BuildContext dialogContext,
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
  ) {
    final analysis = _analysis;
    final resolution = analysis == null
        ? null
        : _analysisIndexes(
            analysis,
          ).sourceGraph.resolve([material.materialLineId]);
    final sources = resolution?.materials ?? [material];
    final targets =
        {
              for (final source in sources)
                for (final target in source.notifiedTargets)
                  if (target.actionId != null) target.actionId!: target,
            }.values
            .where(
              (target) =>
                  target.actionId?.trim().isNotEmpty == true &&
                  (target.status?.toUpperCase() != 'CANCELLED' ||
                      target.notificationReversalPending) &&
                  target.status?.toUpperCase() != 'DONE',
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
                    '${_isSharedFutureClaimAction(target.actionId) ? '公共认领' : target.target?.label ?? '供给'} · '
                    '${target.status ?? '状态待回传'} · '
                    '分配 ${_qty(target.allocatedQty)} · '
                    '${target.documentNo?.trim().isNotEmpty == true ? target.documentNo! : '来源单号受权限保护'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (resolution?.complete != false &&
                    _canCancelSpecificAction(target.actionId))
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
                          : _isSharedFutureClaimAction(target.actionId)
                          ? '撤回认领'
                          : _supplyOperationType(target.actionId) ==
                                'AGGREGATE_SUPPLY'
                          ? '整批撤回'
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
    final draft = await _confirmSharedFutureClaim(eligibleGroups);
    if (draft == null || !mounted) return;
    final byKey = {
      for (final quantity in draft.quantities)
        quantity.actionGroupKey: quantity,
    };
    final chosen = byKey.keys.toList()..sort();
    final chunks = _chunked(chosen);
    var current = analysis;
    var completed = 0;
    setState(() {
      _claimingSharedFuture = true;
      _bulkOperationLabel = '正在采用公共在途';
      _bulkOperationCompleted = 0;
      _bulkOperationTotal = chosen.length;
    });
    try {
      for (final chunk in chunks) {
        final idempotencyKey = businessIdempotencyKey(
          'material-analysis-claim-shared-future',
          '${current.analysisId}|${current.version}|${current.fingerprint}|'
              '${draft.allowLateSupply}|${chunk.map((key) => byKey[key]!.toJson()).join('|')}',
        );
        current = await ref
            .read(productionPlanRepositoryProvider)
            .claimSharedFutureSupply(
              analysis: current,
              idempotencyKey: idempotencyKey,
              actionGroupKeys: chunk,
              quantities: [for (final key in chunk) byKey[key]!],
              allowLateSupply: draft.allowLateSupply,
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
      context.appSuccess('已认领公共供给，尚需下达量已更新；实际合格入库前仍不计现货或可开工量');
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
            ? '已采用 $completed/${chosen.length} 项；余下项目未执行，请按最新结果重新选择。'
            : productionErrorMessage(error, fallback: '采用失败，请刷新后重新选择'),
        force: true,
      );
    }
  }

  Future<MaterialSharedFutureClaimDraft?> _confirmSharedFutureClaim(
    List<_MaterialGroup> groups,
  ) {
    final byAction = <String, List<ProductionMaterialAnalysisMaterial>>{};
    for (final group in groups) {
      final action = group.representative.actionGroupKey;
      if (action != null) {
        byAction.putIfAbsent(action, () => []).addAll(group.paths);
      }
    }
    return showDialog<MaterialSharedFutureClaimDraft>(
      context: context,
      builder: (_) => MaterialSharedFutureClaimDialog(
        rows: [
          for (final entry in byAction.entries)
            MaterialSharedFutureClaimRow(
              actionGroupKey: entry.key,
              poolKey:
                  entry.value.first.preparationPoolKey ??
                  [
                    _analysis?.warehouseId,
                    entry.value.first.goodsId,
                    entry.value.first.colorId,
                    entry.value.first.unitId,
                  ].join('|'),
              label:
                  entry.value.first.goodsName ??
                  entry.value.first.goodsCode ??
                  '物料',
              unit: entry.value.first.unitName ?? '未标单位',
              needQty: entry.value.fold(
                0,
                (sum, material) =>
                    sum + material.additionalSupplyRecommendedQty,
              ),
              timelyQty: entry.value.fold(
                0,
                (max, material) => material.publicSurplusRemainingQty > max
                    ? material.publicSurplusRemainingQty
                    : max,
              ),
              lateQty: entry.value.fold(
                0,
                (max, material) => material.lateSharedFutureAvailableQty > max
                    ? material.lateSharedFutureAvailableQty
                    : max,
              ),
              sources: entry.value
                  .expand((material) => material.sharedFutureSupplyRefs)
                  .where(
                    // Eligibility is exact-source scoped on the server; another
                    // product in this analysis may legitimately supply this row.
                    (source) => source.availableToClaimQty > 0,
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }

  /// 原因选填(2026-09-22 用户口径「弹窗原因不用必填」)：留空服务端记「未填写原因」；
  /// 填了就至少 2 字(库级 CHECK 同口径)。原来必填时空着点确认只在输入框旁冒一个
  /// 小提示、不发请求也不出遮罩, 用户看成「点了没效果」。
  ///
  /// 两个按钮的文案由调用方给：关闭键不能叫「取消」——标题就是「取消物料分析」时,
  /// 「取消」与「确认取消」并排, 点到关闭键就是弹窗一关什么都没发生(同日实机
  /// 「原因填写了, 点了没反应」, 审计里当天没有一条取消请求到过服务端)。
  Future<String?> _promptCancellationReason(
    String title, {
    required String confirmLabel,
    required String dismissLabel,
  }) => showDialog<String>(
    context: context,
    builder: (_) => MaterialRequiredReasonDialog(
      title: title,
      fieldKey: const Key('material-analysis-cancel-reason'),
      initialValue: '',
      requireReason: false,
      info:
          '原因选填，会写入审计记录，留空记为「未填写原因」；'
          '取消后不得把已发生的仓库或执行事实静默抹除。',
      confirmLabel: confirmLabel,
      dismissLabel: dismissLabel,
      minReasonLength: 2,
    ),
  );

  Future<void> _cancelCurrentAnalysis() async {
    final analysis = _analysis;
    if (analysis == null || !_canCancelAnalysis || _busy) return;
    final sessionScope = _sessionScopeKey();
    final reason = await _promptCancellationReason(
      '取消物料分析',
      confirmLabel: '确认取消分析',
      dismissLabel: '暂不取消',
    );
    if (reason == null || !mounted) return;
    if (_busy ||
        !_canCancelAnalysis ||
        !_sameAnalysisSnapshot(analysis, sessionScope)) {
      context.appWarning('分析状态或取消权限已变化，请按最新资料重新核对');
      return;
    }
    final idempotencyKey = businessIdempotencyKey(
      'material-analysis-cancel',
      '${analysis.analysisId}|${analysis.version}|${analysis.fingerprint}|$reason',
    );
    setState(() => _cancellingAnalysis = true);
    // 页面级遮罩(2026-09-22 用户口径「点确认取消没有加载弹窗」)：原来只有右上角
    // 图标里一个 20px 转圈, 看不出在办。遮罩只跟网络段, 收到响应先撤再做别的——
    // 挂着不撤会盖住后面的冲突恢复弹窗。
    bucketActionBusyMessage.value = '正在取消物料分析';
    try {
      await ref
          .read(productionPlanRepositoryProvider)
          .cancelMaterialAnalysis(
            analysis: analysis,
            idempotencyKey: idempotencyKey,
            reason: reason,
          );
      bucketActionBusyMessage.value = null;
      if (!mounted) return;
      setState(() => _cancellingAnalysis = false);
      if (!_sameAnalysisSnapshot(analysis, sessionScope) ||
          !_canCancelAnalysis) {
        return;
      }
      // 2026-09-24 用户口径「确认取消后应该返回任务中心并刷新，现在是还停留在
      // 物料分析准备页面」：分析已取消，本页语义失效，不再就地应用已取消视图；
      // 返回来源页（调度台/记录页/补产横幅都是 await push 打开的，返回即重拉），
      // 深链无栈时归位调度台；徽章(待排产计数)随取消立即重拉。
      refreshBadges(ref);
      context.appSuccess('物料分析已取消');
      popOrBackTo(context, defaultPath: RouteName.productionSchedule);
    } catch (error) {
      bucketActionBusyMessage.value = null;
      if (!mounted) return;
      if (!_sameAnalysisSnapshot(analysis, sessionScope)) {
        setState(() => _cancellingAnalysis = false);
        return;
      }
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

  bool _cancellationStillCurrent(
    ProductionMaterialAnalysisView expected,
    String actionId,
    String sessionScope,
  ) {
    if (_busy ||
        !_sameAnalysisSnapshot(expected, sessionScope) ||
        !_canCancelSpecificAction(actionId)) {
      context.appWarning('分析状态或撤回权限已变化，请按最新资料重新核对撤回');
      return false;
    }
    return true;
  }

  Future<bool> _cancelMaterialAction(String actionId) async {
    if (_supplyOperationType(actionId) == 'AGGREGATE_SUPPLY') {
      return _aggregateTable.cancelAction(actionId);
    }
    final analysis = _analysis;
    if (analysis == null || !_canCancelSpecificAction(actionId) || _busy) {
      return false;
    }
    final sessionScope = _sessionScopeKey();
    final sharedClaim = _isSharedFutureClaimAction(actionId);
    final reason = await _promptCancellationReason(
      sharedClaim ? '撤回公共认领（不撤回原采购 / 委外单）' : '撤回供给任务',
      confirmLabel: '确认撤回',
      dismissLabel: '暂不撤回',
    );
    if (reason == null || !mounted) return false;
    if (!_cancellationStillCurrent(analysis, actionId, sessionScope)) {
      return false;
    }
    final idempotencyKey = businessIdempotencyKey(
      'material-analysis-cancel-action',
      '${analysis.analysisId}|$actionId|${analysis.version}|${analysis.fingerprint}|$reason',
    );
    setState(() => _cancellingAction = true);
    // 与取消分析同款的页面级遮罩(只跟网络段)。
    bucketActionBusyMessage.value = sharedClaim ? '正在撤回公共认领' : '正在撤回供给任务';
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .cancelMaterialSupplyAction(
            analysis: analysis,
            actionId: actionId,
            idempotencyKey: idempotencyKey,
            reason: reason,
          );
      bucketActionBusyMessage.value = null;
      if (!mounted) return false;
      if (!_sameAnalysisSnapshot(analysis, sessionScope)) {
        setState(() => _cancellingAction = false);
        return false;
      }
      setState(() {
        _cancellingAction = false;
        _applyAnalysis(view);
      });
      context.appSuccess(
        sharedClaim ? '公共认领已撤回，原供给单保留；分析已按最新事实重算' : '供给任务已撤回，分析已按最新事实重算',
      );
      return true;
    } catch (error) {
      bucketActionBusyMessage.value = null;
      if (!mounted) return false;
      if (!_sameAnalysisSnapshot(analysis, sessionScope)) {
        setState(() => _cancellingAction = false);
        return false;
      }
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
