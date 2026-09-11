part of 'production_material_analysis_page.dart';

@visibleForTesting
class MaterialAnalysisMakeChildDetails extends StatelessWidget {
  const MaterialAnalysisMakeChildDetails({
    super.key,
    required this.material,
    required this.child,
    required this.qtyText,
    this.statusLabel,
    this.planAction,
  });

  final ProductionMaterialAnalysisMaterial material;
  final ProductionMaterialAnalysisProduct child;
  final String Function(double? value) qtyText;
  final String? statusLabel;
  final Widget? planAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subcontract = child.sourceType == 'SUBCONTRACT_MAKE';
    final title = subcontract ? '关联委外前置自制任务' : '关联自制子任务';
    final childName = child.goodsName?.trim();
    final childCode = child.goodsCode?.trim();
    final childLabel = childName?.isNotEmpty == true
        ? childCode?.isNotEmpty == true
              ? '$childName($childCode)'
              : childName!
        : childCode?.isNotEmpty == true
        ? childCode!
        : child.sourceRef?.trim().isNotEmpty == true
        ? child.sourceRef!.trim()
        : '自制子任务';
    final transferred = qtyText(
      material.delegatedToRequestedQty ?? child.requestedQty,
    );
    final planned = child.planExecutionPlannedQty == null
        ? '待回传'
        : qtyText(child.planExecutionPlannedQty);
    final inbound = child.planExecutionInboundQty == null
        ? '待回传'
        : qtyText(child.planExecutionInboundQty);
    final status = statusLabel?.trim();
    final summary = [
      title,
      childLabel,
      if (status?.isNotEmpty == true) '状态 $status',
      '已下达自制 $transferred',
      '计划量 $planned',
      '已完工入库 $inbound',
    ].join('；');

    Widget metric(String label, String value, Color color) => Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        style: theme.textTheme.bodySmall?.copyWith(color: color),
      ),
    );

    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.55),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            key: ValueKey(
              'material-make-child-summary-${material.materialLineId}',
            ),
            container: true,
            readOnly: true,
            label: summary,
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.subdirectory_arrow_right_rounded,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              childLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                            if (status?.isNotEmpty == true)
                              Text(
                                '状态 · $status',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Wrap(
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s4,
                    children: [
                      metric('已下达自制', transferred, theme.colorScheme.primary),
                      metric('计划量', planned, theme.colorScheme.onSurface),
                      metric('已完工入库', inbound, theme.colorScheme.secondary),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (planAction != null) ...[
            const SizedBox(height: UtenSpacing.s4),
            Align(alignment: Alignment.centerLeft, child: planAction),
          ],
        ],
      ),
    );
  }
}

