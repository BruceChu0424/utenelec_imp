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

    // Persisted material-to-plan anchors cover direct MAKE issuance without
    // supply-action documents. Two equal SKUs retain separate path ownership.
    // Use exact active task documents, never a goods/name match. Two equal
    // SKUs on different BOM paths must retain separate child ownership.
    for (final material in analysis.materials) {
      if (material.planAnchorAnalysisLineId != null) {
        link(material.planAnchorAnalysisLineId!, material.materialLineId);
      }
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
        // 切视图后桶集合会变（如「待确认路线」视图里没有「已齐套」桶）：
        // 只移除失效的表头筛选值，仍有效的保留。
        onSelected: () => setState(() {
          _bomViewMode = mode;
          _bomTablePageNo = 1;
          _pruneMaterialTableFilters();
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
        _pruneMaterialTableFilters();
      }),
      label: _l10n.materialByProduct,
    ),
    _bomViewChip(
      theme,
      key: const ValueKey('material-bom-layout-material'),
      selected: _bomAggregateByMaterial,
      // 汇总视图的进度桶是「已覆盖/部分覆盖/未覆盖」三档，与产品视图不同；
      // 路线桶两边同键（BUY/SUBCONTRACT/MAKE/MIXED）可跨视图保留。
      onSelected: () => setState(() {
        _bomAggregateByMaterial = true;
        _bomTablePageNo = 1;
        _pruneMaterialTableFilters();
      }),
      label: _l10n.materialByMaterial,
    ),
  ];

  /// chip 计数与表格同口径：视图条件 × 关键词 × 表头筛选（产品视图）。
  /// 汇总视图的表头筛选作用于聚合行，chip 仍按节点计数（不含表头筛选）。
  int _bomModeCount(
    ProductionMaterialAnalysisView analysis,
    _BomViewMode mode,
  ) {
    final projection = _bomFilterProjection(analysis);
    var count = 0;
    for (final entry in projection.presentation.nodesByProduct.entries) {
      count += entry.value.where((material) {
        final passesFilters =
            projection.nodeMatchesFilters[material.materialLineId] ?? true;
        return passesFilters &&
            switch (mode) {
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

  // ===== 表头筛选协作契约：实现在 material_analysis_material_table.dart =====
  //
  // 投影层只认「行」的桶键（路线/进度都是行级语义，产品行与根供料节点合一），
  // 所以这里用探针行调用表格部分的桶键/命中判断，不重复实现状态推导。

  /// 节点的探针行（只用于算桶键与筛选命中，不进渲染）。
  _MaterialTableRow _probeMaterialRow(
    ProductionMaterialAnalysisMaterial material,
    _MaterialAnalysisIndexes indexes,
  );

  /// 产品行的探针行（承载根供料节点，与 P1 行同一路线/进度口径）。
  _MaterialTableRow _probeProductRow(
    ProductionMaterialAnalysisProduct product,
    _MaterialAnalysisIndexes indexes,
  );

  /// 行是否通过当前表头筛选（无激活筛选恒 true；脏路线组豁免路线筛选）。
  bool _headerFilterMatchesRow(_MaterialTableRow row);

  bool get _hasActiveMaterialTableFilters;

  /// 表头筛选值 + 路线草稿/脏组签名（投影缓存键的一部分）。
  String _materialTableProjectionSignature();

  Map<String, List<MasterFacetBucket>> _materialTableFacetsOf(
    Iterable<_MaterialTableRow> rows,
  );

  /// 视图 chip + 关键词 + 表头筛选的节点级投影（2026-09-10 F2a 起表头筛选
  /// 也在这里生效，而不是拍平成行之后再裁）：
  ///
  /// 1. 基础可见层 = 视图条件 × 关键词，命中节点的祖先保留为普通行（原口径）；
  /// 2. 表头筛选在基础可见层内按行级桶键命中，未命中但有子孙命中的祖先
  ///    （含产品行）保留为**只读上下文**（`contextOnly*`，无勾选/下拉，不计数）；
  ///    `hasChildren`/箭头/子件数与 chip 计数都以本投影为准；
  /// 3. 桶按基础可见层（不含表头筛选）聚合，选了一个值其余值仍在下拉里。
  ///
  /// 汇总视图的表头筛选作用于聚合行（见 `_aggregateTableRows`），本投影不处理。
  _BomFilterProjection _bomFilterProjection(
    ProductionMaterialAnalysisView analysis,
  ) {
    final cacheKey = [
      _bomViewMode.name,
      _bomKeyword,
      _materialTableProjectionSignature(),
    ].join('\u0000');
    if (identical(_bomProjectionAnalysis, analysis) &&
        _bomProjectionKey == cacheKey &&
        _bomProjectionCache != null) {
      return _bomProjectionCache!;
    }
    final indexes = _analysisIndexes(analysis);
    final presentation = _bomPresentation(analysis);
    final headerFilterActive =
        _hasActiveMaterialTableFilters && !_bomAggregateByMaterial;
    final nodesByProduct =
        <String?, List<ProductionMaterialAnalysisMaterial>>{};
    final visibleProductIds = <String>{};
    final contextOnlyProductIds = <String>{};
    final contextOnlyMaterialIds = <String>{};
    final nodeMatchesFilters = <String, bool>{};
    final facetRows = <_MaterialTableRow>[];
    var directMatches = 0;
    var visibleNodes = 0;
    for (final entry in presentation.nodesByProduct.entries) {
      final product = indexes.productsById[entry.key];
      final ownsProductRow =
          product != null && !_isEmbeddedMakeChildProduct(product);
      bool textMatches(ProductionMaterialAnalysisMaterial material) =>
          _bomTextMatches(material, product) ||
          _bomTextMatches(
            material,
            indexes.productsById[material.analysisLineId],
          );
      directMatches += entry.value.where((material) {
        return _bomModeMatches(material) && textMatches(material);
      }).length;
      final base = _visibleBomNodes(
        entry.value,
        product,
        parentIds: presentation.parentIdsByMaterial,
        textMatches: textMatches,
      );
      // 探针行：产品行承载根供料节点；其余节点各自一行。全量节点都建探针，
      // chip 计数（其它视图）才能与表头筛选同口径。
      final productRow = ownsProductRow
          ? _probeProductRow(product, indexes)
          : null;
      final rootId = productRow?.material?.materialLineId;
      final probeByNode = <String, _MaterialTableRow>{
        for (final node in entry.value)
          if (node.materialLineId != rootId)
            node.materialLineId: _probeMaterialRow(node, indexes),
      };
      bool headerMatches(ProductionMaterialAnalysisMaterial node) {
        if (!headerFilterActive) return true;
        if (node.materialLineId == rootId) {
          return productRow == null || _headerFilterMatchesRow(productRow);
        }
        final probe = probeByNode[node.materialLineId];
        return probe == null || _headerFilterMatchesRow(probe);
      }

      for (final node in entry.value) {
        nodeMatchesFilters[node.materialLineId] =
            textMatches(node) && headerMatches(node);
      }
      if (base.isEmpty) continue;
      // 桶：当前视图基础可见层（产品行 + 非根节点），不含表头筛选本身。
      if (productRow != null) facetRows.add(productRow);
      for (final node in base) {
        final probe = probeByNode[node.materialLineId];
        if (probe != null) facetRows.add(probe);
      }
      if (!headerFilterActive) {
        nodesByProduct[entry.key] = base;
        visibleNodes += base.length;
        if (ownsProductRow) visibleProductIds.add(product.analysisLineId);
        continue;
      }
      final productMatches = productRow == null
          ? true
          : _headerFilterMatchesRow(productRow);
      final byId = {for (final node in base) node.materialLineId: node};
      final matched = <String>{
        for (final node in base)
          if (node.materialLineId != rootId && headerMatches(node))
            node.materialLineId,
      };
      // 命中节点的祖先（基础可见层内）保留为只读上下文。
      final keep = <String>{};
      for (final id in matched) {
        ProductionMaterialAnalysisMaterial? current = byId[id];
        while (current != null && keep.add(current.materialLineId)) {
          current =
              byId[presentation.parentIdsByMaterial[current.materialLineId]];
        }
      }
      for (final id in keep) {
        if (!matched.contains(id) && id != rootId) {
          contextOnlyMaterialIds.add(id);
        }
      }
      final productVisible = productMatches || matched.isNotEmpty;
      if (rootId != null && byId.containsKey(rootId) && productVisible) {
        keep.add(rootId);
      }
      final visible = base
          .where((node) => keep.contains(node.materialLineId))
          .toList(growable: false);
      if (ownsProductRow) {
        if (!productVisible) continue;
        visibleProductIds.add(product.analysisLineId);
        if (!productMatches) contextOnlyProductIds.add(product.analysisLineId);
        nodesByProduct[entry.key] = visible;
        visibleNodes += visible.length;
      } else if (visible.isNotEmpty) {
        nodesByProduct[entry.key] = visible;
        visibleNodes += visible.length;
      }
    }
    final projection = _BomFilterProjection(
      nodesByProduct: nodesByProduct,
      directMatchCount: directMatches,
      visibleNodeCount: visibleNodes,
      presentation: presentation,
      visibleProductIds: visibleProductIds,
      contextOnlyProductIds: contextOnlyProductIds,
      contextOnlyMaterialIds: contextOnlyMaterialIds,
      nodeMatchesFilters: nodeMatchesFilters,
      facets: _materialTableFacetsOf(facetRows),
    );
    _bomProjectionAnalysis = analysis;
    _bomProjectionKey = cacheKey;
    _bomProjectionCache = projection;
    return projection;
  }
}
