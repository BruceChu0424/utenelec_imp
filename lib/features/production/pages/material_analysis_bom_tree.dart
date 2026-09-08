part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisBomTreeState
    extends _MaterialAnalysisProductTasksState {
  ProductionMaterialAnalysisView? _bomPresentationAnalysis;
  _BomPresentation? _bomPresentationCache;

  _BomPresentation _bomPresentation(ProductionMaterialAnalysisView analysis) {
    if (identical(_bomPresentationAnalysis, analysis) &&
        _bomPresentationCache != null) {
      return _bomPresentationCache!;
    }
    final indexes = _analysisIndexes(analysis);
    final byId = {
      for (final material in analysis.materials)
        material.materialLineId: material,
    };
    final byNode = {
      for (final material in analysis.materials)
        if (material.nodeKey?.isNotEmpty == true)
          (material.analysisLineId, material.nodeKey!): material,
    };
    final rootSupplyByProduct = <String?, String>{
      for (final material in analysis.materials)
        if (material.isRootSupply)
          material.analysisLineId: material.materialLineId,
    };
    final physicalParents = <String, String?>{
      for (final material in analysis.materials)
        material.materialLineId: material.isRootSupply
            ? null
            : material.parentNodeKey == null
            ? rootSupplyByProduct[material.analysisLineId]
            : byNode[(material.analysisLineId, material.parentNodeKey!)]
                  ?.materialLineId,
    };
    final sourceByChild = <String, String>{};
    final ambiguousChildren = <String>{};
    void link(String childId, String sourceId) {
      final child = indexes.productsById[childId];
      final source = byId[sourceId];
      if (!_isEmbeddedMakeChildProduct(child) || source == null) return;
      if (child!.parentAnalysisLineId != null &&
          child.parentAnalysisLineId != source.analysisLineId) {
        return;
      }
      final previous = sourceByChild[childId];
      if (previous != null && previous != sourceId) {
        ambiguousChildren.add(childId);
      } else {
        sourceByChild[childId] = sourceId;
      }
    }

    // Use exact active task documents, never a goods/name match. Two equal
    // SKUs on different BOM paths must retain separate child ownership.
    for (final material in analysis.materials) {
      for (final target in material.notifiedTargets) {
        if (target.status == 'CANCELLED' || target.documentId == null) continue;
        if (target.documentType == 'PREPLAN_MAKE_TASK' ||
            target.documentType == 'SUBCONTRACT_MAKE_TASK') {
          link(target.documentId!, material.materialLineId);
        }
      }
    }
    // Older responses expose the child ID on delegated zero descendants.
    // Their first non-delegated ancestor is the exact ownership boundary.
    final explicitChildren = sourceByChild.keys.toSet();
    for (final material in analysis.materials) {
      final childId = material.delegatedToAnalysisLineId;
      if (childId == null || explicitChildren.contains(childId)) continue;
      var parentId = physicalParents[material.materialLineId];
      final visited = <String>{};
      while (parentId != null && visited.add(parentId)) {
        final parent = byId[parentId];
        if (parent == null) break;
        if (parent.delegatedToAnalysisLineId != childId) {
          link(childId, parentId);
          break;
        }
        parentId = physicalParents[parentId];
      }
    }
    for (final childId in ambiguousChildren) {
      sourceByChild.remove(childId);
    }
    final ownershipSourceIds = sourceByChild.values.toSet();
    final shadowIds = <String>{
      for (final material in analysis.materials)
        if (!ownershipSourceIds.contains(material.materialLineId) &&
            material.requiredQty <= 0 &&
            material.delegatedToAnalysisLineId != null &&
            sourceByChild.containsKey(material.delegatedToAnalysisLineId) &&
            indexes
                    .materialsByProduct[material.delegatedToAnalysisLineId]
                    ?.isNotEmpty ==
                true)
          material.materialLineId,
    };
    final parentIds = <String, String?>{};
    for (final material in analysis.materials) {
      if (shadowIds.contains(material.materialLineId)) continue;
      var parentId = physicalParents[material.materialLineId];
      final visited = <String>{};
      while (parentId != null &&
          shadowIds.contains(parentId) &&
          visited.add(parentId)) {
        parentId = physicalParents[parentId];
      }
      parentIds[material.materialLineId] =
          parentId ?? sourceByChild[material.analysisLineId];
    }
    final rootIds = <String, String?>{};
    final depths = <String, int>{};
    final visiting = <String>{};
    void resolve(String id) {
      if (depths.containsKey(id)) return;
      if (!visiting.add(id)) {
        parentIds[id] = null;
        rootIds[id] = byId[id]?.analysisLineId;
        depths[id] = byId[id]?.isRootSupply == true ? 0 : 1;
        return;
      }
      final parentId = parentIds[id];
      if (parentId == null ||
          parentId == id ||
          !parentIds.containsKey(parentId)) {
        rootIds[id] = byId[id]?.analysisLineId;
        depths[id] = byId[id]?.isRootSupply == true ? 0 : 1;
      } else {
        resolve(parentId);
        rootIds[id] = rootIds[parentId];
        depths[id] = (depths[parentId] ?? 0) + 1;
      }
      visiting.remove(id);
    }

    final nodesByProduct =
        <String?, List<ProductionMaterialAnalysisMaterial>>{};
    for (final material in analysis.materials) {
      if (shadowIds.contains(material.materialLineId)) continue;
      resolve(material.materialLineId);
      nodesByProduct
          .putIfAbsent(rootIds[material.materialLineId], () => [])
          .add(material);
    }
    final presentation = _BomPresentation(
      nodesByProduct: nodesByProduct,
      parentIdsByMaterial: parentIds,
      rootIdsByMaterial: rootIds,
      depthByMaterial: depths,
    );
    _bomPresentationAnalysis = analysis;
    _bomPresentationCache = presentation;
    return presentation;
  }

  @override
  bool _hasResolvedMaterialSource(ProductionMaterialAnalysisMaterial material) {
    final analysis = _analysis;
    if (analysis == null) return false;
    final rootId = _bomPresentation(
      analysis,
    ).rootIdsByMaterial[material.materialLineId];
    final product = _analysisIndexes(analysis).productsById[rootId];
    return product != null && !_isEmbeddedMakeChildProduct(product);
  }

  /// 去重后筛出非目标仓，避免同 SKU 在多个 BOM 兄弟节点上重复报数。
  List<_OffTargetWarehousePeg> _offTargetWarehousePegs(
    ProductionMaterialAnalysisView analysis,
  ) {
    final targetWarehouseId = analysis.warehouseId?.trim();
    if (targetWarehouseId == null || targetWarehouseId.isEmpty) return const [];

    final seenDimensions = <String>{};
    final result = <_OffTargetWarehousePeg>[];
    for (final material in analysis.materials) {
      final dimensionKey = _materialDimensionKey(material);
      if (!seenDimensions.add(dimensionKey)) continue;

      for (final stock in material.warehouseStocks) {
        if (stock.warehouseId == targetWarehouseId || stock.ownPeggedQty <= 0) {
          continue;
        }
        result.add(
          _OffTargetWarehousePeg(
            materialLabel: _goodsLabel(material),
            unitName: material.unitName,
            warehouseLabel:
                stock.warehouseName ?? stock.warehouseCode ?? stock.warehouseId,
            qty: stock.ownPeggedQty,
          ),
        );
      }
    }
    result.sort((left, right) {
      final byWarehouse = left.warehouseLabel.compareTo(right.warehouseLabel);
      return byWarehouse != 0
          ? byWarehouse
          : left.materialLabel.compareTo(right.materialLabel);
    });
    return List.unmodifiable(result);
  }

  String _goodsLabel(ProductionMaterialAnalysisMaterial material) {
    final name = material.goodsName?.trim();
    final code = material.goodsCode?.trim();
    if (name?.isNotEmpty == true && code?.isNotEmpty == true) {
      return '$name($code)';
    }
    return name?.isNotEmpty == true
        ? name!
        : code?.isNotEmpty == true
        ? code!
        : '未命名物料';
  }

  Widget _offTargetWarehouseBanner(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
    List<_OffTargetWarehousePeg> pegs,
  ) {
    final targetWarehouse = analysis.warehouses
        .where((warehouse) => warehouse.warehouseId == analysis.warehouseId)
        .firstOrNull;
    final targetWarehouseLabel =
        targetWarehouse?.warehouseName ?? analysis.warehouseId ?? '当前分析仓';
    return Semantics(
      container: true,
      liveRegion: true,
      label: '合格到货在非分析仓，当前不计入备料',
      child: Container(
        key: const Key('material-analysis-off-target-warehouse-warning'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.55),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '合格到货在非分析仓，当前不计入备料',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '目标仓：$targetWarehouseLabel。以下数量已通过品质并绑定本分析，'
                    '但实际位于其它仓：',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  for (final peg in pegs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                      child: Text(
                        '• ${peg.materialLabel}：${peg.warehouseLabel} '
                        '${_qty(peg.qty)}${peg.unitName?.isNotEmpty == true ? ' ${peg.unitName}' : ''}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w700,
                          height: 1.45,
                        ),
                      ),
                    ),
                  Text(
                    '普通调拨不会迁移这笔分析绑定。请走收货红冲/更正流程，'
                    '并在目标仓重新登记、验收；处理后刷新分析。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 树顶筛选按钮（全部 BOM/只看缺料/待确认路线 + 按产品看/按物料汇总）。
  /// 与旁边搜索框等高（最小 48px）、纯文字无图标；选中态用主题深绿实底 +
  /// 白字——默认 ChoiceChip 的选中色偏淡，年长用户看不出当前选中了哪个视图。
  Widget _bomViewChip(
    ThemeData theme, {
    Key? key,
    required bool selected,
    required VoidCallback? onSelected,
    required String label,
  }) {
    final scheme = theme.colorScheme;
    final foreground = selected ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        key: key,
        color: selected ? scheme.primary : scheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          onTap: onSelected,
          canRequestFocus: onSelected != null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s16,
                vertical: UtenSpacing.s4,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// View controls live in the shared table toolbar, including fullscreen.
  /// 查找框常驻顶部卡片（更新时间右侧）；全屏时顶部卡片不可见，才在工具条
  /// 里补挂一个（与顶部卡片共享同一控制器 [_bomSearch]，两处不会同时出现）。
  List<Widget> _bomToolbarActions(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) => [
    if (_bomTableFullscreen)
      SizedBox(
        width: context.breakpoint.isCompact ? 200 : 240,
        child: UtenSearchBar(
          key: const Key('material-bom-search'),
          controller: _bomSearch,
          hint: _l10n.materialSearchHint,
          onChanged: _bomSearchChanged,
        ),
      ),
    for (final mode in _BomViewMode.values)
      _bomViewChip(
        theme,
        key: ValueKey('material-bom-view-${mode.name}'),
        selected: _bomViewMode == mode,
        onSelected: () => setState(() {
          _bomViewMode = mode;
          _bomTablePageNo = 1;
        }),
        label: '${mode.label} ${_bomModeCount(analysis, mode)}',
      ),
    _bomViewChip(
      theme,
      key: const ValueKey('material-bom-layout-product'),
      selected: !_bomAggregateByMaterial,
      onSelected: () => setState(() {
        _bomAggregateByMaterial = false;
        _bomTablePageNo = 1;
      }),
      label: _l10n.materialByProduct,
    ),
    _bomViewChip(
      theme,
      key: const ValueKey('material-bom-layout-material'),
      selected: _bomAggregateByMaterial,
      onSelected: () => setState(() {
        _bomAggregateByMaterial = true;
        _bomTablePageNo = 1;
      }),
      label: _l10n.materialByMaterial,
    ),
  ];

  int _bomModeCount(
    ProductionMaterialAnalysisView analysis,
    _BomViewMode mode,
  ) {
    var count = 0;
    for (final entry in _bomPresentation(analysis).nodesByProduct.entries) {
      count += entry.value.where((material) {
        return switch (mode) {
          _BomViewMode.shortage => material.shortageQty > 0,
          _BomViewMode.unconfirmed =>
            material.shortageQty > 0 && material.confirmedRoute == null,
          _BomViewMode.all => true,
        };
      }).length;
    }
    return count;
  }

  /// MAKE_COMPONENT / SUBCONTRACT_MAKE remain real server-side ownership and
  /// traceability facts. Their real material requirements and plan/progress
  /// stay below the exact source node, rather than becoming extra external
  /// product roots or being hidden after ownership transfers.
  bool _isEmbeddedMakeChildProduct(
    ProductionMaterialAnalysisProduct? product,
  ) =>
      product?.sourceType == 'MAKE_COMPONENT' ||
      product?.sourceType == 'SUBCONTRACT_MAKE';

  bool _bomModeMatches(ProductionMaterialAnalysisMaterial material) =>
      switch (_bomViewMode) {
        _BomViewMode.shortage => material.shortageQty > 0,
        _BomViewMode.unconfirmed =>
          material.shortageQty > 0 && material.confirmedRoute == null,
        _BomViewMode.all => true,
      };

  bool _bomTextMatches(
    ProductionMaterialAnalysisMaterial material,
    ProductionMaterialAnalysisProduct? product,
  ) {
    if (_bomKeyword.isEmpty) return true;
    return [
      product?.goodsCode,
      product?.goodsName,
      product?.orderNo,
      material.goodsCode,
      material.goodsName,
      material.spec,
      material.colorName,
    ].whereType<String>().any(
      (value) => value.toLowerCase().contains(_bomKeyword),
    );
  }

  /// BOM 查找：防抖与清除按钮由 UtenSearchBar 内置；关键词变化才重算可见层。
  ///（清除时本回调同样收到空串，与原手写清除按钮行为一致：清词 + 可见层归位。）
  void _bomSearchChanged(String value) {
    final keyword = value.trim().toLowerCase();
    if (keyword == _bomKeyword) return;
    setState(() {
      _bomKeyword = keyword;
      _bomTablePageNo = 1;
    });
  }

  /// 只看缺料/待确认时仍把命中节点的祖先保留下来，员工能看懂它属于哪件产品、
  /// 哪条装配路径；祖先只是定位上下文，不会被误算为缺料或加入批量选择。
  List<ProductionMaterialAnalysisMaterial> _visibleBomNodes(
    List<ProductionMaterialAnalysisMaterial> nodes,
    ProductionMaterialAnalysisProduct? product, {
    required Map<String, String?> parentIds,
    required bool Function(ProductionMaterialAnalysisMaterial) textMatches,
  }) {
    if (_bomViewMode == _BomViewMode.all && _bomKeyword.isEmpty) return nodes;
    final byId = {for (final node in nodes) node.materialLineId: node};
    final visibleIds = <String>{};
    for (final node in nodes) {
      if (!_bomModeMatches(node) || !textMatches(node)) continue;
      ProductionMaterialAnalysisMaterial? current = node;
      while (current != null && visibleIds.add(current.materialLineId)) {
        current = byId[parentIds[current.materialLineId]];
      }
    }
    return nodes
        .where((node) => visibleIds.contains(node.materialLineId))
        .toList(growable: false);
  }

  // ===== 按物料汇总缺料视图 =====
  //
  // 多产品联合分析（十几个、二十几个产品）时 BOM 节点可能上千行，
  // 平铺没法看。这里把同一物料跨产品的所有 BOM 路径聚成一行：
  // 行上看总需求/现货/总缺口/涉及产品数，展开后逐路径看「哪个产品、
  // 哪个父件各要多少」（pegging 明细）并直接勾选。聚合只是展示投影，
  // 勾选与下达仍写回各自的逐路径节点任务，合单不合账。

  /// 同一物料的稳定聚合键：货品 UUID + 颜色 + 单位；缺 UUID 时退回
  /// 编码/名称组合，避免把不同颜色或不同单位误并成一行。
  String _aggregateKeyOf(ProductionMaterialAnalysisMaterial material) {
    final goods = material.goodsId ?? 'LINE|${material.materialLineId}';
    return '$goods|${material.colorId ?? material.colorName ?? ''}'
        '|${material.unitId ?? material.unitName ?? ''}';
  }

  List<_MaterialAggregate> _materialAggregates(
    ProductionMaterialAnalysisView analysis,
    _MaterialAnalysisIndexes indexes,
  ) {
    final byKey = <String, List<ProductionMaterialAnalysisMaterial>>{};
    final presentation = _bomPresentation(analysis);
    for (final nodes in presentation.nodesByProduct.values) {
      for (final material in nodes) {
        if (!_bomModeMatches(material)) continue;
        final product = indexes.productsById[material.analysisLineId];
        final root =
            indexes.productsById[presentation.rootIdsByMaterial[material
                .materialLineId]];
        if (!_bomTextMatches(material, product) &&
            !_bomTextMatches(material, root)) {
          continue;
        }
        byKey.putIfAbsent(_aggregateKeyOf(material), () => []).add(material);
      }
    }
    final aggregates = [
      for (final entry in byKey.entries)
        _MaterialAggregate(
          key: entry.key,
          paths: entry.value,
          rootProductIds: {
            for (final material in entry.value)
              presentation.rootIdsByMaterial[material.materialLineId],
          },
        ),
    ];
    // 缺口最大的排最前，让计划员先处理最卡脖子的料。
    aggregates.sort((a, b) {
      final byShortage = b.totalShortage.compareTo(a.totalShortage);
      if (byShortage != 0) return byShortage;
      return (a.goodsCode ?? a.goodsName ?? a.key).compareTo(
        b.goodsCode ?? b.goodsName ?? b.key,
      );
    });
    return aggregates;
  }

  List<ProductionMaterialAnalysisMaterial> _orderedBomNodes(
    List<ProductionMaterialAnalysisMaterial> nodes, {
    required Map<String, String?> parentIds,
  }) {
    final byId = {for (final node in nodes) node.materialLineId: node};
    final children = <String, List<ProductionMaterialAnalysisMaterial>>{};
    final roots = <ProductionMaterialAnalysisMaterial>[];
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
    int compare(
      ProductionMaterialAnalysisMaterial left,
      ProductionMaterialAnalysisMaterial right,
    ) {
      final byLevel = left.level.compareTo(right.level);
      if (byLevel != 0) return byLevel;
      return (left.goodsCode ?? left.goodsName ?? left.materialLineId)
          .compareTo(
            right.goodsCode ?? right.goodsName ?? right.materialLineId,
          );
    }

    roots.sort(compare);
    for (final values in children.values) {
      values.sort(compare);
    }
    final result = <ProductionMaterialAnalysisMaterial>[];
    final visited = <String>{};
    void hide(ProductionMaterialAnalysisMaterial node) {
      if (!visited.add(node.materialLineId)) return;
      final key = node.materialLineId;
      for (final child
          in children[key] ?? const <ProductionMaterialAnalysisMaterial>[]) {
        hide(child);
      }
    }

    void visit(ProductionMaterialAnalysisMaterial node) {
      if (!visited.add(node.materialLineId)) return;
      result.add(node);
      final key = node.materialLineId;
      if (_collapsedBomBranches.contains(key)) {
        for (final child
            in children[key] ?? const <ProductionMaterialAnalysisMaterial>[]) {
          hide(child);
        }
        return;
      }
      for (final child
          in children[key] ?? const <ProductionMaterialAnalysisMaterial>[]) {
        visit(child);
      }
    }

    for (final root in roots) {
      visit(root);
    }
    final remaining =
        nodes.where((node) => !visited.contains(node.materialLineId)).toList()
          ..sort(compare);
    for (final node in remaining) {
      visit(node);
    }
    return result;
  }

  void _toggleBomProductCollapsed(String analysisLineId) {
    setState(() {
      if (!_collapsedBomProducts.add(analysisLineId)) {
        _collapsedBomProducts.remove(analysisLineId);
      }
    });
  }

  _BomFilterProjection _bomFilterProjection(
    ProductionMaterialAnalysisView analysis,
  ) {
    if (identical(_bomProjectionAnalysis, analysis) &&
        _bomProjectionMode == _bomViewMode &&
        _bomProjectionKeyword == _bomKeyword &&
        _bomProjectionCache != null) {
      return _bomProjectionCache!;
    }
    final indexes = _analysisIndexes(analysis);
    final nodesByProduct =
        <String?, List<ProductionMaterialAnalysisMaterial>>{};
    var directMatches = 0;
    var visibleNodes = 0;
    final presentation = _bomPresentation(analysis);
    for (final entry in presentation.nodesByProduct.entries) {
      final product = indexes.productsById[entry.key];
      bool textMatches(ProductionMaterialAnalysisMaterial material) =>
          _bomTextMatches(material, product) ||
          _bomTextMatches(
            material,
            indexes.productsById[material.analysisLineId],
          );
      directMatches += entry.value.where((material) {
        return _bomModeMatches(material) && textMatches(material);
      }).length;
      final visible = _visibleBomNodes(
        entry.value,
        product,
        parentIds: presentation.parentIdsByMaterial,
        textMatches: textMatches,
      );
      if (visible.isNotEmpty) nodesByProduct[entry.key] = visible;
      visibleNodes += visible.length;
    }
    final projection = _BomFilterProjection(
      nodesByProduct: nodesByProduct,
      directMatchCount: directMatches,
      visibleNodeCount: visibleNodes,
      presentation: presentation,
    );
    _bomProjectionAnalysis = analysis;
    _bomProjectionMode = _bomViewMode;
    _bomProjectionKeyword = _bomKeyword;
    _bomProjectionCache = projection;
    return projection;
  }
}
