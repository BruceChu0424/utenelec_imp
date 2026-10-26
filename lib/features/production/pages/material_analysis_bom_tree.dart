part of 'production_material_analysis_page.dart';

@visibleForTesting
int debugMaterialSynchronousAggregateBuilds = 0;

/// BOM 兄弟行排序:先层级、再货品编号(无编号退货品名、再退行 id)。
///
/// **全站唯一口径**:物料分析准备页主表([_MaterialAnalysisBomTreeState._orderedBomNodes])
/// 与三个准备桶的共用核对下单页
/// 共用同一个比较器——两张表看的是同一棵 BOM,行序不一样用户就得在两页之间重新
/// 找一遍物料(2026-09-15 用户口径「里面的顺序按照物料分析里准备下面的顺序一样」)。
/// 两处属于不同的 State 类,故落在库级私有函数上而不是某个类里。
int _compareBomSiblings(
  ProductionMaterialAnalysisMaterial left,
  ProductionMaterialAnalysisMaterial right,
) {
  final byLevel = left.level.compareTo(right.level);
  if (byLevel != 0) return byLevel;
  return (left.goodsCode ?? left.goodsName ?? left.materialLineId).compareTo(
    right.goodsCode ?? right.goodsName ?? right.materialLineId,
  );
}

abstract class _MaterialAnalysisBomTreeState
    extends _MaterialAnalysisProductTasksState {
  ProductionMaterialAnalysisView? _bomPresentationAnalysis;
  _BomPresentation? _bomPresentationCache;

  final _bomPresentationSnapshots = Expando<_BomPresentation>();

  @override
  Future<void> _warmMaterialReadSnapshot(
    ProductionMaterialAnalysisView view,
    bool Function() isCurrent,
  ) async {
    final budget = UiWorkBudget(
      isCurrent: isCurrent,
      debugLabel: 'material-snapshot',
    );
    Future<void> consume(Iterable<void> steps) async {
      final iterator = steps.iterator;
      while (true) {
        budget.ensureCurrent();
        if (!iterator.moveNext()) break;
        await budget.checkpoint();
      }
    }

    if (_materialIndexSnapshots[view] == null) {
      late _MaterialAnalysisIndexes indexes;
      await consume(_analysisIndexWork(view, (value) => indexes = value));
      budget.ensureCurrent();
      _materialIndexSnapshots[view] = indexes;
    }
    if (_bomPresentationSnapshots[view] == null) {
      late _BomPresentation presentation;
      await consume(
        _bomPresentationWork(view, (value) => presentation = value),
      );
      budget.ensureCurrent();
      _bomPresentationSnapshots[view] = presentation;
    }
  }

  _BomPresentation _bomPresentation(ProductionMaterialAnalysisView analysis) {
    if (identical(_bomPresentationAnalysis, analysis) &&
        _bomPresentationCache != null) {
      return _bomPresentationCache!;
    }
    var presentation = _bomPresentationSnapshots[analysis];
    if (presentation == null) {
      for (final _ in _bomPresentationWork(
        analysis,
        (value) => presentation = value,
      )) {}
      _bomPresentationSnapshots[analysis] = presentation!;
    }
    _bomPresentationAnalysis = analysis;
    _bomPresentationCache = presentation;
    return presentation!;
  }

  Iterable<void> _bomPresentationWork(
    ProductionMaterialAnalysisView analysis,
    void Function(_BomPresentation) complete,
  ) sync* {
    final indexes = _analysisIndexes(analysis);
    final byId = indexes.materialsById;
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
      if (child?.sourceType == 'AGGREGATE_MAKE') return;
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
      yield null;
      if (material.planAnchorAnalysisLineId != null) {
        link(material.planAnchorAnalysisLineId!, material.materialLineId);
      }
      for (final target in material.notifiedTargets) {
        if (target.status == 'CANCELLED' || target.documentId == null) continue;
        if (target.documentType == 'PREPLAN_MAKE_TASK') {
          link(target.documentId!, material.materialLineId);
        }
      }
    }
    // Older responses expose the child ID on delegated zero descendants.
    // Their first non-delegated ancestor is the exact ownership boundary.
    final explicitChildren = sourceByChild.keys.toSet();
    for (final material in analysis.materials) {
      yield null;
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
        if (material.isRootSupply &&
            indexes.productsById[material.analysisLineId]?.sourceType ==
                'AGGREGATE_MAKE')
          material.materialLineId,
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
      yield null;
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
      yield null;
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
    complete(presentation);
  }

  @override
  bool _hasResolvedMaterialSource(ProductionMaterialAnalysisMaterial material) {
    final analysis = _analysis;
    if (analysis == null) return false;
    final rootId = _bomPresentation(
      analysis,
    ).rootIdsByMaterial[material.materialLineId];
    final product = _analysisIndexes(analysis).productsById[rootId];
    return product != null &&
        (product.sourceType == 'AGGREGATE_MAKE' ||
            !_isEmbeddedMakeChildProduct(product));
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
    UtenSegmentRow<_BomViewMode>(
      key: const Key('material-bom-view-segments'),
      showSelectedIcon: false,
      emptySelectionAllowed: true,
      segments: [
        for (final mode in _BomViewMode.values)
          ButtonSegment(
            value: mode,
            label: Text(
              '${mode.label} ${_bomModeCount(analysis, mode)}',
              key: ValueKey('material-bom-view-${mode.name}'),
            ),
          ),
      ],
      selected: {_bomViewMode},
      onSelectionChanged: (values) {
        final mode = values.isEmpty ? _bomViewMode : values.single;
        // 切视图后桶集合会变（如「待确认路线」视图里没有「已齐套」桶）：
        // 只移除失效的表头筛选值，仍有效的保留。
        // 重复点当前视图仍执行原刷新投影回调，不清空当前视图。
        setState(() {
          _bomViewMode = mode;
          _pruneMaterialTableFilters();
        });
      },
    ),
    _bomLayoutSwitchGroup(theme),
    ?_materialAggregateToolbarAction(),
  ];

  /// 布局切换组（按产品看/按物料汇总）左右各一条竖分割线：与前面的视图
  /// 条件分段、后面的动作按钮明确分组（2026-10-08 用户口径「要有区分」）。
  Widget _bomLayoutSwitchGroup(ThemeData theme) => Row(
    key: const Key('material-bom-layout-switch-group'),
    mainAxisSize: MainAxisSize.min,
    children: [
      _bomToolbarGroupDivider(
        theme,
        key: const Key('material-bom-layout-divider-start'),
      ),
      const SizedBox(width: UtenFilterRow.rowGap),
      Flexible(
        child: ValueListenableBuilder<bool?>(
          valueListenable: _bomLayoutPending,
          builder: (context, pending, _) => UtenSegmentRow<bool>(
            key: const Key('material-bom-layout-segments'),
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: [
              ButtonSegment(
                value: false,
                label: Text(
                  _l10n.materialByProduct,
                  key: const ValueKey('material-bom-layout-product'),
                ),
              ),
              ButtonSegment(
                value: true,
                label: Text(
                  _l10n.materialByMaterial,
                  key: const ValueKey('material-bom-layout-material'),
                ),
              ),
            ],
            selected: {
              _bomLayoutIntentScope == _sessionScopeKey()
                  ? pending ?? _bomAggregateByMaterial
                  : _bomAggregateByMaterial,
            },
            onSelectionChanged: (values) {
              final aggregate = values.isEmpty
                  ? _bomAggregateByMaterial
                  : values.single;
              unawaited(_switchBomLayout(aggregate));
            },
          ),
        ),
      ),
      const SizedBox(width: UtenFilterRow.rowGap),
      _bomToolbarGroupDivider(
        theme,
        key: const Key('material-bom-layout-divider-end'),
      ),
    ],
  );

  Future<void> _switchBomLayout(bool aggregate) async {
    if (_bomLayoutPending.value == null &&
        aggregate == _bomAggregateByMaterial) {
      return;
    }
    final epoch = ++_bomLayoutTransitionEpoch;
    final analysis = _analysis;
    final scope = _sessionScopeKey();
    _bomLayoutIntentScope = scope;
    bool current() =>
        mounted &&
        epoch == _bomLayoutTransitionEpoch &&
        _sessionScopeKey() == scope;
    final fade = utenMotionDurationOf(
      context,
      const Duration(milliseconds: 120),
    );
    // Only this notifier changes initially: paint feedback without rebuilding
    // the analysis projection or mounting another table/selection registrar.
    _bomLayoutPending.value = aggregate;
    try {
      for (var frame = 0; frame < 2; frame++) {
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
        if (!current()) return;
      }
      if (fade != Duration.zero) await Future<void>.delayed(fade);
      if (!current() ||
          !identical(analysis, _analysis) ||
          scope != _sessionScopeKey()) {
        return;
      }
      if (_bomAggregateByMaterial != aggregate) {
        setState(() {
          // Keep the currently rendered mode authoritative for row actions
          // until the requested presentation is complete.
          _pruneMaterialTableFilters();
        });
      }
      if (analysis != null) await _requestMaterialPresentation(analysis);
      // The replacement lays out under the painted local progress surface.
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      if (mounted && epoch == _bomLayoutTransitionEpoch) {
        _bomLayoutIntentScope = null;
        _bomLayoutPending.value = null;
      }
    }
  }

  Future<void> _requestMaterialPresentation(
    ProductionMaterialAnalysisView analysis,
  );

  Widget _materialViewTransitionBody(
    BuildContext context,
    Widget body, {
    bool Function()? blockPointer,
  }) => AnimatedBuilder(
    animation: Listenable.merge([
      _bomLayoutPending,
      _materialProjectionPending,
    ]),
    child: body,
    builder: (context, child) => UtenMotion(
      duration: const Duration(milliseconds: 120),
      builder: (context, duration) => Stack(
        children: [
          AnimatedOpacity(
            key: const Key('material-view-switch-opacity'),
            opacity: 1,
            duration: duration,
            curve: Curves.easeOut,
            child: AbsorbPointer(
              absorbing: blockPointer?.call() ?? false,
              child: child,
            ),
          ),
          if (_bomLayoutPending.value != null ||
              _materialProjectionPending.value)
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Semantics(
                    key: const Key('material-view-switch-progress'),
                    liveRegion: true,
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(UtenRadius.control),
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: UtenSpacing.s12),
                            Text(_l10n.commonLoading),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _bomToolbarGroupDivider(ThemeData theme, {Key? key}) => Container(
    key: key,
    width: 1,
    height: 24,
    color: theme.colorScheme.outlineVariant,
  );

  /// chip 计数与表格同口径：视图条件 × 关键词 × 表头筛选（产品视图）。
  /// 汇总视图的表头筛选作用于聚合行，chip 仍按节点计数（不含表头筛选）。
  int _bomModeCount(
    ProductionMaterialAnalysisView analysis,
    _BomViewMode mode,
  ) {
    final projection =
        identical(_bomProjectionAnalysis, analysis) &&
            _bomProjectionScope == _sessionScopeKey()
        ? _bomProjectionCache
        : null;
    return projection?.modeCounts[mode] ?? 0;
  }

  /// MAKE_COMPONENT / AGGREGATE_MAKE remain real server-side ownership and
  /// traceability facts. Their real material requirements and plan/progress
  /// stay below the exact source node, rather than becoming extra external
  /// product roots or being hidden after ownership transfers.
  bool _isEmbeddedMakeChildProduct(
    ProductionMaterialAnalysisProduct? product,
  ) =>
      product?.sourceType == 'MAKE_COMPONENT' ||
      product?.sourceType == 'AGGREGATE_MAKE';

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
    return matchesKeywordSearch([
      product?.goodsCode,
      product?.goodsName,
      product?.orderNo,
      material.goodsCode,
      material.goodsName,
      material.spec,
      material.colorName,
    ], _bomKeyword);
  }

  /// BOM 查找：防抖与清除按钮由 UtenSearchBar 内置；关键词变化才重算可见层。
  ///（清除时本回调同样收到空串，与原手写清除按钮行为一致：清词 + 可见层归位。）
  void _bomSearchChanged(String value) {
    final keyword = value.trim().toLowerCase();
    if (keyword == _bomKeyword) return;
    setState(() {
      _bomKeyword = keyword;
    });
  }

  /// 只看缺料/待确认时仍把命中节点的祖先保留下来，员工能看懂它属于哪件产品、
  /// 哪条装配路径；祖先只是定位上下文，不会被误算为缺料或加入批量选择。
  Iterable<void> _visibleBomNodesWork(
    List<ProductionMaterialAnalysisMaterial> nodes, {
    required Map<String, String?> parentIds,
    required Map<String, bool> textMatches,
    required void Function(List<ProductionMaterialAnalysisMaterial>) complete,
  }) sync* {
    if (_bomViewMode == _BomViewMode.all && _bomKeyword.isEmpty) {
      complete(nodes);
      return;
    }
    final byId = <String, ProductionMaterialAnalysisMaterial>{};
    for (final node in nodes) {
      yield null;
      byId[node.materialLineId] = node;
    }
    final visibleIds = <String>{};
    for (final node in nodes) {
      yield null;
      if (!_bomModeMatches(node) || textMatches[node.materialLineId] != true) {
        continue;
      }
      ProductionMaterialAnalysisMaterial? current = node;
      while (current != null && visibleIds.add(current.materialLineId)) {
        yield null;
        current = byId[parentIds[current.materialLineId]];
      }
    }
    final result = <ProductionMaterialAnalysisMaterial>[];
    for (final node in nodes) {
      yield null;
      if (visibleIds.contains(node.materialLineId)) result.add(node);
    }
    complete(result);
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
    assert(() {
      debugMaterialSynchronousAggregateBuilds++;
      return true;
    }());
    late List<_MaterialAggregate> result;
    for (final _ in _materialAggregatesWork(
      analysis,
      indexes,
      (value) => result = value,
    )) {}
    return result;
  }

  Iterable<void> _materialAggregatesWork(
    ProductionMaterialAnalysisView analysis,
    _MaterialAnalysisIndexes indexes,
    void Function(List<_MaterialAggregate>) complete,
  ) sync* {
    final byKey = <String, List<ProductionMaterialAnalysisMaterial>>{};
    final presentation = _bomPresentation(analysis);
    final representedTargets = {
      for (final material in analysis.materials)
        ...?material.aggregatePreparation?.targetMaterialLineIds,
    };
    for (final nodes in presentation.nodesByProduct.values) {
      for (final material in nodes) {
        yield null;
        if (material.isRootSupply || material.level <= 0) continue;
        if (representedTargets.contains(material.materialLineId) &&
            indexes.productsById[material.analysisLineId]?.sourceType ==
                'AGGREGATE_MAKE') {
          continue;
        }
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
    // All aggregate rows refer to the same immutable analysis snapshot. A map
    // per group made switching views allocate groups x material-count entries.
    final materialsById = indexes.materialsById;
    final aggregates = [
      for (final entry in byKey.entries)
        _MaterialAggregate(
          key: entry.key,
          paths: entry.value,
          materialsById: materialsById,
          rootProductIds: {
            for (final material in entry.value)
              if (indexes
                      .productsById[presentation.rootIdsByMaterial[material
                          .materialLineId]]
                      ?.sourceType !=
                  'AGGREGATE_MAKE')
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
    complete(aggregates);
  }

  /// 兄弟行排序:先层级、再货品编号(无编号退货品名、再退行 id)。
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
    roots.sort(_compareBomSiblings);
    for (final values in children.values) {
      values.sort(_compareBomSiblings);
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
          ..sort(_compareBomSiblings);
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

  // ===== 整树展开/收起（2026-10-08 用户口径，右键菜单入口） =====
  //
  // 全部展开 = 每个产品都展开子层级（产品折叠与分支折叠一并清空）；
  // 全部收起 = 只显示顶层产品行。汇总视图对应聚合行的来源明细展开/收起。
  // 纯本地展示状态，不触服务端，.busy 期间也可用。

  void _expandAllBomNodes() {
    final analysis = _analysis;
    if (analysis == null) return;
    setState(() {
      if (_bomAggregateByMaterial) {
        _expandedMaterialAggregates.addAll(
          _displayedMaterialAggregates(
            analysis,
          ).map((aggregate) => aggregate.key),
        );
      } else {
        _collapsedBomProducts.clear();
        _collapsedBomBranches.clear();
      }
    });
  }

  void _collapseAllBomNodes() {
    final analysis = _analysis;
    if (analysis == null) return;
    setState(() {
      if (_bomAggregateByMaterial) {
        _expandedMaterialAggregates.clear();
      } else {
        for (final product in analysis.products) {
          if (!_isEmbeddedMakeChildProduct(product)) {
            _collapsedBomProducts.add(product.analysisLineId);
          }
        }
        // Reopening one level (including Ctrl + click) must not revive an
        // implicitly open grandchild after the user collapsed the whole tree.
        _collapsedBomBranches.addAll(
          _bomPresentation(
            analysis,
          ).parentIdsByMaterial.values.whereType<String>(),
        );
      }
    });
  }

  /// 行右键菜单尾部的整树展开/收起两项；挂在每一条能弹菜单的行上，
  /// 计划员在哪行右键都能顺手收起整棵树。
  List<UtenContextMenuEntry> _bomExpansionMenuEntries() => [
    UtenMenuItem(
      label: _bomAggregateByMaterial ? '全部展开来源' : '全部展开',
      icon: Icons.unfold_more_rounded,
      onTap: _expandAllBomNodes,
    ),
    UtenMenuItem(
      label: _bomAggregateByMaterial ? '全部收起来源' : '全部收起',
      icon: Icons.unfold_less_rounded,
      onTap: _collapseAllBomNodes,
    ),
  ];

  /// 生产准备任务卡右上角的「全部展开/全部收起」按钮（动作与右键菜单同源，
  /// 2026-10-08 用户口径：比逐行右键顺手）。还有收起空间时显示「全部展开」，
  /// 整树已全展开时显示「全部收起」；纯文字无图标。
  @override
  Widget? _bomTreeExpansionToggle() {
    final analysis = _analysis;
    if (analysis == null || analysis.materials.isEmpty) return null;
    if (_bomAggregateByMaterial) {
      final aggregates = _displayedMaterialAggregates(analysis);
      if (aggregates.isEmpty) return null;
      final expandedAll =
          _expandedMaterialAggregates.length >= aggregates.length;
      return _bomTreeExpansionToggleButton(expandedAll);
    }
    final anyCollapsed =
        _collapsedBomProducts.isNotEmpty || _collapsedBomBranches.isNotEmpty;
    return _bomTreeExpansionToggleButton(!anyCollapsed);
  }

  List<_MaterialAggregate> _displayedMaterialAggregates(
    ProductionMaterialAnalysisView analysis,
  );

  Widget _bomTreeExpansionToggleButton(bool expanded) =>
      UtenTreeExpansionButton(
        key: const Key('material-analysis-bom-expansion-toggle'),
        expanded: expanded,
        onExpand: _expandAllBomNodes,
        onCollapse: _collapseAllBomNodes,
      );

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
  String _materialTableProjectionSignature(bool aggregate);

  Iterable<void> _materialTableFacetsWork(
    Iterable<_MaterialTableRow> rows,
    void Function(Map<String, List<MasterFacetBucket>>) complete,
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
    final cacheKey = _bomProjectionCacheKey();
    if (identical(_bomProjectionAnalysis, analysis) &&
        _bomProjectionScope == _sessionScopeKey() &&
        _bomProjectionKey == cacheKey &&
        _bomProjectionCache != null) {
      return _bomProjectionCache!;
    }
    late _BomFilterProjection projection;
    for (final _ in _bomFilterProjectionWork(
      analysis,
      _bomAggregateByMaterial,
      (value) => projection = value,
    )) {}
    _bomProjectionAnalysis = analysis;
    _bomProjectionScope = _sessionScopeKey();
    _bomProjectionKey = cacheKey;
    _bomProjectionCache = projection;
    return projection;
  }

  String _bomProjectionCacheKey() => [
    _bomViewMode.name,
    _bomKeyword,
    _materialTableProjectionSignature(_bomAggregateByMaterial),
  ].join('\u0000');

  Iterable<void> _bomFilterProjectionWork(
    ProductionMaterialAnalysisView analysis,
    bool aggregate,
    void Function(_BomFilterProjection) complete,
  ) sync* {
    final indexes = _analysisIndexes(analysis);
    final presentation = _bomPresentation(analysis);
    final headerFilterActive = _hasActiveMaterialTableFilters && !aggregate;
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
      yield null;
      final product = indexes.productsById[entry.key];
      final ownsProductRow =
          product != null &&
          (product.sourceType == 'AGGREGATE_MAKE' ||
              !_isEmbeddedMakeChildProduct(product));
      bool textMatches(ProductionMaterialAnalysisMaterial material) =>
          _bomTextMatches(material, product) ||
          _bomTextMatches(
            material,
            indexes.productsById[material.analysisLineId],
          );
      final textMatchesById = <String, bool>{};
      for (final material in entry.value) {
        yield null;
        final matched = textMatches(material);
        textMatchesById[material.materialLineId] = matched;
        if (_bomModeMatches(material) && matched) directMatches++;
      }
      late List<ProductionMaterialAnalysisMaterial> base;
      yield* _visibleBomNodesWork(
        entry.value,
        parentIds: presentation.parentIdsByMaterial,
        textMatches: textMatchesById,
        complete: (value) => base = value,
      );
      // 探针行：产品行承载根供料节点；其余节点各自一行。全量节点都建探针，
      // chip 计数（其它视图）才能与表头筛选同口径。
      final productRow = ownsProductRow
          ? _probeProductRow(product, indexes)
          : null;
      final rootId = productRow?.material?.materialLineId;
      final probeByNode = <String, _MaterialTableRow>{};
      for (final node in entry.value) {
        yield null;
        if (node.materialLineId != rootId) {
          probeByNode[node.materialLineId] = _probeMaterialRow(node, indexes);
        }
      }
      bool headerMatches(ProductionMaterialAnalysisMaterial node) {
        if (!headerFilterActive) return true;
        if (node.materialLineId == rootId) {
          return productRow == null || _headerFilterMatchesRow(productRow);
        }
        final probe = probeByNode[node.materialLineId];
        return probe == null || _headerFilterMatchesRow(probe);
      }

      for (final node in entry.value) {
        yield null;
        nodeMatchesFilters[node.materialLineId] =
            textMatchesById[node.materialLineId] == true && headerMatches(node);
      }
      if (base.isEmpty) continue;
      // 桶：当前视图基础可见层（产品行 + 非根节点），不含表头筛选本身。
      if (productRow != null) facetRows.add(productRow);
      for (final node in base) {
        yield null;
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
          yield null;
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
    final modeCounts = {for (final mode in _BomViewMode.values) mode: 0};
    for (final nodes in presentation.nodesByProduct.values) {
      for (final material in nodes) {
        yield null;
        if (!(nodeMatchesFilters[material.materialLineId] ?? true)) continue;
        modeCounts[_BomViewMode.all] = modeCounts[_BomViewMode.all]! + 1;
        if (material.shortageQty > 0) {
          modeCounts[_BomViewMode.shortage] =
              modeCounts[_BomViewMode.shortage]! + 1;
          if (material.confirmedRoute == null) {
            modeCounts[_BomViewMode.unconfirmed] =
                modeCounts[_BomViewMode.unconfirmed]! + 1;
          }
        }
      }
    }
    late Map<String, List<MasterFacetBucket>> facets;
    yield* _materialTableFacetsWork(facetRows, (value) => facets = value);
    final projection = _BomFilterProjection(
      nodesByProduct: nodesByProduct,
      modeCounts: modeCounts,
      directMatchCount: directMatches,
      visibleNodeCount: visibleNodes,
      presentation: presentation,
      visibleProductIds: visibleProductIds,
      contextOnlyProductIds: contextOnlyProductIds,
      contextOnlyMaterialIds: contextOnlyMaterialIds,
      nodeMatchesFilters: nodeMatchesFilters,
      facets: facets,
    );
    complete(projection);
  }
}
