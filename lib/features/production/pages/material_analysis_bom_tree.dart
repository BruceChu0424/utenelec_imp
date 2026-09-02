part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisBomTreeState
    extends _MaterialAnalysisProductTasksState {
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

  /// 统一树顶部的批量选择栏：按路线（采购/委外/自制）全选当前可执行缺料。
  Widget _unifiedBomTreeHeader(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    final chips = <Widget>[];
    for (final route in MaterialSupplyRoute.values) {
      final executable = _executableSupplyGroups(route);
      if (executable.isEmpty) continue;
      final selected = _selectedSupplyGroups[route]!;
      final selectedCount = executable
          .where((group) => selected.contains(group.key))
          .length;
      chips.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: Checkbox(
                key: Key('material-route-select-all-${route.wireName}'),
                tristate: true,
                value: _supplyHeaderValue(route),
                onChanged: !_canNotify || _busy
                    ? null
                    : (value) => _toggleAllSupplyGroups(route, value == true),
              ),
            ),
            _typeBadge(theme, route),
            const SizedBox(width: UtenSpacing.s4),
            Text(
              '${route.label}缺料 ${executable.length} · 已选 $selectedCount',
              style: theme.textTheme.bodySmall?.copyWith(
                color: _routeColor(theme, route),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    final projection = _bomFilterProjection(analysis);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 300,
                child: UtenSearchBar(
                  key: const Key('material-bom-search'),
                  controller: _bomSearch,
                  hint: '查找产品或物料',
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
                    _bomProductVisibleLimit =
                        _MaterialAnalysisPageBase._bomProductPageSize;
                  }),
                  label: '${mode.label} ${_bomModeCount(analysis, mode)}',
                ),
              // 排布切换：按产品看 BOM 树（默认）/ 按物料汇总缺料。
              // 多产品联合分析时物料行非常多，按物料汇总把同一物料跨产品
              // 聚成一行，是给采购/委外下单用的决策视图；任务身份不合并。
              _bomViewChip(
                theme,
                key: const ValueKey('material-bom-layout-product'),
                selected: !_bomAggregateByMaterial,
                onSelected: _bomAggregateByMaterial
                    ? () => setState(() => _bomAggregateByMaterial = false)
                    : null,
                label: '按产品看',
              ),
              _bomViewChip(
                theme,
                key: const ValueKey('material-bom-layout-material'),
                selected: _bomAggregateByMaterial,
                onSelected: _bomAggregateByMaterial
                    ? null
                    : () => setState(() => _bomAggregateByMaterial = true),
                label: '按物料汇总',
              ),
              Text(
                '筛选命中 ${projection.directMatchCount} 条；保留上级后共 '
                '${projection.visibleNodeCount} 条 / 全部 '
                '${_bomModeCount(analysis, _BomViewMode.all)} 条',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            const Divider(height: 1),
            const SizedBox(height: UtenSpacing.s4),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '批量选择(整次分析)',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                ...chips,
              ],
            ),
          ],
        ],
      ),
    );
  }

  int _bomModeCount(
    ProductionMaterialAnalysisView analysis,
    _BomViewMode mode,
  ) {
    final indexes = _analysisIndexes(analysis);
    var count = 0;
    for (final entry in indexes.materialsByProduct.entries) {
      final product = entry.key == null
          ? null
          : indexes.productsById[entry.key];
      if (_isEmbeddedMakeChildProduct(product)) continue;
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

  /// MAKE_COMPONENT remains a real server-side ownership and traceability
  /// fact, but it is not a second top-level BOM requested by the planner.
  /// Its plan/progress stays inline on the original MAKE node.
  bool _isEmbeddedMakeChildProduct(
    ProductionMaterialAnalysisProduct? product,
  ) => product?.sourceType == 'MAKE_COMPONENT';

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
      _bomProductVisibleLimit = _MaterialAnalysisPageBase._bomProductPageSize;
    });
  }

  /// 只看缺料/待确认时仍把命中节点的祖先保留下来，员工能看懂它属于哪件产品、
  /// 哪条装配路径；祖先只是定位上下文，不会被误算为缺料或加入批量选择。
  List<ProductionMaterialAnalysisMaterial> _visibleBomNodes(
    List<ProductionMaterialAnalysisMaterial> nodes,
    ProductionMaterialAnalysisProduct? product,
  ) {
    if (_bomViewMode == _BomViewMode.all && _bomKeyword.isEmpty) return nodes;
    final byNodeKey = <String, ProductionMaterialAnalysisMaterial>{
      for (final node in nodes)
        if (node.nodeKey?.isNotEmpty == true) node.nodeKey!: node,
    };
    final visibleIds = <String>{};
    for (final node in nodes) {
      if (!_bomModeMatches(node) || !_bomTextMatches(node, product)) continue;
      ProductionMaterialAnalysisMaterial? current = node;
      while (current != null && visibleIds.add(current.materialLineId)) {
        final parentKey = current.parentNodeKey;
        current = parentKey == null ? null : byNodeKey[parentKey];
      }
    }
    return nodes
        .where((node) => visibleIds.contains(node.materialLineId))
        .toList(growable: false);
  }

  Color _routeColor(ThemeData theme, MaterialSupplyRoute? route) =>
      switch (route) {
        MaterialSupplyRoute.make => theme.colorScheme.primary,
        MaterialSupplyRoute.buy => theme.colorScheme.tertiary,
        MaterialSupplyRoute.subcontract => theme.colorScheme.secondary,
        null => theme.colorScheme.error,
      };

  Widget _bomTreeSliver(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    if (_bomAggregateByMaterial) {
      return _materialAggregateSliver(theme, analysis);
    }
    final indexes = _analysisIndexes(analysis);
    final groupByLine = indexes.groupsByLine;
    final projection = _bomFilterProjection(analysis);
    final entries = <_BomTreeEntry>[];
    final matchingProducts = [
      for (final product in analysis.products)
        if (!_isEmbeddedMakeChildProduct(product) &&
            projection.nodesByProduct[product.analysisLineId]?.isNotEmpty ==
                true)
          product,
    ];
    final visibleProducts = matchingProducts
        .take(_bomProductVisibleLimit)
        .toList(growable: false);
    for (final product in visibleProducts) {
      final nodes = projection.nodesByProduct[product.analysisLineId]!;
      entries.add(_BomProductEntry(product));
      if (_collapsedBomProducts.contains(product.analysisLineId)) continue;
      final parentKeys = {
        for (final node in nodes)
          if (node.parentNodeKey?.isNotEmpty == true) node.parentNodeKey!,
      };
      for (final material in _orderedBomNodes(nodes)) {
        final group = groupByLine[material.materialLineId];
        if (group == null) continue;
        entries.add(
          _BomMaterialEntry(
            material,
            group,
            parentKeys.contains(material.nodeKey),
          ),
        );
      }
    }
    final remainingProducts = matchingProducts.length - visibleProducts.length;
    if (remainingProducts > 0) {
      entries.add(_BomLoadMoreEntry(remainingProducts));
    }
    final knownProductIds = analysis.products
        .map((product) => product.analysisLineId)
        .toSet();
    final unassigned = [
      for (final entry in projection.nodesByProduct.entries)
        if (entry.key == null || !knownProductIds.contains(entry.key))
          ...entry.value,
    ];
    if (unassigned.isNotEmpty) {
      entries.add(const _BomOrphanEntry());
      final parentKeys = {
        for (final node in unassigned)
          if (node.parentNodeKey?.isNotEmpty == true) node.parentNodeKey!,
      };
      for (final material in _orderedBomNodes(unassigned)) {
        final group = groupByLine[material.materialLineId];
        if (group != null) {
          entries.add(
            _BomMaterialEntry(
              material,
              group,
              parentKeys.contains(material.nodeKey),
            ),
          );
        }
      }
    }
    if (entries.isEmpty) entries.add(const _BomEmptyEntry());
    return SliverList(
      key: const Key('material-bom-tree'),
      delegate: SliverChildBuilderDelegate((_, index) {
        final entry = entries[index];
        return switch (entry) {
          _BomEmptyEntry() => _bomEmptyState(theme),
          _BomProductEntry(:final product) => _bomProductRoot(theme, product),
          _BomOrphanEntry() => _bomOrphanHeader(theme),
          _BomLoadMoreEntry(:final remainingProducts) => _bomLoadMore(
            theme,
            remainingProducts,
          ),
          _BomMaterialEntry(
            :final material,
            :final group,
            :final hasChildren,
          ) =>
            _unifiedBomNodeRow(
              theme,
              material,
              group,
              hasChildren: hasChildren,
            ),
        };
      }, childCount: entries.length),
    );
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
    final goods =
        material.goodsId ??
        'CODE|${material.goodsCode ?? material.goodsName ?? material.materialLineId}';
    return '$goods|${material.colorId ?? material.colorName ?? ''}'
        '|${material.unitId ?? material.unitName ?? ''}';
  }

  List<_MaterialAggregate> _materialAggregates(
    ProductionMaterialAnalysisView analysis,
    _MaterialAnalysisIndexes indexes,
  ) {
    final byKey = <String, List<ProductionMaterialAnalysisMaterial>>{};
    for (final material in analysis.materials) {
      if (!_bomModeMatches(material)) continue;
      final product = indexes.productsById[material.analysisLineId];
      if (_isEmbeddedMakeChildProduct(product)) continue;
      if (!_bomTextMatches(material, product)) continue;
      byKey.putIfAbsent(_aggregateKeyOf(material), () => []).add(material);
    }
    final aggregates = [
      for (final entry in byKey.entries)
        _MaterialAggregate(key: entry.key, paths: entry.value),
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

  Widget _materialAggregateSliver(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    final indexes = _analysisIndexes(analysis);
    final aggregates = _materialAggregates(analysis, indexes);
    if (aggregates.isEmpty) {
      return SliverToBoxAdapter(
        child: Container(
          key: const Key('material-aggregate-empty'),
          margin: const EdgeInsets.only(top: UtenSpacing.s8),
          padding: const EdgeInsets.all(UtenSpacing.s20),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
            borderRadius: UtenRadius.mdAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              const Expanded(child: Text('当前筛选下没有缺料物料。可切换「全部 BOM」或清除查找。')),
            ],
          ),
        ),
      );
    }
    return SliverList(
      key: const Key('material-aggregate-list'),
      delegate: SliverChildBuilderDelegate((_, index) {
        if (index == 0) {
          return _materialAggregateIntro(theme, aggregates.length);
        }
        return _materialAggregateRow(theme, aggregates[index - 1], indexes);
      }, childCount: aggregates.length + 1),
    );
  }

  Widget _materialAggregateIntro(ThemeData theme, int count) => Container(
    key: const Key('material-aggregate-intro'),
    margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.summarize_outlined, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            '按物料汇总：共 $count 种物料。同一物料在多个产品里的缺口合成一行，'
            '缺口最大的排最前；点展开能看到每个产品各要多少。'
            '勾选和提交仍按每条装配路径分别记账，不会重复领料。',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        ),
      ],
    ),
  );

  Widget _materialAggregateRow(
    ThemeData theme,
    _MaterialAggregate aggregate,
    _MaterialAnalysisIndexes indexes,
  ) {
    final expanded = _expandedMaterialAggregates.contains(aggregate.key);
    final hasActiveRequirement = aggregate.totalRequired > 0;
    final ratio = aggregate.coverageRatio;
    final hasShortage = hasActiveRequirement && aggregate.totalShortage > 0;
    final hasDemandGap =
        hasActiveRequirement && aggregate.totalDemandSupplyGap > 0;
    final route = aggregate.uniformSuggestion;
    final barColor = !hasDemandGap
        ? theme.colorScheme.primary
        : ratio <= 0
        ? theme.colorScheme.error
        : theme.colorScheme.tertiary;
    return Container(
      key: ValueKey('material-aggregate-${aggregate.key}'),
      margin: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: hasShortage
            ? theme.colorScheme.error.withValues(alpha: 0.08)
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: hasShortage
              ? theme.colorScheme.error.withValues(alpha: 0.5)
              : theme.colorScheme.outlineVariant,
          width: hasShortage ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                key: ValueKey('material-aggregate-toggle-${aggregate.key}'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: expanded ? '收起各产品明细' : '展开各产品明细',
                onPressed: () => setState(() {
                  if (!_expandedMaterialAggregates.add(aggregate.key)) {
                    _expandedMaterialAggregates.remove(aggregate.key);
                  }
                }),
                icon: Icon(
                  expanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${aggregate.goodsName ?? aggregate.goodsCode ?? '未命名物料'}'
                      '${aggregate.spec?.isNotEmpty == true ? '(${aggregate.spec})' : ''}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      [
                        aggregate.goodsCode,
                        aggregate.colorName,
                        aggregate.unitName == null
                            ? null
                            : '单位 ${aggregate.unitName}',
                      ].whereType<String>().join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (route != null)
                _typeBadge(theme, route)
              else
                Tooltip(
                  message: '各路径的建议或确认路线不一致，展开后逐条查看',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s8,
                      vertical: UtenSpacing.s4,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: UtenRadius.smAll,
                      border: Border.all(color: theme.colorScheme.outline),
                    ),
                    child: Text(
                      '路线不一',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Wrap(
            spacing: UtenSpacing.s16,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (hasActiveRequirement)
                _semanticFact(
                  '本批总需求 ${_qty(aggregate.totalRequired)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (hasActiveRequirement || aggregate.warehouseStock > 0)
                _semanticFact(
                  '公共现货 ${_qty(aggregate.warehouseStock)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: hasActiveRequirement && aggregate.warehouseStock <= 0
                        ? theme.colorScheme.error
                        : null,
                    fontWeight:
                        hasActiveRequirement && aggregate.warehouseStock <= 0
                        ? FontWeight.w700
                        : FontWeight.normal,
                  ),
                ),
              if (hasActiveRequirement)
                _semanticFact(
                  '合格库存保障 ${_qty(aggregate.qualifiedCoveredQty)}/'
                  '${_qty(aggregate.totalRequired)}'
                  '(${(ratio * 100).toStringAsFixed(0)}%)',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: hasDemandGap && ratio <= 0
                        ? theme.colorScheme.error
                        : barColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (!hasActiveRequirement)
                _semanticFact(
                  '当前无激活需求，展开查看各路径原因',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              _semanticFact(
                '${aggregate.productCount} 个产品路径',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (hasActiveRequirement) ...[
            const SizedBox(height: UtenSpacing.s12),
            Semantics(
              container: true,
              label:
                  '合格库存保障 ${_qty(aggregate.qualifiedCoveredQty)}/'
                  '${_qty(aggregate.totalRequired)}，'
                  '百分之${(ratio * 100).toStringAsFixed(0)}',
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: UtenRadius.smAll,
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 10,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation<Color>(barColor),
                        ),
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      '保障 ${(ratio * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: hasDemandGap && ratio <= 0
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (expanded) ...[
            const SizedBox(height: UtenSpacing.s8),
            const Divider(height: 1),
            for (final material in aggregate.paths)
              _materialAggregatePathRow(theme, material, indexes),
          ],
        ],
      ),
    );
  }

  /// 汇总行展开后的单条 BOM 路径：哪个产品、哪个父件要这件料、要多少、
  /// 缺多少。选择控件与 BOM 树完全同款，路线确认、下层齐套、权限等
  /// 门禁一处生效，两处一致。
  Widget _materialAggregatePathRow(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialAnalysisIndexes indexes,
  ) {
    final group = indexes.groupsByLine[material.materialLineId];
    if (group == null) return const SizedBox.shrink();
    final product = indexes.productsById[material.analysisLineId];
    final route = _routeDraft[group.key] ?? material.sourceSuggestion;
    final selected =
        route != null &&
        (_selectedSupplyGroups[route]?.contains(group.key) ?? false);
    final status = _materialStatus(theme, group);
    final foreground = selected ? Colors.white : null;
    final coverage = _coverageOf(material);
    final requirementView = coverage == null
        ? _requirementStateView(theme, material)
        : null;
    final delegated =
        material.effectiveRequirementState ==
        MaterialRequirementState.delegatedToMakeChild;
    final delegatedOwner = _delegatedOwnerLabel(material);
    final delegatedChildStatus = _delegatedChildStatusLabel(material);
    final pathFacts = <Widget>[
      if (coverage != null)
        _semanticFact(
          '本批需求 ${_qty(material.requiredQty)}',
          style: TextStyle(color: foreground),
        ),
      if (coverage != null)
        _semanticFact(
          '合格库存保障 ${_qty(coverage.covered)}/'
          '${_qty(material.requiredQty)}'
          '(${(coverage.ratio * 100).toStringAsFixed(0)}%)',
          style: TextStyle(
            color: selected
                ? Colors.white
                : _coverageColor(theme, material, coverage.ratio),
            fontWeight: FontWeight.w700,
          ),
        ),
      if (requirementView != null)
        _semanticFact(
          requirementView.detail,
          style: TextStyle(
            color: selected
                ? Colors.white70
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      if (delegated && material.delegatedToRequestedQty != null)
        _semanticFact(
          '接管子任务总需求 ${_qty(material.delegatedToRequestedQty)}',
          style: TextStyle(
            color: selected ? Colors.white : theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      if (delegated && delegatedOwner != null)
        _semanticFact(
          '接管来源 $delegatedOwner',
          style: TextStyle(
            color: selected ? Colors.white : theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      if (material.subcontractHandoffFutureQty > 0)
        _semanticFact(
          '委外前置自制已接管供给 ${_qty(material.subcontractHandoffFutureQty)}',
          style: TextStyle(
            color: selected ? Colors.white : theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      if (delegatedChildStatus != null)
        _semanticFact(
          '接管子任务状态 $delegatedChildStatus',
          key: ValueKey(
            'material-aggregate-delegated-child-status-${material.materialLineId}',
          ),
          style: TextStyle(
            color: selected ? Colors.white : theme.colorScheme.secondary,
            fontWeight: FontWeight.w700,
          ),
        ),
    ];
    return Container(
      key: ValueKey('material-aggregate-path-${material.materialLineId}'),
      margin: const EdgeInsets.only(top: UtenSpacing.s12),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: selected
            ? UtenColors.deepGreen
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.smAll,
        border: Border.all(
          color: selected
              ? UtenColors.deepGreen
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _routeStateCell(
                theme,
                material,
                group,
                route,
                selected: selected,
              ),
              const SizedBox(width: UtenSpacing.s4),
              SizedBox(
                width: 48,
                height: 48,
                child: group.actionable
                    ? _nodeSelectionControl(
                        theme,
                        material,
                        group,
                        route,
                        selected,
                      )
                    : null,
              ),
              const SizedBox(width: UtenSpacing.s4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product?.goodsName ?? product?.goodsCode ?? '未归属产品',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '路径：${_pathLabel(material)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foreground ?? theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _nodeDetailsToggle(theme, group, foreground: foreground),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s16,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...pathFacts,
              // 已下达供给任务的路径状态可点：弹出供给全链路进度。
              if (_notifiedTargetOf(material) != null)
                InkWell(
                  key: ValueKey(
                    'material-supply-progress-${material.materialLineId}',
                  ),
                  borderRadius: UtenRadius.smAll,
                  onTap: () => _showSupplyProgress(group),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _statusLabel(
                        theme,
                        selected
                            ? _StatusView(
                                status.label,
                                status.icon,
                                Colors.white,
                              )
                            : status,
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.open_in_new_rounded,
                        size: 14,
                        color: selected ? Colors.white : status.color,
                      ),
                    ],
                  ),
                )
              else
                _statusLabel(
                  theme,
                  selected
                      ? _StatusView(status.label, status.icon, Colors.white)
                      : status,
                ),
            ],
          ),
          _borrowBadges(theme, material, selected: selected),
          if (_expandedPathGroups.contains(group.key))
            _nodeDetails(theme, group),
        ],
      ),
    );
  }

  Widget _bomEmptyState(ThemeData theme) => Container(
    key: const Key('material-bom-empty-filter'),
    margin: const EdgeInsets.only(top: UtenSpacing.s8),
    padding: const EdgeInsets.all(UtenSpacing.s20),
    decoration: BoxDecoration(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Row(
      children: [
        Icon(
          Icons.check_circle_outline_rounded,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: UtenSpacing.s8),
        const Expanded(child: Text('当前条件下没有物料任务。可切换“全部”或清除查找查看完整 BOM。')),
      ],
    ),
  );

  Widget _bomLoadMore(ThemeData theme, int remainingProducts) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
    child: Align(
      child: OutlinedButton.icon(
        key: const Key('material-bom-show-more-products'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(240, 52),
          textStyle: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        onPressed: () => setState(
          () => _bomProductVisibleLimit +=
              _MaterialAnalysisPageBase._bomProductPageSize,
        ),
        icon: const Icon(Icons.expand_more_rounded),
        label: Text('继续显示下一批产品(还有 $remainingProducts 个)'),
      ),
    ),
  );

  Widget _bomOrphanHeader(ThemeData theme) => Container(
    constraints: const BoxConstraints(minHeight: 52),
    margin: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.4)),
    ),
    child: Row(
      children: [
        Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
        const SizedBox(width: UtenSpacing.s8),
        const Expanded(child: Text('未归属产品的 BOM 节点，请检查分析数据')),
      ],
    ),
  );

  List<ProductionMaterialAnalysisMaterial> _orderedBomNodes(
    List<ProductionMaterialAnalysisMaterial> nodes,
  ) {
    final byNodeKey = <String, ProductionMaterialAnalysisMaterial>{
      for (final node in nodes)
        if (node.nodeKey?.isNotEmpty == true) node.nodeKey!: node,
    };
    final children = <String, List<ProductionMaterialAnalysisMaterial>>{};
    final roots = <ProductionMaterialAnalysisMaterial>[];
    for (final node in nodes) {
      final parentKey = node.parentNodeKey;
      if (parentKey == null ||
          parentKey.isEmpty ||
          parentKey == node.nodeKey ||
          !byNodeKey.containsKey(parentKey)) {
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
      final key = node.nodeKey;
      if (key == null) return;
      for (final child
          in children[key] ?? const <ProductionMaterialAnalysisMaterial>[]) {
        hide(child);
      }
    }

    void visit(ProductionMaterialAnalysisMaterial node) {
      if (!visited.add(node.materialLineId)) return;
      result.add(node);
      final key = node.nodeKey;
      if (key == null) return;
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

  Widget _bomProductRoot(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product,
  ) {
    final collapsed = _collapsedBomProducts.contains(product.analysisLineId);
    final subcontractPreparation =
        product.sourceType == 'SUBCONTRACT_PREPARATION';
    final executionStage = _productExecutionStage(product);
    final productShortStatus = executionStage?.label;
    final productLabel = product.goodsName ?? product.goodsCode ?? '未命名产品';
    final identitySemantics = [
      productLabel,
      if (subcontractPreparation) '委外前置自制目标件',
      ?productShortStatus,
    ].join('，');
    return Container(
      key: ValueKey('material-bom-product-${product.analysisLineId}'),
      constraints: const BoxConstraints(minHeight: 72),
      margin: const EdgeInsets.only(
        top: UtenSpacing.s12,
        bottom: UtenSpacing.s8,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton(
              key: ValueKey(
                'material-bom-product-toggle-${product.analysisLineId}',
              ),
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              tooltip: collapsed ? '展开该产品 BOM' : '折叠该产品 BOM',
              onPressed: () =>
                  _toggleBomProductCollapsed(product.analysisLineId),
              icon: Icon(
                collapsed
                    ? Icons.chevron_right_rounded
                    : Icons.expand_more_rounded,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            child: Icon(
              subcontractPreparation
                  ? Icons.precision_manufacturing_outlined
                  : Icons.inventory_2_outlined,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Semantics(
              container: true,
              label: identitySemantics,
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      productLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (subcontractPreparation ||
                        productShortStatus != null) ...[
                      const SizedBox(height: UtenSpacing.s4),
                      Wrap(
                        spacing: UtenSpacing.s4,
                        runSpacing: UtenSpacing.s4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (subcontractPreparation)
                            KeyedSubtree(
                              key: ValueKey(
                                'material-bom-product-kind-${product.analysisLineId}',
                              ),
                              child: _miniBadge(
                                theme,
                                label: '委外前置自制',
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          if (productShortStatus != null)
                            KeyedSubtree(
                              key: ValueKey(
                                'material-bom-product-status-${product.analysisLineId}',
                              ),
                              child: _miniBadge(
                                theme,
                                label: productShortStatus,
                                color: executionStage == null
                                    ? theme.colorScheme.primary
                                    : _productExecutionColor(
                                        theme,
                                        executionStage,
                                        selected: false,
                                      ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// BOM 节点卡（紧凑版式）。固定为「左状态栏 + 中内容区 + 右操作区」：
  ///
  /// - 左侧 44px 状态栏整卡等高：顶部路线状态图标，下面一条加粗的竖向
  ///   备料进度条（自底向上填充；悬停出 Tooltip、点按浮出数字进度，
  ///   点其它位置消失）；内容区再高也不侵入状态栏。
  /// - 中内容区两行：①标题行——路线角标 + 标题（独占一行不被挤压，过长
  ///   省略号）+ 右侧「层级 N · 编号 · 颜色」（层级按层着色）与「详情」；
  ///   ②数量行——本批需求 / 合格库存保障 / 现货 / MAKE 执行事实 +
  ///   requirementState 权威状态，右端是选择框（门禁图标同位）。
  /// - 右操作区整卡等高：唯一主动作（采用建议/提交/继续提交…）撑满卡高，
  ///   与内容区以竖分隔线分开；无动作时整区不出现。
  /// - 层级用「整卡左缩进阶梯 + 状态栏竖线 + 层级 N 文字色」三处冗余
  ///   表达，替代旧版行内缩进 + 色带（旧版把内容挤得很乱）。
  Widget _unifiedBomNodeRow(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group, {
    required bool hasChildren,
  }) {
    final route = _routeDraft[group.key] ?? material.sourceSuggestion;
    final actionable = group.actionable;
    final selected =
        route != null &&
        (_selectedSupplyGroups[route]?.contains(group.key) ?? false);
    final status = _materialStatus(theme, group);
    final displayStatus = selected
        ? _StatusView(status.label, status.icon, Colors.white)
        : status;
    final shortage = material.shortageQty > 0;
    final notified = _notifiedTargetOf(material);
    final makeChild = _makeChildProductOf(material);
    final makeExecutionStage = makeChild == null
        ? null
        : _productExecutionStage(makeChild);
    final hasMakePlanFacts =
        makeChild != null && _hasPlanExecutionFacts(makeChild);
    final hasUnfinishedMakeTask =
        notified?.target == MaterialSupplyRoute.make &&
        makeExecutionStage?.status != 'COMPLETED';
    // 备货完成（本批需求被现货/合格入库全覆盖）的节点收成单行紧凑卡：
    // [路线][层级 N] 名称（编号） …… [备货完成]，整卡浅绿成功态。
    // 未完成 MAKE child 必须保持展开，同时展示库存覆盖和真实执行状态；已完工
    // 后可收成紧凑卡，但紧凑卡仍须保留供给流程、执行事实和生产计划深链。
    if (material.requiredQty > 0 &&
        material.shortageQty <= 0 &&
        !hasUnfinishedMakeTask) {
      return _stockedNodeCollapsedCard(
        theme,
        material,
        group,
        route,
        hasChildren: hasChildren,
      );
    }
    final warehouseStock = _selectedWarehouseStock(material);
    final exactPeggedQty = material.exactPeggedQty;
    final publicAvailableQty =
        warehouseStock?.publicAvailableQty ?? material.availableQty;
    final openSafetySupplyQty = warehouseStock?.openSafetySupplyQty ?? 0;
    final safetyReplenishmentGapQty =
        warehouseStock?.safetyReplenishmentGapQty ?? 0;
    final foreground = selected ? Colors.white : null;
    final onSurfaceVar = selected
        ? Colors.white70
        : theme.colorScheme.onSurfaceVariant;
    final coverage = _coverageOf(material);
    final coverageColor = coverage == null
        ? null
        : selected
        ? Colors.white
        : _coverageColor(theme, material, coverage.ratio);
    final requirementView = coverage == null
        ? _requirementStateView(theme, material)
        : null;
    final delegated =
        material.effectiveRequirementState ==
        MaterialRequirementState.delegatedToMakeChild;
    final delegatedChildStatus = _delegatedChildStatusLabel(material);
    // 标题 = 物料名（编号）；规格/颜色收进右侧元信息。
    final title = material.goodsName ?? material.goodsCode ?? '未命名物料';
    final titleWithCode =
        material.goodsName != null && material.goodsCode != null
        ? '${material.goodsName}(${material.goodsCode})'
        : title;
    final branchCollapsed =
        material.nodeKey != null &&
        _collapsedBomBranches.contains(material.nodeKey);
    final action = _nodePrimaryAction(theme, group, route, selected: selected);
    // 路线操作移到右操作区：主动作在上、「更换路线」在下（已确认路线显深绿）。
    final routeButton = _nodeRouteButton(
      theme,
      group,
      route,
      selected: selected,
    );
    // 已下达供给任务的节点：状态文字可点，弹出全链路进度（下单/财务/收货/质检/入库）。
    final supplyNotified = notified != null;
    Widget statusWidget = _statusLabel(theme, displayStatus);
    if (supplyNotified) {
      statusWidget = InkWell(
        key: ValueKey('material-supply-progress-${material.materialLineId}'),
        borderRadius: UtenRadius.smAll,
        onTap: _busy ? null : () => _showSupplyProgress(group),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: statusWidget),
              const SizedBox(width: 2),
              Icon(
                Icons.open_in_new_rounded,
                size: 14,
                color: displayStatus.color,
              ),
            ],
          ),
        ),
      );
    }
    final peeking =
        coverage != null && _progressPeekLineId == material.materialLineId;
    // 右侧元信息：规格 · 颜色（层级徽章已挪到标题行，编号并入标题）。
    // 宽屏在标题右侧，窄屏挪进数量行。
    final metaParts = [
      material.spec,
      material.colorName,
    ].whereType<String>().toList(growable: false);
    final metaText = metaParts.isEmpty
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  metaParts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: onSurfaceVar,
                  ),
                ),
              ),
            ],
          );
    final normalStyle = TextStyle(color: foreground);
    final primaryStyle = TextStyle(
      color: selected ? Colors.white : theme.colorScheme.primary,
      fontWeight: FontWeight.w700,
    );
    final secondaryStyle = TextStyle(
      color: selected ? Colors.white : theme.colorScheme.secondary,
      fontWeight: FontWeight.w700,
    );
    final mutedStyle = TextStyle(color: onSurfaceVar);
    final statWidgets = <Widget>[
      if (coverage != null)
        _semanticFact(
          '本批需求 ${_qty(material.requiredQty)}',
          key: ValueKey('material-batch-demand-${material.materialLineId}'),
          style: normalStyle,
        ),
      if (coverage != null)
        _semanticFact(
          '合格库存保障 ${_qty(coverage.covered)}/'
          '${_qty(material.requiredQty)}'
          '(${(coverage.ratio * 100).toStringAsFixed(0)}%)',
          key: ValueKey('material-batch-available-${material.materialLineId}'),
          style: TextStyle(color: coverageColor, fontWeight: FontWeight.w700),
          maxLines: 1,
        ),
      if (coverage != null && makeChild != null)
        _semanticFact(
          '已转自制需求 ${_qty(material.delegatedToRequestedQty ?? makeChild.requestedQty)}',
          key: ValueKey('material-make-transferred-${material.materialLineId}'),
          style: primaryStyle,
        ),
      if (coverage != null && makeChild != null && hasMakePlanFacts)
        _semanticFact(
          '执行计划量 ${makeChild.planExecutionPlannedQty == null ? '待回传' : _qty(makeChild.planExecutionPlannedQty)}',
          key: ValueKey('material-make-planned-${material.materialLineId}'),
          style: normalStyle,
        ),
      if (coverage != null && makeChild != null && hasMakePlanFacts)
        _semanticFact(
          '已完工入库 ${makeChild.planExecutionInboundQty == null ? '待回传' : _qty(makeChild.planExecutionInboundQty)}',
          key: ValueKey('material-make-inbound-${material.materialLineId}'),
          style: secondaryStyle,
        ),
      if (coverage != null && makeChild != null && !hasMakePlanFacts)
        _semanticFact(
          '自制子任务已创建 · 尚未生成生产计划',
          key: ValueKey(
            'material-make-awaiting-plan-${material.materialLineId}',
          ),
          style: mutedStyle,
        ),
      if (requirementView != null)
        _semanticFact(
          requirementView.detail,
          key: ValueKey('material-requirement-help-${material.materialLineId}'),
          style: mutedStyle,
        ),
      if (delegated && material.delegatedToRequestedQty != null)
        _semanticFact(
          '接管子任务总需求 ${_qty(material.delegatedToRequestedQty)}',
          key: ValueKey('material-delegated-demand-${material.materialLineId}'),
          style: primaryStyle,
        ),
      if (delegated && _delegatedOwnerLabel(material) != null)
        _semanticFact(
          '接管来源 ${_delegatedOwnerLabel(material)}',
          key: ValueKey('material-delegated-owner-${material.materialLineId}'),
          style: primaryStyle,
        ),
      if (delegatedChildStatus != null)
        _semanticFact(
          '接管子任务状态 $delegatedChildStatus',
          key: ValueKey(
            'material-delegated-child-status-${material.materialLineId}',
          ),
          style: secondaryStyle,
        ),
      if (exactPeggedQty > 0)
        _semanticFact(
          '本节点合格入库绑定 ${_qty(exactPeggedQty)}',
          key: ValueKey('material-exact-pegged-${material.materialLineId}'),
          style: primaryStyle,
        ),
      if (material.subcontractHandoffFutureQty > 0)
        _semanticFact(
          '委外前置自制已接管供给 ${_qty(material.subcontractHandoffFutureQty)}',
          key: ValueKey(
            'material-subcontract-handoff-${material.materialLineId}',
          ),
          style: primaryStyle,
        ),
      if (coverage != null || publicAvailableQty > 0)
        _semanticFact(
          '公共可用 ${_qty(publicAvailableQty)}',
          key: ValueKey('material-public-available-${material.materialLineId}'),
          style: normalStyle,
        ),
      if (material.safetyStockQty > 0)
        _semanticFact(
          '安全保护 ${_qty(material.safetyStockQty)}',
          key: ValueKey(
            'material-safety-protection-${material.materialLineId}',
          ),
          style: secondaryStyle,
        ),
      if (warehouseStock != null &&
          (coverage != null || openSafetySupplyQty > 0))
        _semanticFact(
          '公共补库在途 ${_qty(openSafetySupplyQty)}',
          key: ValueKey('material-open-safety-${material.materialLineId}'),
          style: normalStyle,
        ),
      if (safetyReplenishmentGapQty > 0)
        _semanticFact(
          '公共补库待补 ${_qty(safetyReplenishmentGapQty)}',
          key: ValueKey('material-safety-gap-${material.materialLineId}'),
          style: TextStyle(
            color: selected ? Colors.white : theme.colorScheme.error,
            fontWeight: FontWeight.w700,
          ),
        ),
    ];
    final selectionControl = actionable
        ? SizedBox(
            width: 48,
            height: 48,
            child: _nodeSelectionControl(
              theme,
              material,
              group,
              route,
              selected,
            ),
          )
        : null;
    return Container(
      key: ValueKey(
        'material-bom-node-${material.nodeKey ?? material.materialLineId}',
      ),
      margin: EdgeInsets.only(
        top: UtenSpacing.s4,
        bottom: UtenSpacing.s4,
        // 层级阶梯：每层 16px、最多 5 层，整卡右移而不是挤压卡内内容。
        left: (material.level - 1).clamp(0, 5) * 16.0,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: selected
            ? UtenColors.deepGreen
            : shortage
            ? theme.colorScheme.error.withValues(alpha: 0.1)
            : status.color.withValues(alpha: 0.05),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: selected
              ? UtenColors.deepGreen
              : shortage
              ? theme.colorScheme.error.withValues(alpha: 0.55)
              : theme.colorScheme.outlineVariant,
          width: selected || shortage ? 1.4 : 1,
        ),
      ),
      child: LayoutBuilder(
        builder: (_, cardConstraints) {
          // 窄卡（手机 + 深层阶梯缩进后）放不下整高操作区与标题行元信息：
          // 元信息挪进数量行、详情收成图标、选择框与动作并入数量行换行排布。
          final narrow = cardConstraints.maxWidth < 560;
          return Stack(
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _nodeStatusRail(
                      theme,
                      material,
                      group,
                      route,
                      selected: selected,
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s8,
                          UtenSpacing.s12,
                          UtenSpacing.s8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                if (hasChildren && material.nodeKey != null)
                                  SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: IconButton(
                                      key: ValueKey(
                                        'material-bom-branch-toggle-${material.nodeKey}',
                                      ),
                                      tooltip: branchCollapsed
                                          ? '展开下级物料'
                                          : '折叠下级物料',
                                      onPressed: () => setState(() {
                                        final key = material.nodeKey!;
                                        if (!_collapsedBomBranches.add(key)) {
                                          _collapsedBomBranches.remove(key);
                                        }
                                      }),
                                      icon: Icon(
                                        branchCollapsed
                                            ? Icons.chevron_right_rounded
                                            : Icons.expand_more_rounded,
                                        color: foreground ?? onSurfaceVar,
                                      ),
                                    ),
                                  )
                                else
                                  const SizedBox(width: UtenSpacing.s4),
                                _typeBadge(
                                  theme,
                                  route,
                                  onColor: selected ? Colors.white : null,
                                ),
                                const SizedBox(width: UtenSpacing.s4),
                                _levelBadge(
                                  theme,
                                  material.level,
                                  onColor: selected ? Colors.white : null,
                                ),
                                const SizedBox(width: UtenSpacing.s8),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    titleWithCode,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      color: foreground,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (!narrow && metaText != null) ...[
                                  const SizedBox(width: UtenSpacing.s8),
                                  Flexible(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 240,
                                      ),
                                      child: metaText,
                                    ),
                                  ),
                                ],
                                _nodeDetailsToggle(
                                  theme,
                                  group,
                                  foreground: foreground,
                                  compact: narrow,
                                ),
                              ],
                            ),
                            const SizedBox(height: UtenSpacing.s4),
                            if (narrow)
                              Wrap(
                                spacing: UtenSpacing.s16,
                                runSpacing: UtenSpacing.s8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  ...statWidgets,
                                  ?metaText,
                                  statusWidget,
                                  ?selectionControl,
                                  ?action,
                                  ?routeButton,
                                ],
                              )
                            else
                              Row(
                                children: [
                                  Expanded(
                                    child: Wrap(
                                      spacing: UtenSpacing.s16,
                                      runSpacing: UtenSpacing.s4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [...statWidgets, statusWidget],
                                    ),
                                  ),
                                  if (selectionControl != null) ...[
                                    const SizedBox(width: UtenSpacing.s4),
                                    selectionControl,
                                  ],
                                ],
                              ),
                            _borrowBadges(theme, material, selected: selected),
                            if (_expandedPathGroups.contains(group.key))
                              _nodeDetails(theme, group),
                          ],
                        ),
                      ),
                    ),
                    if ((action != null || routeButton != null) && !narrow)
                      Container(
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: selected
                                  ? Colors.white24
                                  : theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: UtenSpacing.s8,
                        ),
                        // 右操作区：主动作在上、「更换路线」在下，垂直居中；
                        // 不用 double.infinity/stretch（Row 内水平无界会断言失败），按钮按内容宽度右对齐。
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            ?action,
                            if (action != null && routeButton != null)
                              const SizedBox(height: UtenSpacing.s8),
                            ?routeButton,
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (peeking)
                Positioned(
                  left: 52,
                  top: UtenSpacing.s4,
                  child: IgnorePointer(
                    child: Container(
                      key: ValueKey(
                        'material-node-progress-peek-${material.materialLineId}',
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s8,
                        vertical: UtenSpacing.s4,
                      ),
                      decoration: BoxDecoration(
                        color: selected ? Colors.white : UtenColors.deepGreen,
                        borderRadius: UtenRadius.smAll,
                        boxShadow: UtenElevation.mid(
                          isDark: theme.brightness == Brightness.dark,
                        ),
                      ),
                      child: Text(
                        '合格库存保障 ${_qty(coverage.covered)}'
                        '/${_qty(material.requiredQty)}'
                        '(${(coverage.ratio * 100).toStringAsFixed(0)}%)',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: selected ? UtenColors.deepGreen : Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 备货完成节点保留紧凑成功态，同时明确本批需求与合格库存保障 100%；
  /// 不能只给“备货完成”而隐藏完成的是哪个数量口径。
  Widget _stockedNodeCollapsedCard(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool hasChildren,
  }) {
    final title = material.goodsName ?? material.goodsCode ?? '未命名物料';
    final titleWithCode =
        material.goodsName != null && material.goodsCode != null
        ? '${material.goodsName}(${material.goodsCode})'
        : title;
    final branchCollapsed =
        material.nodeKey != null &&
        _collapsedBomBranches.contains(material.nodeKey);
    final levelColor = _levelBandColor(theme, material.level);
    final exactPeggedQty = material.exactPeggedQty;
    final notified = _notifiedTargetOf(material);
    final makeChild = notified?.target == MaterialSupplyRoute.make
        ? _makeChildProductOf(material)
        : null;
    final hasMakePlanFacts =
        makeChild != null && _hasPlanExecutionFacts(makeChild);
    return Container(
      key: ValueKey(
        'material-bom-node-${material.nodeKey ?? material.materialLineId}',
      ),
      margin: EdgeInsets.only(
        top: UtenSpacing.s4,
        bottom: UtenSpacing.s4,
        // 层级阶梯与展开卡一致（每层 16px、最多 5 层），折叠后层级位置不漂移。
        left: (material.level - 1).clamp(0, 5) * 16.0,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label:
                  '合格库存保障 ${_qty(material.requiredQty)}/'
                  '${_qty(material.requiredQty)}，百分之100，备货完成',
              child: Container(
                width: 44,
                decoration: BoxDecoration(
                  color: levelColor.withValues(alpha: 0.24),
                  border: Border(
                    right: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 17,
                    vertical: UtenSpacing.s8,
                  ),
                  child: DecoratedBox(
                    key: ValueKey(
                      'material-node-rail-fill-${material.materialLineId}',
                    ),
                    decoration: _verticalRailProgressDecoration(
                      background: theme.colorScheme.primary.withValues(
                        alpha: 0.22,
                      ),
                      fill: theme.colorScheme.primary,
                      ratio: 1,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s12,
                  UtenSpacing.s4,
                  UtenSpacing.s12,
                  UtenSpacing.s4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        if (hasChildren && material.nodeKey != null)
                          SizedBox(
                            width: 40,
                            height: 40,
                            child: IconButton(
                              key: ValueKey(
                                'material-bom-branch-toggle-${material.nodeKey}',
                              ),
                              tooltip: branchCollapsed ? '展开下级物料' : '折叠下级物料',
                              onPressed: () => setState(() {
                                final key = material.nodeKey!;
                                if (!_collapsedBomBranches.add(key)) {
                                  _collapsedBomBranches.remove(key);
                                }
                              }),
                              icon: Icon(
                                branchCollapsed
                                    ? Icons.chevron_right_rounded
                                    : Icons.expand_more_rounded,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        else
                          const SizedBox(width: UtenSpacing.s4),
                        _typeBadge(theme, route),
                        const SizedBox(width: UtenSpacing.s4),
                        _levelBadge(theme, material.level),
                        const SizedBox(width: UtenSpacing.s8),
                        Expanded(
                          child: Text(
                            titleWithCode,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        _nodeDetailsToggle(theme, group, compact: true),
                        const SizedBox(width: UtenSpacing.s4),
                        _stockedDoneBadge(theme),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(
                        left: UtenSpacing.s4,
                        bottom: UtenSpacing.s4,
                      ),
                      child: Wrap(
                        spacing: UtenSpacing.s12,
                        runSpacing: UtenSpacing.s4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _semanticFact(
                            '本批需求 ${_qty(material.requiredQty)}',
                            key: ValueKey(
                              'material-batch-demand-${material.materialLineId}',
                            ),
                            style: theme.textTheme.bodySmall,
                          ),
                          _semanticFact(
                            '合格库存保障 ${_qty(material.requiredQty)}/'
                            '${_qty(material.requiredQty)}(100%)',
                            key: ValueKey(
                              'material-batch-available-${material.materialLineId}',
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (exactPeggedQty > 0)
                            _miniBadge(
                              theme,
                              label: '本节点合格入库绑定 ${_qty(exactPeggedQty)}',
                              color: theme.colorScheme.primary,
                            ),
                          if (material.subcontractHandoffFutureQty > 0)
                            _miniBadge(
                              theme,
                              label:
                                  '委外前置自制已接管供给 '
                                  '${_qty(material.subcontractHandoffFutureQty)}',
                              color: theme.colorScheme.primary,
                            ),
                          if (makeChild != null)
                            _semanticFact(
                              '已转自制需求 ${_qty(material.delegatedToRequestedQty ?? makeChild.requestedQty)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          if (makeChild != null && hasMakePlanFacts)
                            _semanticFact(
                              '执行计划量 ${makeChild.planExecutionPlannedQty == null ? '待回传' : _qty(makeChild.planExecutionPlannedQty)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          if (makeChild != null && hasMakePlanFacts)
                            _semanticFact(
                              '已完工入库 ${makeChild.planExecutionInboundQty == null ? '待回传' : _qty(makeChild.planExecutionInboundQty)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.secondary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          if (notified != null)
                            TextButton.icon(
                              key: ValueKey(
                                'material-supply-progress-${material.materialLineId}',
                              ),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 44),
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _showSupplyProgress(group),
                              icon: const Icon(Icons.route_outlined, size: 18),
                              label: Text(
                                '查看${notified.target?.label ?? '供给'}流程',
                              ),
                            ),
                          if (makeChild?.latestPlanId != null)
                            _makePlanReference(
                              theme,
                              material,
                              makeChild!,
                              selected: false,
                              compact: true,
                            ),
                        ],
                      ),
                    ),
                    if (_expandedPathGroups.contains(group.key))
                      _nodeDetails(theme, group),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 折叠卡右侧的「备货完成」徽章：深绿实底白字（只读，示意合格库存保障已齐）。
  Widget _stockedDoneBadge(ThemeData theme) {
    final iconOnly = MediaQuery.sizeOf(context).width < 480;
    return Tooltip(
      message: '备货完成',
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        label: '备货完成',
        child: ExcludeSemantics(
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: iconOnly ? UtenSpacing.s4 : UtenSpacing.s8,
              vertical: UtenSpacing.s4,
            ),
            decoration: const BoxDecoration(
              color: UtenColors.deepGreen,
              borderRadius: UtenRadius.pillAll,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: Colors.white,
                ),
                if (!iconOnly) ...[
                  const SizedBox(width: UtenSpacing.s4),
                  Text(
                    '备货完成',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 节点「更换路线」按钮（右操作区下位）。已确认路线显深绿实底并带当前
  /// 路线名（点按仍可更换）；无建议路线时作主入口「选择路线」；其余为描边
  /// 「更换路线」。点击弹出路线选择面板，选中立即保存（偏离建议须填原因），

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
    for (final entry in indexes.materialsByProduct.entries) {
      final product = entry.key == null
          ? null
          : indexes.productsById[entry.key];
      if (_isEmbeddedMakeChildProduct(product)) continue;
      directMatches += entry.value.where((material) {
        return _bomModeMatches(material) && _bomTextMatches(material, product);
      }).length;
      final visible = _visibleBomNodes(entry.value, product);
      if (visible.isNotEmpty) nodesByProduct[entry.key] = visible;
      visibleNodes += visible.length;
    }
    final projection = _BomFilterProjection(
      nodesByProduct: nodesByProduct,
      directMatchCount: directMatches,
      visibleNodeCount: visibleNodes,
    );
    _bomProjectionAnalysis = analysis;
    _bomProjectionMode = _bomViewMode;
    _bomProjectionKeyword = _bomKeyword;
    _bomProjectionCache = projection;
    return projection;
  }
}
