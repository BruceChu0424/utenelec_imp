part of 'production_material_analysis_page.dart';

enum _MaterialTableRowKind {
  product,
  material,
  aggregate,
  aggregatePath,
  orphan,
}

/// 主表一行此刻该显示的三个数：需要数量 / 本次要覆盖的量(毛) / 还缺数量(净)。
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

  /// 只读上下文：分页补的祖先（`PAGE_CONTEXT|` 键）或表头筛选未命中、仅因子孙
  /// 命中而保留的祖先。无勾选/下拉/行菜单，不计入业务数量。
  final bool contextOnly;
  final String? rootAnalysisLineId;
  final String? parentMaterialLineId;

  /// 当前投影下的可见直接子件数（树形格「N」徽章）；「只看缺料」等视图下是
  /// 可见子件数而非 BOM 全量。
  final int? childCount;

  /// 分页补祖先行（与表头筛选保留的上下文行区分：后者保留原 widget key）。
  bool get isPageContext => key.startsWith('PAGE_CONTEXT|');

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

  /// 与 [_materialRowsCache] 同生命周期的表头筛选桶（产品视图取自投影，汇总
  /// 视图按聚合行聚合）；始终从「未套表头筛选」的行集算出。
  Map<String, List<MasterFacetBucket>> _materialRowsFacetsCache = const {};
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
    _materialPageCacheSource = null;
    _materialPageCache = null;
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
    final aggregateRows = <_MaterialTableRow>[
      for (var index = 0; index < aggregates.length; index++)
        _MaterialTableRow(
          kind: _MaterialTableRowKind.aggregate,
          key: 'AGGREGATE|${aggregates[index].key}',
          sequence: 'M${index + 1}',
          depth: 0,
          aggregate: aggregates[index],
          hasChildren: aggregates[index].paths.isNotEmpty,
        ),
    ];
    _materialRowsFacetsCache = _materialTableFacetsOf(aggregateRows);
    final filterActive = _hasActiveMaterialTableFilters;
    final result = <_MaterialTableRow>[];
    for (final aggregateRow in aggregateRows) {
      if (filterActive && !_headerFilterMatchesRow(aggregateRow)) continue;
      final aggregate = aggregateRow.aggregate!;
      final prefix = aggregateRow.sequence;
      result.add(aggregateRow);
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
          ),
        );
      }
    }
    return _withSharedTreeProjection(result);
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
    // 2026-09-13 起自制（车间）物料也可采用公共在途；叶子委外限制保留
    // （我方供料 BOM 的委外件不能吃公共超量在途，服务端同口径）。
    // V581 的单一子件委外**同样受限**——它也是我方供料，多出来的量会凭空产生
    // 一份无人负责的子件需求。所以这里判的是 BOM 形状，不是「要不要先自制」。
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
  List<_MaterialGroup> _materialRowGroups(_MaterialTableRow row) =>
      _materialRowAllGroups(
        row,
      ).where(_canEditMaterialRoute).toList(growable: false);

  /// 可勾选的操作组(ADR-102 勾选换义)。
  ///
  /// 勾选从「选行去确认路线」扩成「选行去办事」：一个选中集，底部两个按钮，
  /// 各自只对自己够格的子集动手。所以这里是并集——
  /// 有待提交的路线决定(原口径)，**或**这一行此刻能下单/追加。
  ///
  /// 并集是必须的：以前这个谓词绑死在路线权限上，换义之后只有采购权限的
  /// 采购员会一行都勾不上。
  List<_MaterialGroup> _materialRowSelectableGroups(_MaterialTableRow row) {
    // 「能下单」这一支只对真正持有输入框的行成立：汇总视图的聚合行五列全是
    // 横杠，勾了它提交的就是界面从没显示过的默认值。路线确认那一支不受影响
    // ——它本来就按逐路径的真实节点提交。
    final issuable = _tableEditableGroup(row);
    return _materialRowAllGroups(row)
        .where(
          (group) =>
              (_canRoute &&
                  _canEditMaterialRoute(group) &&
                  _routeGroupSelectable(group)) ||
              (identical(group, issuable) &&
                  _tableIssueBlockedReason(group) == null),
        )
        .toList(growable: false);
  }

  /// 勾选框本身的权限门：四把锁的并集，缺哪一把只是少一个可做的动作，
  /// 不该整列没有勾选框。
  bool get _canSelectMaterialRows =>
      _canRoute || _canNotify || _canGenerate || _canCrossReallocate;

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
    if (_busy || !_canSelectMaterialRows) return;
    final additions = <String>{};
    final removals = <String>{};
    for (final row in rows) {
      final wasSelected = _materialRowSelected(row);
      final nowSelected = selected.contains(row.key);
      if (wasSelected == nowSelected) continue;
      final target = nowSelected ? additions : removals;
      target.addAll(
        _materialRowSelectableGroups(row).map((group) => group.key),
      );
    }
    setState(() {
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
    // 主表要用的两份按需事实(ADR-102)：批量可调拨量决定「物料办理」里调拨
    // 按钮灰不灰，车间/负责人学习记忆决定两个指派列的默认值。都带作用域键，
    // 同一份分析只取一次；放在 build 里是因为它们依赖权限与会话身份，
    // 而这两者在 initState 时还可能没定下来。
    unawaited(Future<void>.microtask(() => _loadTableTransferableIn(analysis)));
    unawaited(
      Future<void>.microtask(() => _loadTableAssignmentDefaults(analysis)),
    );
    // 表头筛选已在投影层生效（祖先保留为只读上下文），行集即最终行；桶随
    // 行缓存一起算出（未套表头筛选的全量行）。
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
        // 已确认且未改动的行无勾选框（F2d）；改下拉后（脏组）勾选框出现并自动勾上。
        idOf: (row) =>
            _canSelectMaterialRows &&
                _materialRowSelectableGroups(row).isNotEmpty
            ? row.key
            : null,
        // idOf 为 null 的行组件默认渲染灰勾选框：已确认未改动的行明确「无勾选框」
        // （勾了也不计数），其余不可勾选行（产品行/只读上下文/不可改路线）保持既有灰框。
        unselectableLeadingBuilder: (_, row) =>
            _materialRowGroups(row).isNotEmpty &&
                _materialRowSelectableGroups(row).isEmpty
            ? const SizedBox.shrink()
            : const Checkbox(value: false, onChanged: null),
        selectionSummaryCount: _selectedMaterialGroupKeys.length,
        onClearSelection: () {
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
        batchActionsBuilder: (_, _) => _bottomActionButtons(),
        items: pageRows,
        // 表头筛选（2026-09-09 用户口径：进度/路线列下拉筛选，UtenTableColumnKit
        // 同款锚定弹窗；2026-09-10 F2a 改稳定键 + 投影级过滤）：bucket 从当前
        // BOM 视图全量行聚合（非当前页、不含表头筛选本身），过滤在节点投影层
        // 生效（保留祖先为只读上下文、箭头/子件数/chip 计数同步），与视图 chip 叠加。
        facets: _materialRowsFacetsCache,
        nullCounts: const {},
        filters: _materialTableFilters,
        onFilterChanged: (key, value) => setState(() {
          _materialTableFilters[key] = value;
          _bomTablePageNo = 1;
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
        canShowRowMenu: (row) => !row.contextOnly && row.group != null,
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

  /// 归属车间列(V590)桶键 = 车间名；还没学过车间(未排产过)的行落「未学习」桶。
  String? _materialTableOwningWorkshopFacetKey(_MaterialTableRow row) {
    if (row.contextOnly) return null;
    final owning = _materialTableOwningWarehouseRef(row);
    final goodsId = owning.goodsId;
    if (goodsId == null || goodsId.isEmpty) return null;
    final name = _materialTableOwningWorkshopText(row)?.trim();
    if (name == null || name.isEmpty || name == '—') {
      return _MaterialAnalysisProductTasksState.owningWorkshopUnsetLabel;
    }
    return name;
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
  /// 否则「确认路线(N)」里计着一条看不见的行。
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
    final owningWorkshopFilter = _materialTableFilterValue('owningWorkshop');
    if (owningWorkshopFilter != null &&
        _materialTableOwningWorkshopFacetKey(row) != owningWorkshopFilter) {
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
  /// 加列必漏其中一处。路线 / 进度 / 所属仓库 / 归属车间四列因为各有特例
  /// (路线要放行改过下拉的脏行、进度要带中文标签、两个仓库列有「未登记」沉底
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
    final owningWorkshopCounts = <String, int>{};
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
      final owningWorkshopKey = _materialTableOwningWorkshopFacetKey(row);
      if (owningWorkshopKey != null) {
        owningWorkshopCounts[owningWorkshopKey] =
            (owningWorkshopCounts[owningWorkshopKey] ?? 0) + 1;
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
    const workshopUnset =
        _MaterialAnalysisProductTasksState.owningWorkshopUnsetLabel;
    final owningWorkshopKeys = owningWorkshopCounts.keys.toList()
      ..sort((a, b) {
        if (a == workshopUnset) return b == workshopUnset ? 0 : 1;
        if (b == workshopUnset) return -1;
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
      // 归属车间(V590)同款：桶键=车间名, 「未学习」沉底。
      'owningWorkshop': [
        for (final key in owningWorkshopKeys)
          MasterFacetBucket(value: key, count: owningWorkshopCounts[key]!),
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
  /// 列顺序按用户口径：先「这一行我能干什么」(物料办理)，再是身份四列、
  /// 供应方式，然后四个数量(需要 / 还缺 / 下单 / 追加)，再是落点与指派
  /// (所属仓库 / 归属车间 / 生产车间 / 负责人)，最后进度。
  ///
  /// 退役的四列及去向：
  /// - 「可用数量」「在途未到」「公共认领未实收」——三者都是「还缺多少」的
  ///   分解项，新的「还缺数量」已经把它们全部扣完，并在悬浮里逐项讲清楚；
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
    ThemeData theme,
  ) => [
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
          '未确认的行框标红——先在这里选好并确认，这一行才能下单；'
          '确认之后仍可随时改，三个下达桶的行与计数会跟着变，'
          '但已经下达过的行要先撤回才能改。',
      cellBuilder: (_, row) => _materialTableRouteCell(theme, row),
    ),
    MasterColumnDef(
      key: 'requiredQty',
      label: _l10n.materialRequired,
      width: 100,
      type: 'number',
      value: (row) => _qty(_materialTableRequiredQty(row)),
      // 父行敲一下这一格自己重建(订阅估算 tick)，整页不动。
      cellBuilder: (_, row) =>
          _materialTableLiveQtyCell(() => _materialTableRequiredQty(row)),
    ),
    // ADR-102：这一列是服务端派生的净口径，客户端不做任何减法。
    MasterColumnDef(
      key: 'netShortageQty',
      label: _l10n.materialShortage,
      width: 112,
      type: 'number',
      value: (row) => _qty(_materialTableNetShortageQty(row)),
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
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => _materialTableOrderQtyCell(theme, row),
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
    // 归属生产车间(V590): 最近一次排产确认/车间改派自动学习回写, 只读展示。
    MasterColumnDef(
      key: 'owningWorkshop',
      label: '归属车间',
      width: 120,
      value: _materialTableOwningWorkshopText,
      info:
          '这个货品平时归哪个生产车间生产。最近一次排产确认或车间改派会自动记住，'
          '下次下达车间默认带出到右边的「生产车间」。',
    ),
    // ADR-102：下达车间之前就地指派本次的车间与负责人，不必再进分桶页。
    MasterColumnDef(
      key: 'productionWorkshop',
      label: _l10n.materialProductionWorkshop,
      width: 156,
      value: _materialTableProductionWorkshopText,
      cellBuilderHandlesSemantics: true,
      info:
          '本次下达车间要交给哪个车间做(不是货品平时的归属车间)。'
          '默认按这个货品上次的排产记住的车间带出，黄框提醒核对，点格子可改。'
          '只对走自制的行有意义，采购 / 委外行显示横杠。',
      cellBuilder: (_, row) => _materialTableProductionWorkshopCell(theme, row),
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
      cellBuilder: (_, row) => _materialTableResponsibleCell(theme, row),
    ),
    MasterColumnDef(
      key: 'status',
      label: _l10n.materialProgress,
      width: 230,
      info:
          '这行物料现在走到哪一步（等待下单 → 下单 → 财务审批 → 收货 → 检验 → '
          '入库)；点击状态可看全程明细。还没确认供应方式的行显示「待选供应方式」。',
      value: _materialTableStatusText,
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => _materialTableStatusCell(theme, row),
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
    // 分页补的祖先行用带页号的键；表头筛选保留的上下文行保持原 widget key。
    if (row.isPageContext) return ValueKey(row.key);
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
    return name;
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
    return UtenTreeTableCell(
      key: ValueKey('material-table-tree-${row.key}'),
      toggleKey: ValueKey('material-table-toggle-${row.key}'),
      depth: row.depth,
      // 2026-09-14 用户口径：名称前不再挂级联号，最底层不再画圆点；
      // 编号 / 颜色 / 单位已各自成列（就排在本列右边）。
      sequence: '',
      sequenceInline: true,
      showLeafMarker: false,
      // 连线要跨过宿主给每个数据格的纵向内边距，否则行与行之间空出 2×8px，
      // 整列看着像虚线（2026-09-15：这里原来没传，默认 0，与级联页观感不同的
      // 一大来源）。数值取自表格组件自己公开的常量，不在调用点抄魔数。
      guideBleed: MasterDataTableView.cellVerticalPadding,
      title: title,
      subtitle: aggregate == null
          ? null
          : _l10n.materialAggregateSources(
              aggregate.productCount,
              aggregate.paths.length,
            ),
      hasChildren: row.hasChildren,
      // 未展开时圆底右下角叠「N」徽章（当前投影可见子件数）；汇总行副标题
      // 已有「N 来源」，不再叠徽章。
      childCount: aggregate == null ? row.childCount : null,
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

  String? _materialTableRouteText(_MaterialTableRow row) => row.contextOnly
      ? '—'
      : _materialTableRoute(row)?.label ??
            (row.aggregate == null && row.group == null
                ? '—'
                : _l10n.materialMixedRoutes);

  /// 该组当前显示的路线是否只是「主档来源为空」时的硬回退（委外）：没有草稿、
  /// 没有已确认路线、没有学习记忆、主档也没给建议（服务端 REVIEW → 前端 null）。
  /// 这种行看起来像已决定，实际只是缺省值——路线格旁给黄标提示核对（F8）。
  bool _routeIsBlankSourceFallback(_MaterialGroup group) {
    final material = group.representative;
    if (material.sourceSuggestion != null ||
        material.confirmedRoute != null ||
        _routeDraft.containsKey(group.key)) {
      return false;
    }
    final product = _analysis == null
        ? null
        : _analysisIndexes(_analysis!).productsById[material.analysisLineId];
    if (material.isRootSupply &&
        product != null &&
        _hasExistingRootPlan(product)) {
      return false;
    }
    // 走到这里 = 没有草稿、没有已确认路线、主档也没给建议（服务端 REVIEW →
    // 前端 null）：显示的委外只是硬回退的缺省值，挂黄标提醒核对。
    return true;
  }

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
    final blankSourceFallback = groups.any(_routeIsBlankSourceFallback);
    // 2026-09-16 用户口径：表格内下拉统一用自家 UtenDropdownField（统一弹层/
    // 单行省略号/描边与同行格一致），不再用原生 DropdownButton。
    final dropdown = UtenDropdownField(
      key: ValueKey(
        'material-route-dropdown-${row.material?.materialLineId ?? row.key}',
      ),
      dense: true,
      value: route?.name,
      hintText: _l10n.materialMixedRoutes,
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
        unawaited(_confirmRouteChanges(groups, next));
      },
    );
    // ADR-102：还没确认路线的行把这一格框成红的。这一行的下单、追加、办理
    // 全部锁着，红框是唯一的入口提示——「先在这里选好并确认」。
    final pending = groups.any(
      (group) => group.representative.confirmedRoute == null,
    );
    final framed = pending
        ? Tooltip(
            message: '这一行还没确认供应方式，先在这里选好并确认，它才能下单。',
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
          )
        : dropdown;
    if (!blankSourceFallback) return framed;
    // 主档来源为空的行：下拉预填的「委外」只是缺省值，黄标提醒核对（F8）。
    return Row(
      children: [
        Expanded(child: framed),
        UtenFieldHintIcon(
          key: ValueKey(
            'material-route-blank-source-${row.material?.materialLineId ?? row.key}',
          ),
          autofillMessage: '主档来源为空，请核对',
        ),
      ],
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

  /// 归属生产车间列文本(V590): 货品主档 owning_workshop_department_id,
  /// 最近一次排产确认/车间改派自动学习回写; 未学习过显示「—」。
  String? _materialTableOwningWorkshopText(_MaterialTableRow row) {
    final workshop =
        row.product?.owningWorkshopName ??
        (row.aggregate?.representative ?? row.material)?.owningWorkshopName;
    return workshop == null || workshop.trim().isEmpty ? '—' : workshop.trim();
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
    final label = Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
    );
    final goodsId = _materialTableOwningWarehouseRef(row).goodsId;
    if (row.contextOnly || goodsId == null || goodsId.isEmpty) return label;
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

  /// 「需要数量」：本批要用多少。
  ///
  /// 与「还缺数量」走**同一份快照**：父行改量之后有一份服务端算好的模拟快照时，
  /// 两列都读它。少了这一句，同一行会出现「需要 1000 / 还缺 2000」这种自相
  /// 矛盾的组合——一列跟着父行变了，另一列还停在权威快照上。
  double? _materialTableRequiredQty(_MaterialTableRow row) => row.contextOnly
      ? null
      : row.material?.isRootSupply == true
      ? _tableShownQty(row.material!).required
      : row.product?.remainingQty ??
            (row.aggregate != null
                ? row.aggregate!.paths.fold<double>(
                    0,
                    (sum, material) => sum + _tableShownQty(material).required,
                  )
                : row.material == null
                ? null
                : _tableShownQty(row.material!).required);

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
          (sum, material) => sum + _tableShownQty(material).residual,
        )
      : row.material == null
      ? null
      // 与「还缺数量」「下单数量」同一份来源：父行改量之后三列必须一起变。
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

  /// 系统预填过的文本快照：轮询刷新只回填「用户没动过」的格子，
  /// 已经被人改过的一律保留，不让后台刷新吃掉手输的数。
  final Map<String, String> _tableSeededQtyTexts = {};

  /// 用户**亲手填过**的数量(键 = materialLineId)。
  ///
  /// 送给服务端重算的只能是这一份，绝不能送界面显示值：服务端那侧按
  /// 计划产出量单调向上取 max，把回显值送回去会把整棵子树钉在旧数上。
  /// 清空输入框 = 从这里移除 = 把这一行交还给系统算。
  final Map<String, double> _tableUserTypedQty = {};

  /// 父行改量之后，服务端算出的「下达之后」快照(ADR-099 回滚式预览)。
  ///
  /// **只用于展示子层数量，绝不替换权威快照 [_analysis]**：它是服务端真跑一遍
  /// 下达再整体回滚的模拟结果，版本与指纹都是模拟态。提交一律按 [_analysis] 走，
  /// 否则就是拿模拟结果当依据下单。
  ProductionMaterialAnalysisView? _tableCascadePreview;
  int _tableCascadeGeneration = 0;
  Timer? _tableCascadeDebounce;
  bool _tableCascadePreviewing = false;

  /// [_tableCascadePreview] 是按哪一份「用户亲手填的数」算出来的(键 = materialLineId)；
  /// 权威快照对应空表。当场换算下层的**分母**必须按它算：那份快照里子层的数字是
  /// 按这些数展开的，不是按此刻框里的数——服务端那趟在路上时用户又改了数，
  /// 回来以后也要拿它把这期间多改的那部分就地补算，屏幕才不会先跳回旧数字。
  Map<String, double> _tableCascadePreviewTyped = const {};

  /// 父行刚改完、服务端那份重算还在路上时，页面**当场**按比例换算出来的子层数字
  /// (键 = materialLineId)。用户口径 2026-09-21「输入框输入的时候子层级就要变，
  /// 不是等到确认后」——那趟回滚式预览在服务端是真跑一遍下达再回滚，实测 1.4 到
  /// 7 秒，光等它主表上就是「改了没反应」。只覆盖展示与预填，提交仍按权威快照。
  final Map<String, _TableQty> _tableEstimatedQty = {};

  /// 「敲一下当场变」只通知**依赖估算值的那几个格子**自己重建(需要数量 / 还缺数量 /
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
    _tableCascadeDebounce?.cancel();
    _tableCascadeDebounce = null;
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
    _tableSeededQtyTexts.clear();
    _tableUserTypedQty.clear();
    _tableAutoSelectedKeys.clear();
    _tableUserDeselectedKeys.clear();
    _tableCascadePreview = null;
    _tableCascadePreviewTyped = const {};
    _tableEstimatedQty.clear();
    _tableCascadeGeneration++;
    _tableWorkshopDraft.clear();
    _tableWorkerDraft.clear();
    _tableTransferableIn = const {};
    _tableTransferableInScope = null;
    _tableAssignmentScope = null;
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
  /// 对已确认采购或直接外发委外的顶层行**会显示真实数字** —— 于是同一行左边看得见
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

  /// 还缺数量(ADR-102 口径，服务端权威派生)：已把「下达时真会自动认领的
  /// 公共在途」当成已占用扣掉。客户端只做跨路径求和，不做任何缺口减在途的算术
  /// (ADR-099 不变量 2)。
  ///
  /// 2026-09-22：顶层放开办理后，这一列与办理/下单两列收口到同一条判据 ——
  /// 有根供给组的产品行照常显示它自己的缺口，没有的才是横杠。原来只对
  /// 「已确认非自制路线」的顶层行显示，顶层自制明明也能下达车间却看不到缺口。
  double? _materialTableNetShortageQty(_MaterialTableRow row) => row.contextOnly
      ? null
      : row.product != null && row.group == null
      ? null
      : row.aggregate != null
      ? row.aggregate!.paths.fold<double>(
          0,
          (sum, material) => sum + _tableShownQty(material).net,
        )
      : row.material == null
      ? null
      : _tableShownQty(row.material!).net;

  /// 本提交单元累计已下单量。
  ///
  /// 三条来源不是随便选的：顶层自制行的计划挂在产品行自己身上(它本身就是排产对象，
  /// 没有锚点——2026-09-23 前这里漏了它：顶层下了 2000 的计划，主表照旧给它一个可填
  /// 的「下单数量」，再全选下单就把它当新计划重下，服务端 409 整批停在第一步)；
  /// 其余已建自制锚点的行，真实已下达量在锚点产品的计划总量上(含公共备货产出)；
  /// 采购 / 直接外发委外的行在申请明细上 = 归本需求的分摊量 + 同一条行动记的
  /// 公共备货份。一行只可能是其中一种，不会同时成立。
  double _tableGroupIssuedQty(_MaterialGroup group) {
    final route = _draftRoute(group);
    // 走车间通道的行(自制、要先自制目标件的委外)按锚点产品的计划总量：要先自制的委外
    // 建过前置自制任务(SUBCONTRACT_MAKE 锚点)后, 它「已下达」的是那张计划, 不是后面
    // 发外的委外申请——按申请明细算会把计划多下的那部分(3000 需求下了 4000)看丢,
    // 父件一追加就把它算成还缺、再送一段 ARRANGE 吃 409(2026-09-22 用户实机
    // 「有些子层级之前一次多下了, 这次就是不需要下」)。没建过锚点的委外照旧按申请明细。
    if (_tableUsesMakeAnchor(group)) {
      final anchor = _tableMakeAnchorOf(group);
      if (anchor != null) {
        return anchor.issuedPlanQty * _tableAnchorUnitRate(group, anchor);
      }
      if (route == MaterialSupplyRoute.make) return 0;
    }
    var ordered = 0.0;
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
        final allocated = target.allocatedQty ?? 0;
        ordered += allocated;
        // 填得比当时需求多的部分，服务端记在同一条行动的公共备货份上(V577/V589)，
        // 申请明细上就是两者的合计。它同样是这一行下出去的单——不算的话，填 5000
        // 下成「需求 2000 + 公共 3000」的行会显示成「累计已下单 2000」，用户实机
        // 看到的就是「我填了 5000 怎么只下了 2000」(2026-09-23)。
        // 一条行动可能分摊到多条物料行(各一条 allocation)，公共份按本行分摊量占行动
        // 需求份的比例摊，几条行加起来正好是整条行动的公共份，不会每行都算一遍。
        final action = _supplyActionOf(target.actionId);
        if (action != null && action.publicSurplusQty > 0) {
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
  ) => group.representative.isRootSupply ? (anchor.unitRate ?? 1) : 1;

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
    final anchorId = material.isRootSupply
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

  /// 已下过单的车间通道行(自制含顶层、要先自制目标件的委外)的锚点产品；不是这类行
  /// 返回 null。
  ProductionMaterialAnalysisProduct? _tableIssuedMakeAnchorOf(
    _MaterialGroup group, {
    bool authoritative = false,
  }) {
    if (!_tableUsesMakeAnchor(group)) return null;
    final anchor = _tableMakeAnchorOf(group, authoritative: authoritative);
    return anchor != null && anchor.issuedPlanQty > 0.0001 ? anchor : null;
  }

  /// 这一行的「已下达 / 还需安排 / 能不能再追加」是不是按计划锚点判：自制行与要先自制
  /// 目标件的委外行(它们的下达都是 issue-plans 出计划, 锚点产品才是事实源)。与级联页
  /// `preparationAnchor` 同一口径。
  bool _tableUsesMakeAnchor(_MaterialGroup group) =>
      _draftRoute(group) == MaterialSupplyRoute.make ||
      _tableSubcontractNeedsPreparation(group);

  /// 这一行下过单没有(下过 = 下单数量列锁死、改填追加下单列)。
  bool _tableGroupIssued(_MaterialGroup group) =>
      _tableGroupIssuedQty(group) > 0.0001;

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

  /// 这一类行必须整批接管：要先自制目标件的委外。
  ///
  /// **2026-09-22 修订：自制行不再算在内。** 原来的理由是「服务端要求下单量逐字等于
  /// 全部剩余需求，既不能超也不能少」，而那条校验(`createsChildOwnership`)长在
  /// `MaterialAnalysisCommandService.notifySupply` 里 —— 自制行在同一个方法更靠前的
  /// 地方就被另一道闸拦掉了(「自制路线请直接『创建生产计划』下达车间，不再单独创建
  /// 子件任务」)，**根本走不到那条数量校验**。自制行实际走的是 `issue-plans`，而那条路
  /// 明确接受任意数量：`demandQty = line.qty().min(remainingQty)`，超出部分按 V577 记进
  /// `public_surplus_qty`，连超量权限都不要。兄弟页面早就是这个口径 ——「下达车间」
  /// 分桶页写着「任何行都可填超量」，「父件 + 下层一起下单」页把用户填的数原样送进
  /// issue-plans。所以锁死自制行是引错了对象的历史惯性，不是技术约束。
  ///
  /// 委外那一支只剩一种情况：**没有「下达车间」权限**时它落回 `notifySupply` 的整量
  /// 接管。有权限的走 issue-plans 的 ARRANGE 段(与委外桶 / 级联页 `_subcontractChannelOf`
  /// 同一口径, 2026-09-16 起)，那条路数量可改可超——2026-09-22 用户实机：把一行改成委外
  /// 后「下单数量就定死了不能修改, 我都没有下单过」，正是这里没看权限一律锁死。
  bool _tableGroupWholeTakeover(_MaterialGroup group) =>
      _tableSubcontractNeedsPreparation(group) && !_canGenerate;

  /// 委外行是不是「要先自制目标件再发外」的那种(有生产性下层, 且不是 V581 单一
  /// 子件件)。快照还没到手时按「要」处理：格子只读比让人填个数再吃 400 好。
  bool _tableSubcontractNeedsPreparation(_MaterialGroup group) {
    if (_draftRoute(group) != MaterialSupplyRoute.subcontract) return false;
    final analysis = _analysis;
    if (analysis == null) return true;
    return _subcontractNeedsPreparation(group.representative, analysis);
  }

  /// 顶层自制行要走的「产品行排产」通道的 analysisLineId；不是这类行就返回 null。
  ///
  /// 服务端 `candidateRoutesByMaterialLine` 的过滤是
  /// `!"ROOT_SUPPLY".equals(nodeRole) || "SUBCONTRACT".equals(sourceConfirmed)` ——
  /// 顶层自制既不是候选、也不该走 notify(自制路线在 notifySupply 开头就被拒),
  /// 它本身就是排产对象, 要按产品的 analysisLineId 送进 issue-plans 的 planDrafts。
  /// 顶层委外则**是**候选(ADR-099 放开), 照常走 materialLineId 那条。
  String? _tableRootMakePlanLineId(_MaterialGroup group) {
    final material = group.representative;
    if (!material.isRootSupply) return null;
    if (_draftRoute(group) != MaterialSupplyRoute.make) return null;
    return material.analysisLineId;
  }

  /// 自制行这次填的数比本行「还需安排」少多少；不少就返回 null。
  ///
  /// **只提示，不拦提交。** 填少了并不会丢东西：没下的那部分仍旧留在这一行的
  /// 「还需安排」里，下一轮接着下，分批下达本来就是合法用法。真正「不能少」的是
  /// 「父件 + 下层一起下单」那个页面 —— 那里是同一次提交里子件必须盖住父件本批，
  /// 与主表逐行下单不是一回事，别把那条下限照搬过来把分批堵死。
  double? _tableBelowMinimumBy(_MaterialGroup group) {
    if (_draftRoute(group) != MaterialSupplyRoute.make) return null;
    if (_tableGroupIssued(group)) return null;
    final text = _tableOrderQtyControllers[group.key]?.text;
    if (text == null || text.trim().isEmpty) return null;
    final typed = double.tryParse(text.trim());
    if (typed == null) return null;
    final floor = _tableGroupResidual(group);
    final gap = floor - typed;
    return gap > 0.0001 ? gap : null;
  }

  TextEditingController _tableOrderQtyController(_MaterialGroup group) {
    final seeded = _qty(_tableGroupResidual(group));
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
        final seeded = _qty(_tableGroupResidual(group));
        _tableSeededQtyTexts['APPEND|${group.key}'] = seeded;
        return TextEditingController(text: seeded);
      });

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
    for (final group in _analysisIndexes(analysis).groupsByKey.values) {
      for (final append in const [false, true]) {
        final value = _reseedTableQtyCell(group, append: append);
        if (value == null || !autoSelect) continue;
        // 这一格的数是不是父行改量带出来的：与**权威快照**的还需安排不同才算。
        // 按快照本来就预填着数、没被改量碰到的行不能因为别处改了一个父件就被
        // 勾上；父行清空、数回落到快照值的行，替他勾的那个勾也要撤掉。
        final baseline = _tableGroupResidual(group, authoritative: true);
        final driven = (value - baseline).abs() > 0.0001;
        if (_autoSelectTableGroup(group, select: driven && value > 0.0001)) {
          selectionChanged = true;
        }
      }
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
  /// 它冲掉。宿主页的 _refreshSystemSeededPlanBatchQty 早就是 remove 这个写法，
  /// 这里漏了。2026-09-22 对抗复查抓出来的真缺陷。
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
    final value = _tableGroupResidual(group);
    final next = _qty(value);
    // 没变就不写：每次赋值都会通知那个 TextField 重建，一屏几十个格子白跑。
    if (controller.text != next) controller.text = next;
    _tableSeededQtyTexts[seededKey] = next;
    return value;
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
      return true;
    }
    if (!_tableAutoSelectedKeys.remove(key)) return false;
    return _selectedMaterialGroupKeys.remove(key);
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

  /// 随估算值当场变的只读数字格：只订阅 [_tableEstimateTick]，父行敲一下这一格
  /// 自己重建，整页不动。
  Widget _materialTableLiveQtyCell(double? Function() value) =>
      ValueListenableBuilder<int>(
        valueListenable: _tableEstimateTick,
        builder: (_, _, _) =>
            Text(_qty(value()), maxLines: 1, overflow: TextOverflow.ellipsis),
      );

  /// 「下单数量」格此刻是不是填错了 / 填少了(用户口径 2026-09-22「数量填的不对的
  /// 或者缺的都要输入框冒红……父类下了 1000，子类需要 1000，输入小于 1000 就冒红，
  /// 一输入就冒红直到输入正确」)：空 / 不是数 / 不大于 0 / 小于这一行此刻的
  /// 「还需安排」。还需安排随父行的估算当场变，所以红框同时订阅估算 tick。
  bool _tableOrderQtyInvalid(_MaterialGroup group) {
    final text = _tableOrderQtyControllers[group.key]?.text.trim() ?? '';
    final typed = double.tryParse(text);
    if (text.isEmpty || typed == null || !typed.isFinite || typed <= 0) {
      return true;
    }
    return typed + 0.0001 < _tableGroupResidual(group);
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

  /// 权威快照一到就让父子联动的模拟快照作废(ADR-102)。
  ///
  /// 回滚式预览是「下达之后会变成什么样」的模拟，它没有版本与指纹，永远比
  /// 权威快照旧。不清它的话：轮询/409 恢复/下达成功换上新快照之后，
  /// 「还缺数量」列与下单数量预填仍旧来自下达前那次模拟——同事的到货入库已经
  /// 把某行缺口清零，主表还照着模拟值预填并让人下单，就是凭空多买一批。
  /// 2026-09-22 对抗复查抓出来的真缺陷。
  @override
  void _invalidateMaterialTableCascadePreview() {
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
    if (_tableUserTypedQty.isNotEmpty && !_tableSubmitting) {
      _tableCascadeDebounce?.cancel();
      _tableCascadeDebounce = Timer(
        const Duration(milliseconds: 300),
        () => unawaited(_refreshTableCascadePreview()),
      );
    }
  }

  /// 主表「下单(N)」的分段编排正在进行：期间不自动发层级预览。
  bool _tableSubmitting = false;

  // ---------------- 父行改量带动子层(ADR-099 回滚式预览) ----------------

  /// 这一行在树上还有没有下层：只有带下层的行改量才值得惊动服务端重算。
  ///
  /// 按**表上画出来的那棵树**判(`_bomPresentation` 的父子链)，不按 `parentNodeKey`
  /// 原始桶：顶层产品行的第 1 层子件 `parentNodeKey` 是空的，按原始桶查顶层
  /// 永远「没有下层」——在顶层产品行改数既不当场换算、也不问服务端，正是用户
  /// 2026-09-22 实机看到的「主表改数值没反应」。前置自制接管的分支同理。
  bool _tableGroupHasChildren(_MaterialGroup group) {
    final analysis = _analysis;
    if (analysis == null) return false;
    final parents = _bomPresentation(analysis).parentIdsByMaterial;
    final ids = {for (final path in group.paths) path.materialLineId};
    return parents.values.any(ids.contains);
  }

  /// 用户在某一行填了数：记下**他亲手填的值**，并安排一次服务端重算。
  ///
  /// 去抖是页面级单例(不是每行一个 Timer)：整张表铺开输入框之后，每行一个
  /// 定时器会把回滚式预览的请求量放大到不可接受——那个端点在服务端是真跑一遍
  /// 下达再整体回滚。
  void _onTableQtyTyped(_MaterialGroup group, String text) =>
      _recordTableTypedQty(group, orderText: text);

  /// 追加格填的数：与下单格是**同一个提交单元**的两半，合起来才是「这一行这批
  /// 要产出多少」，所以两格都往同一个键上写合计值，不各写各的。
  void _onTableAppendQtyTyped(_MaterialGroup group, String text) =>
      _recordTableTypedQty(group, appendText: text);

  /// 记下用户**亲手填的值**，并安排一次服务端重算。
  ///
  /// 两格只要有一格填了数，这一行就算「用户亲手决定过」；两格都空 = 把这一行
  /// 交还给系统算(手滑敲一下再删掉能复位，不会永久脱离跟随)。
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

    final order =
        parse(orderText) ??
        (orderText != null
            ? null
            : parse(_tableOrderQtyControllers[group.key]?.text));
    final append =
        parse(appendText) ??
        (appendText != null
            ? null
            : parse(_tableAppendQtyControllers[group.key]?.text));
    final total = (order ?? 0) + (append ?? 0);
    if (total <= 0) {
      // 两格都空 = 把这一行交还给系统算，不是「填了 0」。
      _tableUserTypedQty.remove(lineId);
    } else {
      _tableUserTypedQty[lineId] = total;
    }
    // 亲手填了数的行就是要下的行：有数就替他勾上(亲手填数比之前撤过的勾更新，
    // 所以先把「撤过勾」的记号抹掉)，清成空 / 0 就把替他勾的那个勾撤掉。
    if (total > 0) _tableUserDeselectedKeys.remove(group.key);
    final selectionChanged = _autoSelectTableGroup(group, select: total > 0);
    if (!_tableGroupHasChildren(group)) {
      if (selectionChanged) _scheduleTableEstimateRebuild();
      return;
    }
    // 敲一下当场变：先按比例把它下面每一层换算好并回填预填值(有数的子行顺手
    // 勾上)，再去抖要服务端那份权威重算。叶子行改量到不了这里。
    _recomputeTableEstimates();
    _reseedTableQtyInputs(autoSelect: true);
    // 不整页 setState：只让订阅了 tick 的格子(需要数量 / 还缺数量 / 红框)重建，
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
  /// 客户端一行算术都不做：子层该变成多少由服务端按计划产出量展开
  /// (ADR-099 不变量——客户端没有任何缺口减在途的回退)。代价是有一次
  /// 往返延迟，换来的是主表不会把父子联动的算术重实现一遍再踩一遍坑。
  Future<void> _refreshTableCascadePreview() async {
    final analysis = _analysis;
    final warehouseId = _warehouseId;
    if (analysis == null || warehouseId == null || !mounted) return;
    // 代际先推：用户把输入清空时也要占一个代际，否则上一次在途的预览回来时
    // `generation != _tableCascadeGeneration` 判定为假，那份**已被撤销的输入**
    // 派生出来的模拟快照会照样装上去，之后全表的数字与预填都来自它。
    final generation = ++_tableCascadeGeneration;
    if (_tableUserTypedQty.isEmpty) {
      if (_tableCascadePreview == null && _tableEstimatedQty.isEmpty) return;
      setState(() {
        _tableCascadePreview = null;
        _tableCascadePreviewTyped = const {};
        _recomputeTableEstimates();
      });
      _reseedTableQtyInputs(autoSelect: true);
      return;
    }
    // 记下这一趟是按哪份填数要的：回来时它就是新的换算分母。
    final typedSent = Map<String, double>.unmodifiable(_tableUserTypedQty);
    setState(() => _tableCascadePreviewing = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .previewIssuePlans(
            analysis: analysis,
            warehouseId: warehouseId,
            // 幂等键必须每次都新：这是一次纯重算，不是要复用上一次的结果。
            idempotencyKey: businessIdempotencyKey(
              'material-analysis-table-cascade-preview',
              [
                analysis.analysisId,
                analysis.version,
                analysis.fingerprint,
                generation,
                for (final entry in _tableUserTypedQty.entries)
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
      if (!mounted || generation != _tableCascadeGeneration) return;
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
      if (!mounted || generation != _tableCascadeGeneration) return;
      setState(() {
        _tableCascadePreview = null;
        _tableCascadePreviewTyped = const {};
        _recomputeTableEstimates();
      });
      _reseedTableQtyInputs(autoSelect: true);
    } finally {
      if (mounted && generation == _tableCascadeGeneration) {
        setState(() => _tableCascadePreviewing = false);
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
    for (final candidate in preview.materials) {
      if (candidate.materialLineId == material.materialLineId) return candidate;
    }
    return material;
  }

  /// 服务端那份快照(模拟优先、否则权威)给这一行的三个数——当场换算的**分母**。
  _TableQty _tablePreviewedQty(
    ProductionMaterialAnalysisMaterial material, {
    bool authoritative = false,
  }) {
    final shown = _tablePreviewed(material, authoritative: authoritative);
    return (
      required: shown.requiredQty,
      residual:
          _tableAnchorResidual(material, authoritative: authoritative) ??
          shown.additionalSupplyRecommendedQty,
      net: shown.netShortageQty,
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
  /// 「需要数量」「还缺数量」「下单数量」三列都从这里读，父行改量之后一起变。
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
    _tableEstimatedQty.clear();
    final analysis = _analysis;
    if (analysis == null) return;
    final changed = <String>{
      for (final entry in _tableUserTypedQty.entries)
        if (_tableCascadePreviewTyped[entry.key] != entry.value) entry.key,
      for (final key in _tableCascadePreviewTyped.keys)
        if (!_tableUserTypedQty.containsKey(key)) key,
    };
    if (changed.isEmpty) return;
    final presentation = _bomPresentation(analysis);
    final roots = <String?>{
      for (final key in changed) presentation.rootIdsByMaterial[key],
    };
    for (final rootId in roots) {
      _estimateTableTree(analysis, presentation, rootId);
    }
  }

  /// 把 [rootId] 这一棵树未经投影的全量前序(折叠、表头筛选、分页都不影响它)
  /// 交给共用件换算：屏幕上相邻不等于树上父子，比例只能沿真实父子链传。
  void _estimateTableTree(
    ProductionMaterialAnalysisView analysis,
    _BomPresentation presentation,
    String? rootId,
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
          typed: _tableUserTypedQty[root.materialLineId],
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
        userTyped: _tableUserTypedQty[material.materialLineId],
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
    if (material.isRootSupply) {
      final planned = committedOutput + (typed ?? 0);
      return planned > server.required ? planned : server.required;
    }
    return cascadePlannedOutput(
      committedOutput: committedOutput,
      server: server,
      userTyped: typed,
    );
  }

  /// 本行此刻可以从别的计划锁定量里调进来多少(0 = 调拨按钮置灰)。
  double _tableTransferableInQty(_MaterialGroup group) {
    if (_tableTransferableIn.isEmpty) return 0;
    var total = 0.0;
    for (final path in group.paths) {
      total += _tableTransferableIn[path.materialLineId] ?? 0;
    }
    return total;
  }

  /// 按需取一次批量可调拨量。带会话作用域键：切账号后丢弃迟到响应，
  /// 免得把上一个账号可见范围里的量显示给下一个账号。
  Future<void> _loadTableTransferableIn(
    ProductionMaterialAnalysisView analysis,
  ) async {
    if (!_canCrossReallocate || _tableTransferableInLoading) return;
    final sessionKey = _sessionScopeKey();
    final scope = '$sessionKey#${analysis.analysisId}';
    if (_tableTransferableInScope == scope) return;
    _tableTransferableInLoading = true;
    try {
      final summary = await ref
          .read(productionPlanRepositoryProvider)
          .materialTransferableInSummary(analysis.analysisId);
      // 切账号后到货的响应直接丢弃：可调拨量随登录人的对象级可见范围变，
      // 把上一个账号看得见的量显示给下一个账号是越权泄露。
      // 会话键**先存下来再比**，不要从拼接串里拆——会话键自身含 '|'。
      if (!mounted || _sessionScopeKey() != sessionKey) return;
      setState(() {
        _tableTransferableIn = summary;
        _tableTransferableInScope = scope;
      });
    } catch (_) {
      // 调拨按钮灰不灰是辅助信息，取不到就一律按「无可调拨」置灰，不打断主表。
      if (!mounted) return;
      setState(() {
        _tableTransferableIn = const {};
        _tableTransferableInScope = scope;
      });
    } finally {
      _tableTransferableInLoading = false;
    }
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

  Future<void> _loadTableAssignmentDefaults(
    ProductionMaterialAnalysisView analysis,
  ) async {
    if (!_canGenerate || _tableAssignmentLoading) return;
    final scope = '${_sessionScopeKey()}|${analysis.analysisId}';
    if (_tableAssignmentScope == scope) return;
    final goodsIds = <String>{
      for (final material in analysis.materials)
        if (material.goodsId?.isNotEmpty == true) material.goodsId!,
    };
    if (goodsIds.isEmpty) return;
    _tableAssignmentLoading = true;
    try {
      final tree = await _tableWorkshopTreeOrEmpty();
      final defaults = await ref
          .read(productionPlanRepositoryProvider)
          .defaultWorkshops(goodsIds);
      if (!mounted) return;
      setState(() {
        _tableWorkshopTree = tree;
        _tableWorkshopDefaults = defaults;
        _tableWorkshopManagers = {
          for (final node in tree)
            if (node.managerId?.isNotEmpty == true)
              node.id: (id: node.managerId, name: node.managerName),
        };
        _tableAssignmentScope = scope;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _tableAssignmentScope = scope);
    } finally {
      _tableAssignmentLoading = false;
    }
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

  /// 本行此刻的生产车间：手选草稿 > 货品学习记忆 > 主档归属车间。
  ({String? id, String? name, bool autofilled}) _tableWorkshopFor(
    _MaterialGroup group,
  ) {
    final draft = _tableWorkshopDraft[group.key];
    if (draft != null) {
      return (id: draft.id, name: draft.name, autofilled: false);
    }
    final goodsId = group.representative.goodsId;
    final learned = goodsId == null ? null : _tableWorkshopDefaults[goodsId];
    if (learned != null) {
      return (
        id: learned.departmentId,
        name: learned.departmentName,
        autofilled: true,
      );
    }
    final material = group.representative;
    if (material.owningWorkshopId?.isNotEmpty == true) {
      return (
        id: material.owningWorkshopId,
        name: material.owningWorkshopName,
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
    if (selection == null || !mounted) return;
    setState(() {
      _tableWorkshopDraft[group.key] = (id: selection.id, name: selection.name);
      // 换车间必须把负责人草稿清掉：留着上一个车间的人是最容易漏掉的错派。
      _tableWorkerDraft.remove(group.key);
    });
  }

  Future<void> _pickTableWorker(_MaterialGroup group) async {
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
            .list(
              size: 30,
              search: keyword,
              departmentId: (keyword?.trim().isEmpty ?? true)
                  ? workshop.id
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
      _tableWorkerDraft[group.key] = (id: picked.id, name: picked.name);
    });
  }

  // ------------------------- 物料办理列 -------------------------

  /// 这一行的下达去向。与「父件 + 下层一起下单」页的分通道判定同源：
  /// 自制、以及要先自制目标件的委外(有「下达车间」权限时)都走车间；其余委外与采购
  /// 走外发通道——没有权限的「要先自制」委外退回 notify 整批接管。
  ({String label, bool viaWorkshop}) _tableIssueTarget(_MaterialGroup group) {
    final route = _draftRoute(group);
    if (route == MaterialSupplyRoute.make) {
      return (label: '下达车间', viaWorkshop: true);
    }
    if (route == MaterialSupplyRoute.subcontract) {
      return _tableSubcontractNeedsPreparation(group) && _canGenerate
          ? (label: '下达车间', viaWorkshop: true)
          : (label: '下达委外', viaWorkshop: false);
    }
    return (label: '下达采购', viaWorkshop: false);
  }

  /// 主表里还有用户手填未提交的数量，或还勾着待下单的行。
  @override
  bool get _hasUnsubmittedMaterialTableInput =>
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

  /// 这一行现在能不能下达；不能时给出**人话**原因(缺权限要说清缺哪一个)。
  @override
  String? _tableIssueBlockedReason(_MaterialGroup group) {
    if (group.representative.confirmedRoute == null) {
      return '这一行还没确认供应方式，先在「供应方式」列里选好并确认';
    }
    // 路线草稿保存失败时 _routeDraft/_dirtyRouteGroups 会留在页面上，此时
    // _draftRoute 给的是还没落盘的路线：照它选下达通道会直接吃服务端 400，
    // 而且 _notifyRoute 只要页面上还有任一脏组就整段拒绝。所有旧入口都把脏组
    // 当「路线待确认」，主表这个新口子不能漏。
    if (_dirtyRouteGroups.contains(group.key)) {
      return '这一行的供应方式还没保存成功，请先确认路线';
    }
    final planningBlock = _planningBlockForGroup(group);
    if (planningBlock != null) return planningBlock;
    // 已排满又不能再追加公共备货产出的自制行(含顶层产品行)：服务端 issue-plans 对
    // 「剩余需求 0 且没声明纯公共备货」一律 409「当前分析需求已全部转入生产计划」。
    final issuedAnchor = _tableIssuedMakeAnchorOf(group);
    if (issuedAnchor != null &&
        !issuedAnchor.canSchedule &&
        !issuedAnchor.canIssueSurplus) {
      return '这一行的生产计划已排满，当前不能再追加公共备货产出';
    }
    // 已建前置自制任务的委外行只能经 ARRANGE 段追加(notify 整批接管会再建一次子件
    // 任务)：没有「下达车间」权限就不能在这里追加。
    if (issuedAnchor != null &&
        _draftRoute(group) == MaterialSupplyRoute.subcontract &&
        !_canGenerate) {
      return '这一行已建前置自制任务，再追加要「下达车间」权限，请找管理员开通';
    }
    // 服务端会拒的形态在这里就拦掉，别让人勾了、填了数、点了下达才吃 400。
    // 判据复用既有权威谓词的同名分支，不另造一套。
    final route = _draftRoute(group);
    if (_routeBlockedBySafetyGap(group, route)) {
      return '本版本仅采购路线支持公共安全补库，请改用采购路线下达';
    }
    if (!group.paths.every(_hasResolvedMaterialSource)) {
      return '这一行的物料来源解析不出来，请刷新分析后核对';
    }
    final target = _tableIssueTarget(group);
    if (target.viaWorkshop && !_canGenerate) {
      return '你没有「下达车间」的权限，请找管理员开通';
    }
    if (!target.viaWorkshop && !_canNotify) {
      return '你没有「下达采购 / 委外」的权限，请找管理员开通';
    }
    if (target.viaWorkshop) {
      // 生产车间 / 负责人跟路线走(用户口径 2026-09-22「变成采购、委外就不需要生产
      // 车间了」)：只有自制行在主表上要求指派；要先自制目标件的委外走 ARRANGE 段时
      // 车间按学习默认带给服务端, 没有就由服务端按排产方案落车间, 不在这里拦。
      if (route == MaterialSupplyRoute.make) {
        final workshop = _tableWorkshopFor(group);
        if (workshop.id == null) return '先在「生产车间」列里指定本次交给哪个车间';
        if (_tableWorkerFor(group).id == null) {
          return '先在「负责人」列里指定本次谁负责';
        }
      }
    } else if (!_isExecutableSupplyGroup(
      group,
      route,
      allowExtra: _canOverSupply,
    )) {
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
    final group = _tableEditableGroup(row);
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
    final gross = _materialTableAdditionalRecommendedQty(row) ?? net ?? 0;
    final claimed = (gross - (net ?? gross)).clamp(0.0, gross);
    final late = row.aggregate != null
        ? row.aggregate!.paths.fold<double>(
            0,
            (sum, item) => sum + item.lateSharedFutureAvailableQty,
          )
        : row.material?.lateSharedFutureAvailableQty ?? 0;
    // 退役的「可用数量 / 在途未到 / 公共认领未实收」三列并进这段说明：
    // 它们本来就是「还缺多少」的分解项，分成三列反而要人自己做减法。
    final available = _materialTableAvailableQty(row);
    final inbound = _materialTableInboundQty(row);
    final physical = _materialTableShortageQty(row);
    // 顶层自制产品行没有「还要另外下多少」这个数(它的补货走下达车间)，
    // 但仓库可用与在途这些事实照样要有落点——格子显示横杠，说明照给。
    final buffer = StringBuffer(
      net == null
          ? '这一行的补货走「下达车间」，没有单独的下单缺口。'
          : '扣掉公共的量之后，这一行还要另外下 ${_qty(net)}。',
    );
    if (available != null && available > 0) {
      buffer.write('\n仓库现在可用 ${_qty(available)}。');
    }
    if (inbound != null && inbound > 0) {
      buffer.write('\n已安排但还没合格入库 ${_qty(inbound)}。');
    }
    if (claimed > 0) {
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
              _qty(net),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _shortageTextColor(theme, net),
                fontWeight: FontWeight.w800,
              ),
            ),
    );
  }

  // ------------------------- 下单数量 / 追加下单 -------------------------

  String? _materialTableOrderQtyText(_MaterialTableRow row) {
    final group = _tableEditableGroup(row);
    if (group == null) return '—';
    if (_tableGroupIssued(group)) return _qty(_tableGroupIssuedQty(group));
    return _tableOrderQtyControllers[group.key]?.text ??
        _qty(_tableGroupResidual(group));
  }

  Widget _materialTableOrderQtyCell(ThemeData theme, _MaterialTableRow row) {
    final group = _tableEditableGroup(row);
    if (group == null) return const Text('—');
    // 已下达：这一格锁住并改成显示累计已下单量，本次要再下就填右边的追加。
    if (_tableGroupIssued(group)) {
      return Tooltip(
        message:
            '累计已下单 ${_qty(_tableGroupIssuedQty(group))}。'
            '下达之后这一格不可改，要再下请填右边的「追加下单」。',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s4),
            Text(
              _qty(_tableGroupIssuedQty(group)),
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    // 整批接管的行(要先自制目标件的委外、且没有「下达车间」权限)：它落回
    // notifySupply，那条路要求逐字等于剩余需求，给输入框只会让人填完吃 400，
    // 所以直接只读并说明原因。有权限的走 ARRANGE 段，数量照常可填。
    if (_tableGroupWholeTakeover(group)) {
      return Tooltip(
        message:
            '这类行要先自制目标件再发外；你没有「下达车间」权限，只能整批接管 '
            '${_qty(_tableGroupResidual(group))}，不能多填也不能少填。'
            '本批实际生产数量在子件任务建好后的计划里填。',
        child: Text(
          _qty(_tableGroupResidual(group)),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (group.representative.confirmedRoute == null) {
      return Tooltip(
        message: '先确认供应方式，这一行才能填下单数量。',
        child: Text('—', style: theme.textTheme.bodySmall),
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
        '本次只下 ${_qty(_tableGroupResidual(group) - shortBy)}，'
            '比这一行的「还需安排」${_qty(_tableGroupResidual(group))} 少 ${_qty(shortBy)}。'
            '没下的部分仍留在这一行，下一轮可以接着下。',
      if (blocked != null) '这一行本次下不了单：$blocked',
      if (blocked == null && shortBy == null)
        '填多少下多少。填得比需求多的部分按公共备货产出记账，下层物料需求不会自动变大。',
    ].join('\n');
    return Tooltip(message: hint, child: field);
  }

  String? _materialTableAppendQtyText(_MaterialTableRow row) {
    final group = _tableEditableGroup(row);
    if (group == null || !_tableGroupIssued(group)) return '—';
    return _tableAppendQtyControllers[group.key]?.text ?? '0';
  }

  Widget _materialTableAppendQtyCell(ThemeData theme, _MaterialTableRow row) {
    final group = _tableEditableGroup(row);
    if (group == null) return const Text('—');
    // 整批接管的行(需先自制目标件的委外)提交量恒等于剩余需求，这一格填了也不会
    // 被读走——所以不给输入框，直接说清追加走哪条路。
    // 2026-09-22 对抗复查：原先这一格对已下达的自制行是可编辑的，用户填的数
    // 被 _tableSubmitQtyOf 的整批接管分支整个丢弃，还弹「请先填数」。
    // 同日自制行已从整批接管里摘出去，这一格对自制行重新可填(走 publicSurplusOnly)。
    if (_tableGroupWholeTakeover(group)) {
      return Tooltip(
        message:
            '这一行没有「下达车间」权限时按整批接管提交，追加产出请在「下达车间」'
            '建好的计划里填，不在这里。',
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
  }) => RequiredCellFrame(
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
      onSubmitted: (_) => setState(() {}),
    ),
  );

  // ------------------------- 生产车间 / 负责人 -------------------------

  /// 「生产车间 / 负责人」两列跟**路线**走(用户口径 2026-09-22「路线改变后对应的
  /// 生产车间、负责人就要清空, 除非变回原来的路线——变成采购、委外就不需要生产车间
  /// 了」)：只有自制行显示并要求指派, 采购 / 委外一律横杠。草稿按提交单元记着不删,
  /// 改回自制那一刻原来选的车间 / 负责人就回来。要先自制目标件的委外走 ARRANGE 段时,
  /// 车间由学习默认 / 服务端排产方案兜底, 不在主表上露出来。
  bool _tableAssignable(_MaterialGroup? group) =>
      group != null && _draftRoute(group) == MaterialSupplyRoute.make;

  String? _materialTableProductionWorkshopText(_MaterialTableRow row) {
    final group = _tableEditableGroup(row);
    if (!_tableAssignable(group)) return '—';
    return _tableWorkshopFor(group!).name ?? '待指派';
  }

  Widget _materialTableProductionWorkshopCell(
    ThemeData theme,
    _MaterialTableRow row,
  ) {
    final group = _tableEditableGroup(row);
    if (!_tableAssignable(group)) return const Text('—');
    final current = _tableWorkshopFor(group!);
    return _materialTableAssignmentCell(
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
  }

  String? _materialTableResponsibleText(_MaterialTableRow row) {
    final group = _tableEditableGroup(row);
    if (!_tableAssignable(group)) return '—';
    return _tableWorkerFor(group!).name ?? '待指派';
  }

  Widget _materialTableResponsibleCell(ThemeData theme, _MaterialTableRow row) {
    final group = _tableEditableGroup(row);
    if (!_tableAssignable(group)) return const Text('—');
    final current = _tableWorkerFor(group!);
    return _materialTableAssignmentCell(
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
  double _tableSubmitQtyOf(_MaterialGroup group) {
    if (_tableGroupWholeTakeover(group)) return _tableGroupResidual(group);
    final controller = _tableGroupIssued(group)
        ? _tableAppendQtyControllers[group.key]
        : _tableOrderQtyControllers[group.key];
    final text = controller?.text.trim() ?? '';
    if (text.isEmpty) {
      // 没建过控制器 = 用户没看过这一行，按系统预填值走；追加默认 0。
      return _tableGroupIssued(group) ? 0 : _tableGroupResidual(group);
    }
    return double.tryParse(text) ?? 0;
  }

  /// 主表直接下达：把选中的行按「车间(自上而下逐层)→ 采购 → 委外」分段提交。
  ///
  /// **这不是一个事务，是编排。** 三条下达链各有自己的端点、请求形状、权限与
  /// 幂等键，合成一个端点要新造一套契约；任一段失败就停下并如实回报已完成的段，
  /// 未完成的行保留勾选让人接着重试。这一点与「父件 + 下层一起下单」页的口径一致。
  ///
  /// 车间段必须按层级自上而下逐层提交：一次性全发，深层那些按父件新数量填的量
  /// 会被服务端当成超出当时需求，记成公共备货产出。
  /// 勾选集里此刻真能下单的行，以及被折叠或表头筛选藏起来的行数。
  ///
  /// 「看到的勾选 = 提交的内容」是硬口径：主表折叠不撤勾、表头筛选也不撤勾，
  /// 而选中集是跨分页累积的。所以提交前必须按**当前投影**过一遍——
  /// 藏起来的行不进提交集合，但要如实数出来告诉人，不能静默丢掉。
  @override
  ({List<_MaterialGroup> visible, int hidden}) _selectedIssuableGroups() {
    final analysis = _analysis;
    if (analysis == null || _selectedMaterialGroupKeys.isEmpty) {
      return (visible: const [], hidden: 0);
    }
    final onScreen = <String, _MaterialGroup>{};
    for (final row in _materialTableRows(analysis)) {
      if (row.contextOnly) continue;
      for (final group in _materialRowAllGroups(row)) {
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
      if (_tableIssueBlockedReason(group) == null) visible.add(group);
    }
    return (visible: visible, hidden: hidden);
  }

  @override
  Future<void> _submitMaterialTableRows(List<_MaterialGroup> groups) async {
    final analysis = _analysis;
    if (analysis == null || _busy || groups.isEmpty) return;

    final pending = <_MaterialGroup, double>{};
    final blocked = <String>[];
    // 勾了但本次没有量的行(追加留 0)：批成功后一并撤勾，否则「下单(N)」一直挂着它，
    // _hasUnsubmittedMaterialTableInput 永真、45 秒轮询也不再跑。
    final skipped = <String>{};
    for (final group in groups) {
      final reason = _tableIssueBlockedReason(group);
      if (reason != null) {
        blocked.add('${_tableGroupLabel(group)}：$reason');
        continue;
      }
      final qty = _tableSubmitQtyOf(group);
      // 追加填 0 = 本次不动这一行，不进提交集合(服务端把「给了身份却不给数量」
      // 当成全量剩余下达，漏掉这一步会凭空多下一单)。
      if (qty <= 0.0001) {
        skipped.add(group.key);
        continue;
      }
      pending[group] = qty;
    }
    if (pending.isEmpty) {
      if (!mounted) return;
      context.appInfo(
        blocked.isEmpty ? '所选的行本次都没有要下的数量，请先在「下单数量」或「追加下单」里填数' : blocked.first,
      );
      return;
    }
    if (!await _confirmMaterialTableSubmit(pending, blocked)) return;

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
    _tableCascadeGeneration++;
    // 在路上的那份预览被代际作废后不会再走到它的 finally，预览态要在这里复位，
    // 否则「还缺数量」悬浮一直挂着「正在重算」。
    _tableCascadePreviewing = false;
    try {
      // 提交顺序 = **父先子后，跨路线**。一行的需求由它上面每一层的计划产出量决定，
      // 含父件超出需求的公共备货产出(V577/V589「顶层做 5000，委外件就要加工 5000」)。
      // 父件的计划 / 委外申请还没落地时，子件按父件新数量填的量会被服务端当成超出
      // 当时需求的部分、记成公共备货；随后父件的超量把子件需求抬上去，子件行就留下
      // 一截「已经下了却还缺」的幽灵缺口，而且认不回来(公共在途认领不含本分析自己的)。
      // 2026-09-23 实机：委外件「E极插套(酸洗)」的我方供料子件先按采购 5000 提交，
      // 记成需求 2000 + 公共 3000；委外 5000 随后下达把子件需求抬到 5000，子件行
      // 留下 3000 缺口——原来「采购 → 委外」的顺序正好反了。
      // 于是：逐层自上而下，同一层先下达车间(自制 + 需先自制的委外)、再直接外发
      // 委外；采购件没有下层，等全部父件落地后最后一次提交。
      final levels = {
        for (final group in pending.keys) group.representative.level,
      }.toList()..sort();
      var halted = false;
      for (final level in levels) {
        final atLevel = pending.keys
            .where((group) => group.representative.level == level)
            .toList(growable: false);
        final workshop = atLevel
            .where((group) => _tableIssueTarget(group).viaWorkshop)
            .toList(growable: false);
        if (workshop.isNotEmpty) {
          final ok = await _issueMaterialTableWorkshopBatch(workshop, pending);
          steps.add((
            label: '下达车间(第 $level 层，${workshop.length} 行)',
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
          );
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
        final buy = pending.keys
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
          );
          steps.add((
            label: '下达采购(${buy.length} 行)',
            ok: ok,
            note: ok ? null : haltNote,
          ));
          if (ok) settle(buy);
        }
      }
    } finally {
      _tableSubmitting = false;
    }

    if (!mounted) return;
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
      // 可调拨量随下达变化，下次进主表重取。
      _tableTransferableInScope = null;
    });
    _reportMaterialTableSubmit(steps, blocked);
  }

  /// 车间段的一层：顶层自制走 planDrafts、其余候选走 candidateInputs，一次 issue-plans。
  ///
  /// 顶层自制与其它自制行走的是**两条不同的通道**：服务端
  /// candidateRoutesByMaterialLine 明确把 ROOT_SUPPLY 排除在候选之外(除非它
  /// 确认为委外)，顶层产品行本身就是排产对象，要按 analysisLineId 走 planDrafts。
  /// 当成候选按 materialLineId 提交的话服务端解析不出候选、整批失败。
  Future<bool> _issueMaterialTableWorkshopBatch(
    List<_MaterialGroup> batch,
    Map<_MaterialGroup, double> pending,
  ) {
    final inputs = <_BucketCandidatePlanInput>[];
    final drafts = <_BucketPlanDraft>[];
    for (final group in batch) {
      // 锚点(顶层 = 产品行自己)已无剩余需求时，本次填的全是追加的公共备货产出。
      // 自制行直接按锚点产品判(服务端同一判据 canSchedule / canIssueSurplus)，不经
      // 估算值——估算值在分段提交期间是清空的，别的时候也可能还带着父行的比例。
      final anchor = _tableIssuedMakeAnchorOf(group);
      final publicSurplusOnly = anchor != null
          ? !anchor.canSchedule && anchor.canIssueSurplus
          : _tableGroupIssued(group) && _tableGroupResidual(group) <= 0.0001;
      final rootMakeLineId = _tableRootMakePlanLineId(group);
      if (rootMakeLineId != null) {
        drafts.add(
          _BucketPlanDraft(
            analysisLineId: rootMakeLineId,
            qty: pending[group]!,
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
    );
  }

  /// 外发段的一批：采购 / 直接外发委外各走既有的 _notifyRoute 链路(裁决 / 分块 /
  /// 幂等 / 409 恢复都在那里)，成功与否以它返回的新快照为准。
  Future<bool> _notifyMaterialTableBatch(
    MaterialSupplyRoute route,
    List<_MaterialGroup> batch,
    Map<_MaterialGroup, double> pending,
  ) async {
    final view = await _notifyRoute(
      route,
      onlyGroupKeys: batch.map((group) => group.key).toSet(),
      qtyByActionGroupKey: {
        for (final group in batch)
          ?group.representative.actionGroupKey: _qty(pending[group]!),
      },
      silent: true,
      allowExtra: _canOverSupply,
    );
    return view != null;
  }

  Future<bool> _confirmMaterialTableSubmit(
    Map<_MaterialGroup, double> pending,
    List<String> blocked,
  ) async {
    final lines = <String>[
      for (final entry in pending.entries)
        '· ${_tableGroupLabel(entry.key)}'
            ' ${_tableIssueTarget(entry.key).label} ${_qty(entry.value)}'
            '${_tableGroupIssued(entry.key) ? "(追加)" : ""}',
    ];
    final hiddenSelected = _selectedIssuableGroups().hidden;
    final confirmed = await UtenDialog.show(
      context,
      title: '确认下达 ${pending.length} 行？',
      content: SingleChildScrollView(
        child: Text(
          [
            ...lines.take(12),
            if (lines.length > 12) '…… 以及其余 ${lines.length - 12} 行',
            if (blocked.isNotEmpty) ...[
              '',
              '以下 ${blocked.length} 行本次跳过：',
              ...blocked.take(5).map((reason) => '· $reason'),
              if (blocked.length > 5) '…… 以及其余 ${blocked.length - 5} 行',
            ],
            // 折叠起来或被表头筛选藏起来的勾选行不会提交——如实说出来，
            // 别让人以为「我勾了的都下了」。
            if (hiddenSelected > 0) ...[
              '',
              '另有 $hiddenSelected 行还勾着但当前看不到'
                  '(折叠起来了，或被表头筛选挡住了)，本次不提交。',
            ],
            '',
            '按层级父先子后分段提交(同一层先车间再委外，采购最后一次)，'
                '中途失败会停下并告诉你停在哪一步。',
          ].join('\n'),
        ),
      ),
      confirmLabel: '下达',
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
      context.appSuccess(
        blocked.isEmpty
            ? '已下达：\n$summary'
            : '已下达：\n$summary\n(另有 ${blocked.length} 行不满足条件，本次跳过)',
      );
      return;
    }
    // 如实回报：说清哪几段成了、停在哪一步，别把半截状态说成成功。
    context.appError('下达没有全部完成：\n$summary\n未完成的行仍然勾着，可以修改后重试。');
  }

  Widget _materialTableAssignmentCell(
    ThemeData theme, {
    required String key,
    required String text,
    required bool autofilled,
    required bool empty,
    required String semanticsLabel,
    VoidCallback? onTap,
  }) => Semantics(
    label: semanticsLabel,
    button: onTap != null,
    child: InkWell(
      key: ValueKey(key),
      onTap: onTap,
      borderRadius: BorderRadius.circular(UtenRadius.control),
      child: InputDecorator(
        // 学习默认带出 = 黄框提醒核对；手选后清除(与计划向导同口径)。
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
    final operation = _supplyOperationType(actionId);
    if (operation == 'FUTURE_TRANSFER') return false;
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
                    '${_isSharedFutureClaimAction(target.actionId) ? '公共认领' : target.target?.label ?? '供给'} · '
                    '${target.status ?? '状态待回传'} · '
                    '分配 ${_qty(target.allocatedQty)} · '
                    '${target.documentNo?.trim().isNotEmpty == true ? target.documentNo! : '来源单号受权限保护'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (_canCancelSpecificAction(target.actionId))
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
              poolKey: [
                _analysis?.warehouseId,
                entry.value.first.goodsId,
                entry.value.first.colorId,
                entry.value.first.unitId,
                entry.value.first.confirmedRoute?.wireName,
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
                    (source) =>
                        !source.sourceIsCurrentAnalysis &&
                        source.availableToClaimQty > 0,
                  )
                  .toList(),
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
      minReasonLength: 2,
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
    if (analysis == null || !_canCancelSpecificAction(actionId) || _busy) {
      return false;
    }
    final sharedClaim = _isSharedFutureClaimAction(actionId);
    final reason = await _promptCancellationReason(
      sharedClaim ? '撤回公共认领（不撤回原采购 / 委外单）' : '撤回供给任务',
    );
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
      context.appSuccess(
        sharedClaim ? '公共认领已撤回，原供给单保留；分析已按最新事实重算' : '供给任务已撤回，分析已按最新事实重算',
      );
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