abstract class _MaterialAnalysisProductTasksState
    extends _MaterialAnalysisPlanActionsState {
  List<ProductionMaterialAnalysisMaterial> _depth1MaterialsFor(
    ProductionMaterialAnalysisProduct product,
  ) {
    final analysis = _analysis;
    if (analysis == null) return const [];
    // 索引取本产品物料（原为全表 where 扫描，几百产品时 O(物料×产品)）。
    return _analysisIndexes(analysis).materialsByProduct[product.analysisLineId]
            ?.where((material) => material.level == 1)
            .toList(growable: false) ??
        const [];
  }

  bool _productExecutionCompleted(ProductionMaterialAnalysisProduct product) =>
      _productExecutionStage(product)?.tone == ProductionFlowTone.done;

  Color _productExecutionColor(ThemeData theme, ProductionFlowStage stage) {
    return switch (stage.tone) {
      ProductionFlowTone.done => theme.colorScheme.primary,
      ProductionFlowTone.active => theme.colorScheme.tertiary,
      ProductionFlowTone.pending => theme.colorScheme.outline,
    };
  }

  /// Bottom-up material readiness for a product/assembly card. This controls
  /// whether material may be issued and production may start; scheduling uses
  /// the independent server-authored canSchedule/maxSchedulableQty pair.
  /// When material is short, the reason is broken down by which depth-one
  /// materials are still short and whether they are self-make
  /// sub-assemblies (waiting on children to be built and received), procured
  /// (BUY) or subcontracted items.
  _ProductReadiness _productReadiness(
    ProductionMaterialAnalysisProduct product,
  ) {
    if (product.readyNowQty > 0) {
      return const _ProductReadiness(_ReadinessState.ready);
    }
    var make = 0, buy = 0, subcontract = 0, review = 0;
    for (final material in _depth1MaterialsFor(product)) {
      if (material.shortageQty <= 0) continue;
      switch (material.confirmedRoute ?? material.sourceSuggestion) {
        case MaterialSupplyRoute.make:
          make++;
        case MaterialSupplyRoute.buy:
          buy++;
        case MaterialSupplyRoute.subcontract:
          subcontract++;
        case null:
          review++;
      }
    }
    final state = make > 0
        ? _ReadinessState.waitingMake
        : (buy > 0 || subcontract > 0
              ? _ReadinessState.waitingSupply
              : _ReadinessState.waiting);
    return _ProductReadiness(
      state,
      make: make,
      buy: buy,
      subcontract: subcontract,
      review: review,
    );
  }

  @override
  ProductionMaterialAnalysisMaterial? _rootSupplyMaterialOf(
    ProductionMaterialAnalysisProduct product,
  ) {
    final analysis = _analysis;
    final rootId = product.rootMaterialLineId;
    if (analysis == null || rootId == null) return null;
    final group = _analysisIndexes(analysis).groupsByLine[rootId];
    return group?.paths
        .where(
          (material) =>
              material.materialLineId == rootId &&
              material.analysisLineId == product.analysisLineId &&
              material.isRootSupply,
        )
        .firstOrNull;
  }

  List<ProductionMaterialAnalysisMaterial> _directNodeMaterials(
    ProductionMaterialAnalysisMaterial material,
    ProductionMaterialAnalysisView analysis,
  ) {
    final indexes = _analysisIndexes(analysis);
    if (material.isRootSupply) {
      return (indexes.materialsByProduct[material.analysisLineId] ??
              const <ProductionMaterialAnalysisMaterial>[])
          .where((node) => !node.isRootSupply && node.level == 1)
          .toList(growable: false);
    }
    return indexes.childrenByParentNodeKey[(
          analysisLineId: material.analysisLineId,
          parentNodeKey: material.nodeKey ?? '',
        )] ??
        const [];
  }

  String? _rootRouteScheduleHint(ProductionMaterialAnalysisProduct product) {
    final root = _rootSupplyMaterialOf(product);
    if (root == null) return null;
    final group = _analysisIndexes(
      _analysis!,
    ).groupsByLine[root.materialLineId];
    if (root.confirmedRoute == null ||
        (group != null && _dirtyRouteGroups.contains(group.key))) {
      // 2026-09-05 用户口径：顶层进度与下层物料同款红色「路线待确认」，
      // 不再用更长的指令式文案（materialRootRoutePending 已统一改短）。
      return _l10n.materialRootRoutePending;
    }
    return root.confirmedRoute != MaterialSupplyRoute.make
        ? _l10n.materialRootExternalRoute
        : null;
  }

  /// 顶层供料路线是否待确认（含本页已改路线未保存的脏组）。
  bool _rootRoutePending(ProductionMaterialAnalysisProduct product) {
    final root = _rootSupplyMaterialOf(product);
    if (root == null) return false;
    final group = _analysisIndexes(
      _analysis!,
    ).groupsByLine[root.materialLineId];
    return root.confirmedRoute == null ||
        (group != null && _dirtyRouteGroups.contains(group.key));
  }

  bool _belongsInWorkshop(ProductionMaterialAnalysisProduct product) {
    if (_productExecutionStage(product) != null) return true;
    final root = _rootSupplyMaterialOf(product);
    // 顶层与子层自制同构（2026-09-05 用户口径）：顶层路线显式确认为自制才进
    // 车间桶——未确认的顶层和未确认的子层候选一样只留在主表（红色「路线待
    // 确认」），确认采购/委外的顶层只进各自路线桶，不再有顶层专用放行。
    return root == null || root.confirmedRoute == MaterialSupplyRoute.make;
  }

  /// MAKE 路线已确认但尚未创建子件任务的候选卡投影：下层未齐 → 显示
  /// 「下层缺料 · 可先创建子件任务」（2026-09-04 起不再卡：先建任务，计划
  /// 审批后形成 WAITING 执行段——零预留、无领料单，齐套后自动转 READY）；
  /// 下层齐套 → 可安排区可勾选，批量「创建子件任务」后留在本页填数量。
  /// 已创建（存在活动 MAKE 通知或真实 child）的节点不再出现在这里，
  /// 由真实 MAKE_COMPONENT 产品卡接管。
  ///
  /// V458/ADR-064 两段式：**有子层级的委外件确认「采用委外」后与自制完全
  /// 同构**——同样进入候选卡（下层未齐与自制同口径可先建任务、齐套=可安排
  /// 勾选提交，服务端分流建 SUBCONTRACT_MAKE 任务行），不再要求下达瞬间立即建任务。
  List<_PendingMakeCandidate> _pendingMakeCandidates(
    ProductionMaterialAnalysisView analysis,
  ) {
    final indexes = _analysisIndexes(analysis);
    final result = <_PendingMakeCandidate>[];
    // 顶层产品的根物料行不生成候选：顶层是否下达都由上方产品行承载
    // （ADR-071 一张表）。nodeRole 缺失的旧载荷按 rootMaterialLineId 兜底
    // 识别，否则已下达根产品会以「自制候选」重复出现在未下达段。
    final rootProductLineIds = {
      for (final product in analysis.products)
        if (product.rootMaterialLineId != null) product.rootMaterialLineId!,
    };
    for (final material in analysis.materials) {
      final isRootLine =
          material.isRootSupply ||
          rootProductLineIds.contains(material.materialLineId);
      if (isRootLine && material.confirmedRoute == MaterialSupplyRoute.make) {
        continue;
      }
      if (material.shortageQty <= 0) continue;
      final route = material.confirmedRoute;
      final isMakeCandidate = route == MaterialSupplyRoute.make;
      final isSubcontractCandidate =
          route == MaterialSupplyRoute.subcontract &&
          _hasProductionBomChildren(material, analysis);
      if (!isMakeCandidate && !isSubcontractCandidate) {
        continue;
      }
      final hasActiveTask = material.notifiedTargets.any(
        (target) =>
            target.target == route &&
            target.status?.toUpperCase() != 'CANCELLED',
      );
      final existingChild = _taskChildProductOf(material);
      if (hasActiveTask ||
          existingChild != null ||
          _hasUnlinkedIssuedPlan(material)) {
        continue;
      }

      final directShortages = _directNodeMaterials(material, analysis)
          .where(
            (child) =>
                child.hardGate != false &&
                !_isNonProductionStage(child.controlStage) &&
                child.shortageQty > 0,
          )
          .toList(growable: false);
      final kindCount = directShortages
          .map(_materialKindIdentity)
          .toSet()
          .length;
      final unconfirmedCount = directShortages
          .where((child) => child.confirmedRoute == null)
          .length;
      final path = material.path
          .where((segment) => !_looksLikeUuid(segment))
          .toList(growable: false);
      final parentProduct = material.analysisLineId == null
          ? null
          : indexes.productsById[material.analysisLineId];
      final parentLabel =
          material.parentLabel ??
          (path.length > 1 ? path[path.length - 2] : null) ??
          parentProduct?.goodsName ??
          parentProduct?.goodsCode;
      result.add(
        _PendingMakeCandidate(
          material: material,
          group: indexes.groupsByLine[material.materialLineId],
          route: route!,
          parentLabel: parentLabel,
          shortageKindCount: kindCount,
          shortagePathCount: directShortages.length,
          unconfirmedPathCount: unconfirmedCount,
        ),
      );
    }
    result.sort((left, right) {
      final readiness = (_canArrangePendingMakeCandidate(left) ? 0 : 1)
          .compareTo(_canArrangePendingMakeCandidate(right) ? 0 : 1);
      if (readiness != 0) return readiness;
      return left.material.materialLineId.compareTo(
        right.material.materialLineId,
      );
    });
    return result;
  }

  /// 有子层级委外件判定：分析树中该节点存在生产性 BOM 子件
  /// （排除 SHIP/REFERENCE 非生产阶段）。只有这类委外件走「先自制」
  /// 候选两段式；无子层纯外发件确认后仍直接走申请链。
  /// 经 (analysisLineId, parentNodeKey) 复合索引取直接子件（原为全表扫描）。
  bool _hasProductionBomChildren(
    ProductionMaterialAnalysisMaterial material,
    ProductionMaterialAnalysisView analysis,
  ) {
    if (material.isRootSupply &&
        _analysisIndexes(analysis)
                .productsById[material.analysisLineId]
                ?.hasProductionMaterialChildren ==
            true) {
      return true;
    }
    return _directNodeMaterials(
      material,
      analysis,
    ).any((child) => !_isNonProductionStage(child.controlStage));
  }

  bool _isNonProductionStage(String? stage) {
    final normalized = stage?.trim().toUpperCase();
    return normalized == 'SHIP' || normalized == 'REFERENCE';
  }

  String _materialKindIdentity(ProductionMaterialAnalysisMaterial material) {
    final key = material.materialKey?.trim();
    if (key?.isNotEmpty == true) return key!;
    final dimension = [
      material.goodsId,
      material.colorId,
      material.unitId,
    ].whereType<String>().join('|');
    return dimension.isEmpty ? material.materialLineId : dimension;
  }

  /// 显式子件任务可执行判定：路线已确认且有剩余量。
  /// 下层未齐只决定后续计划审批为 WAITING，不再阻止建 child。
  bool _canArrangePendingMakeCandidate(_PendingMakeCandidate candidate) {
    final group = candidate.group;
    return group != null && _isExecutableSupplyGroup(group, candidate.route);
  }

  Widget _productSection(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    final byId = {
      for (final product in analysis.products) product.analysisLineId: product,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '生产准备任务',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    _l10n.materialTaskSectionHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (_canAdjustPriorities && analysis.products.length > 1)
              UtenButton(
                key: const Key('material-analysis-priority-edit'),
                type: UtenButtonType.ghost,
                icon: Icons.swap_vert_rounded,
                onPressed: _busy || _editingPriorities
                    ? null
                    : _beginPriorityEdit,
                child: const Text('调整物料优先顺序'),
              ),
          ],
        ),
        if (_editingPriorities) ...[
          const SizedBox(height: UtenSpacing.s8),
          _priorityEditor(theme, byId),
        ],
        const SizedBox(height: UtenSpacing.s8),
        // Route entries retain issued history and show status inside each list.
        Wrap(
          key: const Key('material-analysis-bucket-entries'),
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            for (final bucket in _AnalysisBucket.values)
              _bucketEntryTile(theme, bucket),
          ],
        ),
      ],
    );
  }

  /// 分桶入口卡：图标 + 名称 + 计数徽标；计数 0 时灰显不可点。
  Widget _bucketEntryTile(ThemeData theme, _AnalysisBucket bucket) {
    final count = _bucketCount(bucket);
    final enabled = count > 0 && !_busy;
    final accent = _bucketAccent(theme, bucket);
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label:
          '${bucket.countLabel(_l10n)} $count 项。${bucket.semanticHint(_l10n)}',
      child: InkWell(
        key: Key('material-analysis-entry-${bucket.name}'),
        onTap: enabled ? () => _openBucketDetail(bucket) : null,
        borderRadius: UtenRadius.mdAll,
        child: Container(
          constraints: const BoxConstraints(minWidth: 168),
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s12,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: UtenRadius.mdAll,
            border: Border.all(
              color: enabled
                  ? accent.withValues(alpha: 0.55)
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _bucketIcon(bucket),
                size: 20,
                color: enabled ? accent : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                bucket.countLabel(_l10n),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: enabled
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: enabled
                      ? accent.withValues(alpha: 0.14)
                      : theme.colorScheme.surfaceContainerLow,
                  borderRadius: UtenRadius.smAll,
                  border: Border.all(
                    color: enabled
                        ? accent.withValues(alpha: 0.5)
                        : theme.colorScheme.outlineVariant,
                  ),
                ),
                child: Text(
                  '$count',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: enabled
                        ? accent
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s4),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: enabled ? accent : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _bucketIcon(_AnalysisBucket bucket) => switch (bucket) {
    _AnalysisBucket.buy => Icons.shopping_cart_outlined,
    _AnalysisBucket.subcontract => Icons.precision_manufacturing_outlined,
    _AnalysisBucket.workshop => Icons.factory_outlined,
  };

  Color _bucketAccent(ThemeData theme, _AnalysisBucket bucket) =>
      switch (bucket) {
        _AnalysisBucket.buy => theme.colorScheme.tertiary,
        _AnalysisBucket.subcontract => theme.colorScheme.secondary,
        _AnalysisBucket.workshop => theme.colorScheme.primary,
      };

  /// 各桶计数（入口徽标与详情页行数同一来源，不会漂移）。
  int _bucketCount(_AnalysisBucket bucket) => _bucketRows(bucket).length;

  /// 分桶行投影缓存（按分析对象身份）：行投影含 `_pendingMakeCandidates`
  /// 的 O(物料²) 扫描，而路由转场动画期间入口/详情页每帧重建——不缓存时
  /// 大分析（几百物料）点入口即页面卡死数十秒。分析快照被 `_applyAnalysis`
  /// 替换时随之失效；详情页在前台时宿主页轮询暂停，快照天然稳定。
  List<_BucketRow> _bucketRows(_AnalysisBucket bucket) {
    final analysis = _analysis;
    if (analysis == null) return const [];
    if (_bucketRowsCacheAnalysis == null ||
        !identical(_bucketRowsCacheAnalysis, analysis) ||
        _bucketRowsCache == null) {
      _bucketRowsCacheAnalysis = analysis;
      _bucketRowsCache = {};
    }
    // putIfAbsent：空桶也缓存，避免 O(物料²) 投影在转场每帧重算。
    return _bucketRowsCache!.putIfAbsent(
      bucket,
      () => _computeBucketRows(bucket, analysis),
    );
  }

  List<_BucketRow> _computeBucketRows(
    _AnalysisBucket bucket,
    ProductionMaterialAnalysisView analysis,
  ) {
    if (bucket == _AnalysisBucket.workshop) {
      final products = _operationalProducts(
        analysis,
      ).where(_belongsInWorkshop).toList(growable: false);
      final presentIds = products
          .map((product) => product.analysisLineId)
          .toSet();
      return [
        for (final product in products) _BucketRow.product(product),
        // Completed products remain available in issued history.
        for (final product in analysis.products)
          if (_belongsInWorkshop(product) &&
              presentIds.add(product.analysisLineId))
            _BucketRow.product(product),
        for (final candidate in _pendingMakeCandidates(analysis))
          if (candidate.route == MaterialSupplyRoute.make)
            _BucketRow.candidate(candidate),
      ];
    }
    final route = bucket.supplyRoute!;
    return [
      for (final group in _materialGroups(analysis))
        if ((group.representative.confirmedRoute == route &&
                _hasSupplySubmitQty(group, route)) ||
            group.paths.any(
              (path) =>
                  path.notifiedTargets.any((target) => target.target == route),
            ))
          _BucketRow.group(group),
    ];
  }

  bool _bucketRowHasIssued(_BucketRow row, _AnalysisBucket bucket) {
    final product = row.product;
    if (product != null) return _productExecutionStage(product) != null;
    final route = bucket.supplyRoute;
    return route != null &&
        (row.group?.paths.any(
              (path) =>
                  path.notifiedTargets.any((target) => target.target == route),
            ) ??
            false);
  }

  bool _bucketRowHasPending(_BucketRow row, _AnalysisBucket bucket) {
    final product = row.product;
    if (product != null) {
      return !_productFullyTransferred(product) &&
          !_productExecutionCompleted(product);
    }
    if (row.candidate != null) return true;
    final group = row.group;
    final route = bucket.supplyRoute;
    return group != null &&
        route != null &&
        group.representative.confirmedRoute == route &&
        _hasSupplySubmitQty(group, route);
  }

  bool _bucketRowNeedsAttention(_BucketRow row, _AnalysisBucket bucket) {
    if (!_bucketRowHasPending(row, bucket)) return false;
    if (row.product != null) return !_canSelectProduct(row.product!);
    if (row.candidate != null) {
      return !_canArrangePendingMakeCandidate(row.candidate!);
    }
    return !_isExecutableSupplyGroup(row.group!, bucket.supplyRoute!);
  }

  bool _bucketRowCanAct(_BucketRow row, _AnalysisBucket bucket) {
    if (!_bucketRowHasPending(row, bucket) ||
        _bucketRowNeedsAttention(row, bucket)) {
      return false;
    }
    return row.product != null ? _canGenerate : _canNotify;
  }

  /// 未完工且未全部转生产的产品（按排产优先序，物料齐套优先）。
  List<ProductionMaterialAnalysisProduct> _operationalProducts(
    ProductionMaterialAnalysisView analysis,
  ) {
    final byId = {
      for (final product in analysis.products) product.analysisLineId: product,
    };
    final ordered = [
      for (final id in _priorityDraft)
        if (byId[id] != null) byId[id]!,
    ];
    // Set 判重（原 List.contains 是 O(产品²)，几千产品时秒级）。
    final orderedIds = ordered.map((product) => product.analysisLineId).toSet();
    for (final product in analysis.products) {
      if (orderedIds.add(product.analysisLineId)) ordered.add(product);
    }
    final originalOrder = {
      for (var index = 0; index < ordered.length; index++)
        ordered[index].analysisLineId: index,
    };
    ordered.sort((a, b) {
      final ar = a.canSchedule ? 0 : 1;
      final br = b.canSchedule ? 0 : 1;
      final readiness = ar.compareTo(br);
      if (readiness != 0) return readiness;
      return originalOrder[a.analysisLineId]!.compareTo(
        originalOrder[b.analysisLineId]!,
      );
    });
    return ordered
        .where((product) => !_productExecutionCompleted(product))
        .toList(growable: false);
  }

  /// 打开分桶详情页。详情页动作执行期间保持在前台（数量弹窗/计划向导经
  /// root Navigator 叠在详情页之上），不再先 pop 回宿主页弹窗。
  Future<void> _openBucketDetail(_AnalysisBucket bucket) async {
    if (_busy) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _MaterialAnalysisBucketPage(host: this, bucket: bucket),
      ),
    );
  }

  /// 分桶详情页发起的批量动作（详情页保持在前台时执行）：数量确认弹窗、
  /// 分批、幂等、409 恢复和计划向导仍由宿主页状态统一编排——实现只此一份，
  /// 避免详情页与宿主页各自漂移；弹层经 root Navigator 显示在详情页之上，
  /// 动作完成后详情页按最新快照刷新行集。
  Future<void> _executeBucketAction(_BucketActionRequest request) async {
    switch (request.type) {
      case _BucketActionType.buy:
        await _notifyRoute(
          MaterialSupplyRoute.buy,
          onlyGroupKeys: request.groupKeys,
          qtyByActionGroupKey: request.qtyByActionGroupKey,
        );
      case _BucketActionType.subcontractOnly:
        await _arrangeSubcontractProduction(
          onlyGroupKeys: request.groupKeys,
          qtyByActionGroupKey: request.qtyByActionGroupKey,
        );
      case _BucketActionType.createProductionPlans:
        // 2026-09-05 ADR-071：车间桶单按钮「创建生产计划」——所有自制行
        // 一视同仁，单次原子调用服务端 issue-plans（候选行建子件任务、逐行
        // 出计划、有审核权限同事务审核下达）；任一行失败整体回滚，不再有
        // 「已建子件、未出计划」的残留行。
        await _issueWorkshopPlans(
          candidateInputs: request.candidateInputs,
          planDrafts: request.planDrafts,
        );
    }
  }

  /// 下达车间（ADR-071）：把分桶页收集的行输入交给服务端原子执行。数量/
  /// 车间/负责人在分桶页已校验；这里组幂等键、处理 409 冲突恢复并展示
  /// 生成结果（计划单/领料单一屏）。齐不齐料由车间侧执行段自行判断等待。
  Future<void> _issueWorkshopPlans({
    List<_BucketCandidatePlanInput>? candidateInputs,
    List<_BucketPlanDraft>? planDrafts,
  }) async {
    final analysis = _analysis;
    final warehouseId = _warehouseId;
    final candidates = candidateInputs ?? const <_BucketCandidatePlanInput>[];
    final products = planDrafts ?? const <_BucketPlanDraft>[];
    if (analysis == null || warehouseId == null) return;
    if (candidates.isEmpty && products.isEmpty) return;
    final lines = <MaterialAnalysisIssueLine>[
      for (final input in candidates)
        MaterialAnalysisIssueLine(
          materialLineId: input.materialLineId,
          qty: input.qty,
          departmentId: input.departmentId,
          workshopName: input.workshopName,
          workerId: input.workerId,
        ),
      for (final draft in products)
        MaterialAnalysisIssueLine(
          analysisLineId: draft.analysisLineId,
          qty: draft.qty,
          departmentId: draft.departmentId,
          workshopName: draft.workshopName,
          workerId: draft.workerId,
        ),
    ];
    final key = businessIdempotencyKey(
      'material-analysis-issue-plans',
      [
        analysis.analysisId,
        analysis.version,
        analysis.fingerprint,
        _dateText(_billDate),
        _dateText(_deliveryDate),
        for (final line in lines) line.toJson().toString(),
      ].join('|'),
    );
    final approveNow = _permissions.contains(Perm.productionPlanApprove);
    setState(() {
      _setGenerating(true);
      _planSubmissionApproveNow = approveNow;
    });
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .issueWorkshopPlans(
            analysis: analysis,
            warehouseId: warehouseId,
            idempotencyKey: key,
            billDate: _dateText(_billDate)!,
            deliveryDate: _dateText(_deliveryDate),
            approveNow: approveNow,
            lines: lines,
          );
      if (!mounted) return;
      setState(() {
        _setGenerating(false);
        _applyAnalysis(result.analysis);
        _selectedPlanLineIds.clear();
        for (final line in lines) {
          _batchQtyControllers[line.analysisLineId]?.clear();
          _systemSeededBatchQtyTexts.remove(line.analysisLineId);
        }
      });
      refreshAfterProductionPlanGenerated(ref);
      final plans = result.plans;
      final approved = plans.any((plan) => plan.status == 'APPROVED');
      context.appSuccess(
        approved
            ? plans.any((plan) => plan.drawDocuments.isNotEmpty)
                  ? '生产计划已审核下达，物料提货单已生成'
                  : '生产计划已审核下达；当前待料，齐套后自动生成提货单'
            : '生产计划已生成并提交审批',
      );
      await _showGeneratedPlans(plans);
    } catch (error) {
      if (!mounted) return;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '创建生产计划',
      )) {
        if (mounted) setState(() => _setGenerating(false));
        return;
      }
      if (!mounted) return;
      setState(() => _setGenerating(false));
      context.appError(
        productionErrorMessage(error, fallback: '创建生产计划失败，请刷新后重试'),
        force: true,
      );
    } finally {
      if (mounted && _planSubmissionApproveNow) {
        setState(() => _planSubmissionApproveNow = false);
      }
    }
  }

  Widget _priorityEditor(
    ThemeData theme,
    Map<String, ProductionMaterialAnalysisProduct> products,
  ) => Container(
    key: const Key('material-analysis-priority-editor'),
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
          '生产优先级',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          '优先产品先模拟分配共享可用库存；这里只调整分析顺序，不创建正式库存预留。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        SizedBox(
          height: (_priorityDraft.length * 56.0).clamp(56.0, 480.0),
          child: Scrollbar(
            child: ListView.builder(
              key: const Key('material-analysis-priority-list'),
              itemExtent: 56,
              itemCount: _priorityDraft.length,
              itemBuilder: (_, index) => Container(
                key: ValueKey('material-priority-${_priorityDraft[index]}'),
                padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      foregroundColor: theme.colorScheme.onPrimaryContainer,
                      child: Text('${index + 1}'),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        products[_priorityDraft[index]]?.goodsName ??
                            products[_priorityDraft[index]]?.goodsCode ??
                            _priorityDraft[index],
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      key: ValueKey('material-priority-up-$index'),
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      tooltip: '提高优先级',
                      onPressed: index == 0 || _savingPriorities
                          ? null
                          : () => _movePriority(index, -1),
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
                    IconButton(
                      key: ValueKey('material-priority-down-$index'),
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      tooltip: '降低优先级',
                      onPressed:
                          index == _priorityDraft.length - 1 ||
                              _savingPriorities
                          ? null
                          : () => _movePriority(index, 1),
                      icon: const Icon(Icons.arrow_downward_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            UtenButton(
              key: const Key('material-analysis-priority-cancel'),
              type: UtenButtonType.ghost,
              onPressed: _savingPriorities ? null : _cancelPriorityEdit,
              child: const Text('取消'),
            ),
            UtenButton(
              key: const Key('material-analysis-priority-save'),
              icon: Icons.check_rounded,
              isLoading: _savingPriorities,
              onPressed: _savingPriorities ? null : _savePriorities,
              child: const Text('确认优先顺序'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _nodeDetails(ThemeData theme, _MaterialGroup group) {
    final material = group.representative;
    final taskChild = _taskChildProductOf(material);
    final taskChildStage = taskChild == null
        ? null
        : _productExecutionStage(taskChild);
    final exactPeggedQty = material.exactPeggedQty;
    final coverage = _coverageOf(material);
    final requirementView = coverage == null
        ? _requirementStateView(theme, material)
        : null;
    final delegated =
        material.effectiveRequirementState ==
        MaterialRequirementState.delegatedToMakeChild;
    final delegatedOwner = _delegatedOwnerLabel(material);
    final delegatedChildStatus = _delegatedChildStatusLabel(material);
    final detailFacts = <String>[
      if (coverage != null) '本批需求 ${_qty(material.requiredQty)}',
      if (coverage != null)
        '合格库存保障 ${_qty(coverage.covered)}/'
            '${_qty(material.requiredQty)}'
            '(${(coverage.ratio * 100).toStringAsFixed(0)}%)',
      if (requirementView != null) requirementView.title,
      if (requirementView != null) requirementView.detail,
      if (taskChild == null &&
          delegated &&
          material.delegatedToRequestedQty != null)
        '接管子任务总需求 ${_qty(material.delegatedToRequestedQty)}',
      if (taskChild == null && delegated && delegatedOwner != null)
        '接管来源 $delegatedOwner',
      if (taskChild == null && delegatedChildStatus != null)
        '接管子任务状态 $delegatedChildStatus',
      if (exactPeggedQty > 0) '本节点合格入库绑定 ${_qty(exactPeggedQty)}',
      if (material.subcontractHandoffFutureQty > 0)
        '委外前置自制已接管供给 ${_qty(material.subcontractHandoffFutureQty)}',
      if (material.reservedQty > 0) '已预留 ${_qty(material.reservedQty)}',
      if (coverage != null || material.mainWarehousePublicAvailableQty > 0)
        '公共可用 ${_qty(material.mainWarehousePublicAvailableQty)}',
      if (material.safetyStockQty > 0) '安全保护 ${_qty(material.safetyStockQty)}',
      if (coverage != null || material.mainWarehouseOpenSafetySupplyQty > 0)
        '公共补库在途 ${_qty(material.mainWarehouseOpenSafetySupplyQty)}',
      if (material.mainWarehouseSafetyReplenishmentGapQty > 0)
        '公共补库待补 ${_qty(material.mainWarehouseSafetyReplenishmentGapQty)}',
      if (material.inboundQty > 0) '本批供给预计在途 ${_qty(material.inboundQty)}',
      if (material.unitName?.isNotEmpty == true) '单位 ${material.unitName}',
      _materialStageLabel(material),
    ];
    return Container(
      key: ValueKey('material-node-details-${material.materialLineId}'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            children: [
              for (final fact in detailFacts)
                _semanticFact(fact, style: theme.textTheme.bodySmall),
            ],
          ),
          if (taskChild != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            MaterialAnalysisMakeChildDetails(
              key: ValueKey(
                'material-make-child-details-${material.materialLineId}',
              ),
              material: material,
              child: taskChild,
              qtyText: _qty,
              statusLabel: taskChildStage?.displayLabel,
              planAction: taskChild.latestPlanId == null
                  ? null
                  : _makePlanReference(
                      theme,
                      material,
                      taskChild,
                      compact: true,
                    ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
          for (final path in group.paths)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s4),
                  Expanded(
                    child: Text(
                      '路径：${_pathLabel(path)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: UtenSpacing.s4),
          // 2026-08-18 起路线选择与建议不再放在详情里：路线操作收进右侧
          // 操作区（采用建议 / 更换路线按钮），详情只保留高级字段与路径。
          if (!group.actionable) _inactiveNodeHint(theme, material),
          _nodeBorrowSection(theme, material),
        ],
      ),
    );
  }

  Widget _inactiveNodeHint(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
  ) {
    final label = material.requiredQty <= 0
        ? (() {
            final view = _requirementStateView(theme, material);
            return '${view.title}；${view.detail}';
          })()
        : material.shortageQty <= 0
        ? '库存已覆盖'
        : '当前节点只读；请查看状态与路径原因';
    return _semanticFact(
      label,
      key: ValueKey('material-inactive-hint-${material.materialLineId}'),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _makePlanReference(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    ProductionMaterialAnalysisProduct child, {
    bool compact = false,
  }) {
    final latestPlanId = child.latestPlanId!;
    if (!_canViewPlans) {
      return _disabledNodeAction(
        theme.colorScheme.onSurfaceVariant,
        Icons.lock_outline_rounded,
        '无查看生产计划权限',
      );
    }
    return TextButton.icon(
      key: ValueKey('material-view-plan-${material.materialLineId}'),
      style: TextButton.styleFrom(minimumSize: Size(48, compact ? 44 : 48)),
      onPressed: () =>
          context.push(RoutePath.productionPlanDetail(latestPlanId)),
      icon: const Icon(Icons.open_in_new_rounded, size: 18),
      label: Text(
        compact
            ? '生产计划 · ${child.latestPlanNo ?? '查看'}'
            : child.latestPlanNo ?? '查看计划',
      ),
    );
  }

  Widget _disabledNodeAction(Color color, IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: UtenSpacing.s4),
      Flexible(
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );

  /// 进度文案 + 稳定桶键（`facetKey`）：表头筛选只按键比较，带数量/百分比的
  /// 文案（在途/待补/保障 N%）统一落 inTransit/pendingIssue 等有限枚举，
  /// 流程阶段落 [ProductionFlowStage.key]（见 [_materialStatusFacetLabels]）。
  _StatusView _materialStatus(ThemeData theme, _MaterialGroup group) {
    final planningBlock = _planningBlockForGroup(group);
    if (planningBlock != null) {
      return _StatusView(
        planningBlock,
        Icons.info_outline_rounded,
        theme.colorScheme.tertiary,
        facetKey: 'blocked',
      );
    }
    final material = group.representative;
    // 2026-09-06 统一流程阶段优先：已下达/链路中的行显示真实停在哪一步。
    // 锚点模型下已转生产的行 requiredQty 常为 0——不能因此退化为
    // 「本批需求已转入生产计划」这类通用文案，进度必须与具体单据对应。
    if (_hasUnlinkedIssuedPlan(material)) {
      return _StatusView(
        _l10n.materialIssuedPlanSyncPending,
        Icons.sync_rounded,
        theme.colorScheme.tertiary,
        facetKey: 'inTransit',
      );
    }
    final serverStage = _serverFlowStageOf(group);
    if (serverStage != null) {
      return _StatusView(
        serverStage.displayLabel,
        serverStage.icon,
        _productExecutionColor(theme, serverStage),
        facetKey: serverStage.key,
        facetLabel: serverStage.label,
      );
    }
    // 自制/有子层委外的锚点子件执行（服务端无键时回退同款词表推导）。
    // 本批需求被合格库存覆盖时保留前缀——库存覆盖与子件执行是两个事实。
    final anchorChild = _taskChildProductOf(material);
    if (anchorChild != null) {
      final anchorStage = _productExecutionStage(anchorChild);
      if (anchorStage != null) {
        final covered = material.shortageQty <= 0;
        final label = covered && anchorStage.tone != ProductionFlowTone.done
            ? '本批库存已覆盖 · ${anchorStage.displayLabel}'
            : anchorStage.displayLabel;
        return _StatusView(
          label,
          anchorStage.icon,
          _productExecutionColor(theme, anchorStage),
          facetKey: anchorStage.key,
          facetLabel: anchorStage.label,
        );
      }
    }
    if (material.requiredQty <= 0) {
      final view = _requirementStateView(theme, material);
      return _StatusView(
        view.title,
        view.icon,
        view.color,
        facetKey: 'inactive',
      );
    }
    if (!group.actionable) {
      if (material.shortageQty <= 0) {
        return _StatusView(
          '本层库存已齐',
          Icons.check_circle_outline_rounded,
          theme.colorScheme.primary,
          facetKey: 'covered',
        );
      }
      return _StatusView(
        '当前节点只读',
        Icons.lock_outline_rounded,
        theme.colorScheme.tertiary,
        facetKey: 'blocked',
      );
    }
    final notified = _notifiedTargetOf(material);
    final covered = material.shortageQty <= 0;
    final demandGap = _groupDemandSupplyGapQty(group);
    final safetyGap = _groupSafetyReplenishmentGapQty(group);
    final openSafety = _groupOpenSafetySupplyQty(group);
    // shortageQty 是最终齐套阻断；demandSupplyGapQty 与公共安全补库必须分层，
    // 不能再把“安全库存未补”写成“本批物料未到”。
    if (notified != null) {
      final route = notified.target;
      if (route != null && _routeBlockedBySafetyGap(group, route)) {
        return _StatusView(
          '本批需求 ${demandGap <= 0 ? '已覆盖' : '还差 ${_qty(demandGap)}'}'
          ' · 本版本仅采购路线支持公共安全补库',
          Icons.policy_outlined,
          theme.colorScheme.error,
          facetKey: 'blocked',
        );
      }
      // MAKE 与有子层 SUBCONTRACT 的子件任务同构：内联真实子件执行状态；
      // 无子层委外叶子没有子件，落回下方普通已下达口径。
      final taskChild = _taskChildProductOf(material);
      if (route == MaterialSupplyRoute.make || taskChild != null) {
        final child = taskChild;
        final executionStage = child == null
            ? null
            : _productExecutionStage(child);
        if (executionStage != null) {
          final label =
              covered && executionStage.tone != ProductionFlowTone.done
              ? '本批库存已覆盖 · ${executionStage.displayLabel}'
              : executionStage.displayLabel;
          return _StatusView(
            label,
            executionStage.icon,
            _productExecutionColor(theme, executionStage),
            facetKey: executionStage.key,
            facetLabel: executionStage.label,
          );
        }
        if (covered) {
          return _StatusView(
            '本批库存已覆盖 · 自制任务状态待回传',
            Icons.inventory_2_outlined,
            theme.colorScheme.primary,
            facetKey: 'covered',
          );
        }
        // 2026-09-05 状态统一：未下达的自制任务一律「未下达」+ 同款颜色/
        // 图标（齐不齐料由车间侧执行段判断，这里不再按齐套分叉文案）。
        return _StatusView(
          _pendingIssueLabelOf(material),
          Icons.hourglass_bottom_rounded,
          theme.colorScheme.tertiary,
          facetKey: 'pendingIssue',
        );
      }
      if (covered) {
        return _StatusView(
          '已齐套(库存已覆盖)',
          Icons.check_circle_outline_rounded,
          theme.colorScheme.primary,
          facetKey: 'covered',
        );
      }
      // 分批提交：上一批仍在途且剩余缺口未闭合时，明说「当前在途 / 还差」，
      // DONE 只代表历史任务已经完成，不能被「已提交 0」误读为从未下达；
      // 该行可继续勾选补交，不会被误认为已全部下单。
      final residual = _residualSubmitQty(
        group,
        route ?? MaterialSupplyRoute.buy,
      );
      if (route != null && residual > 0) {
        final safetySuffix = safetyGap > 0
            ? ' · 安全补库待补 ${_qty(safetyGap)}'
            : '';
        return _StatusView(
          '需求在途 ${_qty(_openSubmittedQty(group, route))} · '
          '本批还差 ${_qty(residual)}$safetySuffix',
          Icons.timelapse_rounded,
          route == MaterialSupplyRoute.subcontract
              ? theme.colorScheme.secondary
              : theme.colorScheme.tertiary,
          facetKey: 'inTransit',
        );
      }
      if (route == MaterialSupplyRoute.buy && safetyGap > 0) {
        return _StatusView(
          '本批需求已覆盖 · 公共补库在途 ${_qty(openSafety)} · '
          '待补 ${_qty(safetyGap)}',
          Icons.shield_outlined,
          theme.colorScheme.tertiary,
          facetKey: 'inTransit',
        );
      }
      return _StatusView(
        route == MaterialSupplyRoute.subcontract ? '委外准备处理中' : '等待采购入库',
        Icons.local_shipping_outlined,
        route == MaterialSupplyRoute.subcontract
            ? theme.colorScheme.secondary
            : theme.colorScheme.tertiary,
        facetKey: 'inTransit',
      );
    }
    // 未通知：先看路线是否确认（ADR-029 §6.1 硬门槛）。
    if (material.confirmedRoute == null) {
      return _StatusView(
        '路线待确认',
        Icons.help_outline_rounded,
        theme.colorScheme.error,
        facetKey: 'routePending',
      );
    }
    if (material.lowerLevelPending) {
      // 2026-09-05 下达车间做减法：下层齐不齐不影响下达（计划只管下发，
      // 齐套由执行段 WAITING/READY 自动判断），状态统一「未下达」。
      return _StatusView(
        _pendingIssueLabelOf(material),
        Icons.hourglass_bottom_rounded,
        theme.colorScheme.tertiary,
        facetKey: 'pendingIssue',
      );
    }
    final confirmedRoute = material.confirmedRoute;
    if (confirmedRoute != null &&
        _routeBlockedBySafetyGap(group, confirmedRoute)) {
      return _StatusView(
        '本版本仅采购路线支持公共安全补库',
        Icons.policy_outlined,
        theme.colorScheme.error,
        facetKey: 'blocked',
      );
    }
    if (demandGap > 0) {
      return _StatusView(
        '本批需求待通知 ${_qty(demandGap)}',
        Icons.notifications_active_outlined,
        theme.colorScheme.tertiary,
        facetKey: 'pendingIssue',
      );
    }
    if (confirmedRoute == MaterialSupplyRoute.buy && safetyGap > 0) {
      return _StatusView(
        '本批需求已覆盖 · 待提交公共安全补库 ${_qty(safetyGap)}',
        Icons.shield_outlined,
        theme.colorScheme.tertiary,
        facetKey: 'pendingIssue',
      );
    }
    if (material.shortageQty > 0) {
      return _StatusView(
        '本批需求已覆盖 · 安全保护处理中',
        Icons.shield_outlined,
        theme.colorScheme.tertiary,
        facetKey: 'inTransit',
      );
    }
    return _StatusView(
      '已齐套',
      Icons.check_circle_outline_rounded,
      theme.colorScheme.primary,
      facetKey: 'covered',
    );
  }

  /// 服务端行级流程阶段（MaterialAnalysisFlowStageService 批量推导）；
  /// 旧服务端无 flowStage 字段或尚未下达时返回 null，由既有回退口径接管
  /// （未下达的第一步也有专门的路线文案）。
  ProductionFlowStage? _serverFlowStageOf(_MaterialGroup group) {
    final material = group.representative;
    final key = material.flowStage;
    if (key == null || key.endsWith('_PENDING_ISSUE')) {
      // 未下达不算“流程中”——由下方路线待确认/未下达分支接管。
      return null;
    }
    final route = material.confirmedRoute ?? material.sourceSuggestion;
    return ProductionFlowStage.fromServerKey(
      key,
      route: switch (route) {
        MaterialSupplyRoute.make => ProductionFlowRoute.make,
        MaterialSupplyRoute.subcontract => ProductionFlowRoute.subcontract,
        _ => ProductionFlowRoute.buy,
      },
    );
  }

  /// 未下达的第一步文案：按路线显示「等待下发采购 / 等待下发委外 /
  /// 等待下达车间」，与流程词表第一步同名。
  String _pendingIssueLabelOf(ProductionMaterialAnalysisMaterial material) {
    final route = material.confirmedRoute ?? material.sourceSuggestion;
    return switch (route) {
      MaterialSupplyRoute.make => '等待下达车间',
      MaterialSupplyRoute.subcontract => '等待下发委外',
      _ => '等待下发采购',
    };
  }

  /// 该物料组当前有效的「已下达通知」目标（跳过已撤销 CANCELLED）。

  /// 「层级 N」徽章：与路线角标同款小胶囊，颜色取层级色板（与整卡阶梯
  /// 缩进、状态栏底色共用同一色板，三处冗余表达层级）。
  Widget _factChip(ThemeData theme, IconData icon, String label) => Container(
    constraints: const BoxConstraints(maxWidth: 280),
    padding: const EdgeInsets.symmetric(
      horizontal: UtenSpacing.s8,
      vertical: UtenSpacing.s8,
    ),
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s4),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );

  Widget _serverRefreshBanner(ThemeData theme, String message) => Container(
    key: const Key('material-analysis-server-refresh-notice'),
    padding: const EdgeInsets.fromLTRB(
      UtenSpacing.s12,
      UtenSpacing.s8,
      UtenSpacing.s4,
      UtenSpacing.s8,
    ),
    decoration: BoxDecoration(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(
        color: theme.colorScheme.secondary.withValues(alpha: 0.4),
      ),
    ),
    child: Row(
      children: [
        Icon(Icons.sync_rounded, color: theme.colorScheme.secondary),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          tooltip: '关闭更新提示',
          onPressed: () => setState(() => _serverRefreshNotice = null),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );
}
