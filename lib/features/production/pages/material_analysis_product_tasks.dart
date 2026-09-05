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
      '已转自制需求 $transferred',
      '执行计划量 $planned',
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
                      metric('已转自制需求', transferred, theme.colorScheme.primary),
                      metric('执行计划量', planned, theme.colorScheme.onSurface),
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
      _productExecutionStage(product)?.status == 'COMPLETED';

  Color _productExecutionColor(ThemeData theme, _ProductExecutionStage stage) {
    return switch (stage.status) {
      'COMPLETED' => theme.colorScheme.primary,
      'IN_PROGRESS' || 'DISPATCHED' => theme.colorScheme.secondary,
      'SUBMITTED' || 'WAITING' => theme.colorScheme.tertiary,
      _ => theme.colorScheme.primary,
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

  Future<void> _openPlanForProduct(
    ProductionMaterialAnalysisProduct product,
  ) async {
    if (_busy) return;
    // 2026-09-04 用户口径：「填写生产计划单」向导页下线——单产品「安排生产」
    // 与分桶批量入口统一，直接打开该产品所在的分桶详情页（表内改数量/车间/
    // 负责人后点「生成生产计划」即预览+生成+下发车间任务）。
    var bucket = _AnalysisBucket.ready;
    for (final candidate in _AnalysisBucket.values) {
      final contains = _bucketRows(
        candidate,
      ).any((row) => row.product?.analysisLineId == product.analysisLineId);
      if (contains) {
        bucket = candidate;
        break;
      }
    }
    await _openBucketDetail(bucket);
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
    for (final material in analysis.materials) {
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
      final existingChild = isMakeCandidate
          ? _makeChildProductOf(material)
          : _subcontractMakeChildProductOf(material);
      if (hasActiveTask || existingChild != null) continue;

      final nodeKey = material.nodeKey;
      // 直接子层缺料：经父节点索引取直接子件（原为全表 where 扫描，
      // 几百物料×候选数 = O(物料²)，大分析点「可安排/暂不可安排」即卡顿）。
      final directShortages = nodeKey == null
          ? const <ProductionMaterialAnalysisMaterial>[]
          : (indexes.childrenByParentNodeKey[(
                      analysisLineId: material.analysisLineId,
                      parentNodeKey: nodeKey,
                    )] ??
                    const [])
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
    final nodeKey = material.nodeKey;
    if (nodeKey == null) return false;
    final children =
        _analysisIndexes(analysis).childrenByParentNodeKey[(
          analysisLineId: material.analysisLineId,
          parentNodeKey: nodeKey,
        )];
    if (children == null || children.isEmpty) return false;
    return children.any((child) => !_isNonProductionStage(child.controlStage));
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
                    '点击下方入口进入对应任务清单，可批量勾选下达或生成计划。',
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
        // 入口条：六个分桶各一张紧凑入口卡（计数徽标 + 前进箭头），点击进
        // 全屏详情页批量处理。替代原「大卡片套小卡片」瀑布流——物料多时
        // 顶部不再被成百张卡片撑爆，明细统一在详情页表格里分页浏览。
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
      label: '${bucket.countLabel} $count 项。${bucket.semanticHint}',
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
                bucket.countLabel,
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
    _AnalysisBucket.ready => Icons.play_circle_outline_rounded,
    _AnalysisBucket.waiting => Icons.do_not_disturb_on_outlined,
    _AnalysisBucket.transferred => Icons.account_tree_outlined,
    _AnalysisBucket.buy => Icons.shopping_cart_outlined,
    _AnalysisBucket.subcontract => Icons.precision_manufacturing_outlined,
    _AnalysisBucket.make => Icons.factory_outlined,
  };

  Color _bucketAccent(ThemeData theme, _AnalysisBucket bucket) =>
      switch (bucket) {
        _AnalysisBucket.ready => theme.colorScheme.primary,
        _AnalysisBucket.waiting => theme.colorScheme.error,
        _AnalysisBucket.transferred => theme.colorScheme.secondary,
        _AnalysisBucket.buy => theme.colorScheme.tertiary,
        _AnalysisBucket.subcontract => theme.colorScheme.secondary,
        _AnalysisBucket.make => theme.colorScheme.primary,
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
    switch (bucket) {
      case _AnalysisBucket.ready:
      case _AnalysisBucket.waiting:
        final candidates = _pendingMakeCandidates(analysis);
        final operationalProducts = _operationalProducts(analysis);
        final waitingCandidates = candidates
            .where((candidate) => !_canArrangePendingMakeCandidate(candidate))
            .map(_BucketRow.candidate);
        final readyProducts = operationalProducts
            .where(
              (product) =>
                  !_productFullyTransferred(product) &&
                  _canSelectProduct(product),
            )
            .map(_BucketRow.product);
        final waitingProducts = operationalProducts
            .where(
              (product) =>
                  !_productFullyTransferred(product) &&
                  !_canSelectProduct(product),
            )
            .map(_BucketRow.product);
        return bucket == _AnalysisBucket.ready
            // Route buckets own executable MAKE/SUBCONTRACT candidates. Keeping
            // them here too made one task appear in two buckets and exposed two
            // equivalent write entrances.
            ? readyProducts.toList(growable: false)
            : [
                ...waitingCandidates,
                ...waitingProducts,
              ].toList(growable: false);
      case _AnalysisBucket.transferred:
        return [
          for (final product in _operationalProducts(analysis))
            if (_productFullyTransferred(product)) _BucketRow.product(product),
        ];
      case _AnalysisBucket.buy:
        return [
          for (final group in _executableSupplyGroups(MaterialSupplyRoute.buy))
            _BucketRow.group(group),
        ];
      case _AnalysisBucket.subcontract:
        return [
          for (final group in _executableSupplyGroups(
            MaterialSupplyRoute.subcontract,
          ))
            _BucketRow.group(group),
        ];
      case _AnalysisBucket.make:
        return [
          for (final group in _executableSupplyGroups(MaterialSupplyRoute.make))
            _BucketRow.group(group),
        ];
    }
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
        );
      case _BucketActionType.subcontractOnly:
        await _arrangeSubcontractProduction(onlyGroupKeys: request.groupKeys);
      case _BucketActionType.makeOnly:
        await _arrangeMakeProduction(onlyGroupKeys: request.groupKeys);
      case _BucketActionType.readyCandidates:
        // 可安排桶的候选行按路线分流（自制与有子层委外并存一批）。
        final makeKeys = request.makeGroupKeys;
        if (makeKeys != null && makeKeys.isNotEmpty) {
          await _arrangeMakeProduction(onlyGroupKeys: makeKeys);
        }
        final subKeys = request.subcontractGroupKeys;
        if (subKeys != null && subKeys.isNotEmpty && mounted) {
          await _arrangeSubcontractProduction(onlyGroupKeys: subKeys);
        }
      case _BucketActionType.generatePlans:
        await _generatePlansFor(request.planDrafts ?? const []);
    }
  }

  /// 详情页「生成生产计划」：逐产品输入（数量+车间+负责人）已校验过，这里
  /// 按最新快照复核有效性后直接预览+生成——2026-09-04 用户口径：不再进
  /// 「填写生产计划单」向导页；有审核权限的用户同事务审核下达（车间任务
  /// 即时下发），无权限则生成计划草稿待审。
  Future<void> _generatePlansFor(List<_BucketPlanDraft> drafts) async {
    if (drafts.isEmpty) return;
    final analysis = _analysis;
    if (analysis == null) return;
    final productsById = {
      for (final product in analysis.products) product.analysisLineId: product,
    };
    final items = <MaterialAnalysisPlanItemInput>[];
    final validDrafts = <_BucketPlanDraft>[];
    for (final draft in drafts) {
      final product = productsById[draft.analysisLineId];
      if (product == null || !_canSelectProduct(product)) continue;
      validDrafts.add(draft);
      items.add(
        MaterialAnalysisPlanItemInput(
          analysisLineId: draft.analysisLineId,
          qty: draft.qty,
          departmentId: draft.departmentId,
          workshopName: draft.workshopName,
          workerId: draft.workerId,
        ),
      );
    }
    if (items.isEmpty) {
      context.appWarning('所选产品状态已变化，请刷新后重试');
      return;
    }
    setState(() {
      _selectedPlanLineIds
        ..clear()
        ..addAll([for (final draft in validDrafts) draft.analysisLineId]);
      for (final draft in validDrafts) {
        final controller = _batchQtyControllers[draft.analysisLineId];
        if (controller != null) {
          _systemSeededBatchQtyTexts.remove(draft.analysisLineId);
          controller.text = _bucketQtyText(draft.qty);
        }
      }
      _planPreview = null;
    });
    final approveNow = _permissions.contains(Perm.productionPlanApprove);
    setState(() => _planSubmissionApproveNow = approveNow);
    try {
      final previewPassed = await _previewPlan(items);
      if (!mounted || !previewPassed) return;
      await _generatePlan(items, approveNow: approveNow);
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
    final warehouseStock = _selectedWarehouseStock(material);
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
      if (warehouseStock != null &&
          (coverage != null || warehouseStock.publicAvailableQty > 0))
        '公共可用 ${_qty(warehouseStock.publicAvailableQty)}',
      if (material.safetyStockQty > 0) '安全保护 ${_qty(material.safetyStockQty)}',
      if (warehouseStock != null &&
          (coverage != null || warehouseStock.openSafetySupplyQty > 0))
        '公共补库在途 ${_qty(warehouseStock.openSafetySupplyQty)}',
      if ((warehouseStock?.safetyReplenishmentGapQty ?? 0) > 0)
        '公共补库待补 ${_qty(warehouseStock!.safetyReplenishmentGapQty)}',
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
              statusLabel: taskChildStage?.label,
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

  /// 节点唯一主动作。返回 null 表示该节点当前没有可显示的动作，
  /// 卡片右侧的整高操作区随之整体隐藏。
  Widget? _nodePrimaryAction(
    ThemeData theme,
    _MaterialGroup group,
    MaterialSupplyRoute? route,
  ) {
    final material = group.representative;
    final notified = _notifiedTargetOf(material);
    if (notified != null) {
      if (notified.target == MaterialSupplyRoute.make ||
          notified.target == MaterialSupplyRoute.subcontract) {
        final child = _taskChildProductOf(material);
        if (child != null &&
            child.planExecutionStatus == null &&
            _canSelectProduct(child)) {
          return FilledButton.tonalIcon(
            key: ValueKey(
              'material-arrange-production-${material.materialLineId}',
            ),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _canGenerate && !_busy
                ? () => _openPlanForProduct(child)
                : null,
            icon: const Icon(Icons.factory_outlined),
            label: const Text('安排生产'),
          );
        }
      }
      final child = notified.target == MaterialSupplyRoute.buy
          ? null
          : _taskChildProductOf(material);
      final latestPlanId = child?.latestPlanId;
      if (latestPlanId != null) {
        return _makePlanReference(theme, material, child!);
      }
      // 分批提交的补交入口：上一批在途、缺口未闭合时可直接再提交余量。
      final notifiedRoute = notified.target;
      if (notifiedRoute != null &&
          _routeBlockedBySafetyGap(group, notifiedRoute)) {
        return _disabledNodeAction(
          theme.colorScheme.error,
          Icons.policy_outlined,
          '仅采购可补安全库存',
        );
      }
      if (notifiedRoute != null &&
          notifiedRoute != MaterialSupplyRoute.make &&
          _hasSupplySubmitQty(group, notifiedRoute)) {
        return FilledButton.tonalIcon(
          key: ValueKey('material-topup-${material.materialLineId}'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _canNotify && !_busy
              ? () => _notifyRoute(notifiedRoute, onlyGroupKeys: {group.key})
              : null,
          icon: const Icon(Icons.playlist_add_rounded),
          label: Text('继续提交${notifiedRoute.label}'),
        );
      }
      if (notifiedRoute == MaterialSupplyRoute.subcontract &&
          _canViewSubcontractPreparations) {
        return FilledButton.tonalIcon(
          key: ValueKey(
            'material-open-subcontract-preparation-${material.materialLineId}',
          ),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy
              ? null
              : () {
                  final analysis = _analysis;
                  if (analysis == null) return;
                  context.push(
                    RoutePath.productionSubcontractPreparations(
                      sourceAnalysisId: analysis.analysisId,
                      sourceMaterialLineId: material.materialLineId,
                    ),
                  );
                },
          icon: const Icon(Icons.precision_manufacturing_outlined),
          label: Text(_canStartSubcontractPreparations ? '安排前置自制' : '查看前置自制'),
        );
      }
      return null;
    }
    if (material.requiredQty <= 0) {
      return null;
    }
    if (material.shortageQty <= 0) {
      return null;
    }
    if (!group.actionable) {
      return null;
    }
    if (material.confirmedRoute == null) {
      final suggestion = material.sourceSuggestion;
      // 无建议路线：主动作让位给右操作区的「选择路线」按钮（弹路线面板），
      // 这里不再重复提供入口。
      if (suggestion == null) {
        return null;
      }
      return OutlinedButton.icon(
        key: ValueKey('material-adopt-route-${material.materialLineId}'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _canRoute && !_busy
            ? () => _confirmSuggestedRoute(group)
            : null,
        icon: const Icon(Icons.check_circle_outline_rounded),
        label: Text('采用${suggestion.label}'),
      );
    }
    if (route == null || _dirtyRouteGroups.contains(group.key)) {
      return _disabledNodeAction(
        theme.colorScheme.tertiary,
        Icons.save_outlined,
        '请先保存路线',
      );
    }
    if (_routeBlockedBySafetyGap(group, route)) {
      return _disabledNodeAction(
        theme.colorScheme.error,
        Icons.policy_outlined,
        '仅采购可补安全库存',
      );
    }
    final label = switch (route) {
      MaterialSupplyRoute.buy => '提交采购',
      MaterialSupplyRoute.subcontract => '下达委外准备',
      MaterialSupplyRoute.make => '创建子件任务',
    };
    return FilledButton.tonalIcon(
      key: ValueKey('material-node-action-${material.materialLineId}'),
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: _canNotify && !_busy && _isExecutableSupplyGroup(group, route)
          ? route == MaterialSupplyRoute.make
                ? () => _arrangeMakeProduction(onlyGroup: group)
                : () => _notifyRoute(route, onlyGroupKeys: {group.key})
          : null,
      icon: Icon(
        route == MaterialSupplyRoute.make
            ? Icons.precision_manufacturing_outlined
            : Icons.notifications_active_outlined,
      ),
      label: Text(label),
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

  _StatusView _materialStatus(ThemeData theme, _MaterialGroup group) {
    final material = group.representative;
    if (material.requiredQty <= 0) {
      final view = _requirementStateView(theme, material);
      return _StatusView(view.title, view.icon, view.color);
    }
    if (!group.actionable) {
      if (material.shortageQty <= 0) {
        return _StatusView(
          '本层库存已齐',
          Icons.check_circle_outline_rounded,
          theme.colorScheme.primary,
        );
      }
      return _StatusView(
        '当前节点只读',
        Icons.lock_outline_rounded,
        theme.colorScheme.tertiary,
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
          final label = covered && executionStage.status != 'COMPLETED'
              ? '本批库存已覆盖 · ${executionStage.label}'
              : executionStage.label;
          return _StatusView(
            label,
            executionStage.icon,
            _productExecutionColor(theme, executionStage),
          );
        }
        if (covered) {
          return _StatusView(
            '本批库存已覆盖 · 自制任务状态待回传',
            Icons.inventory_2_outlined,
            theme.colorScheme.primary,
          );
        }
        return _StatusView(
          '待安排生产',
          Icons.precision_manufacturing_outlined,
          theme.colorScheme.primary,
        );
      }
      if (covered) {
        return _StatusView(
          '已齐套(库存已覆盖)',
          Icons.check_circle_outline_rounded,
          theme.colorScheme.primary,
        );
      }
      // 2026-08-18 起状态文字不再带单据编号（点击状态可弹出全链路进度，
      // 单号在进度弹窗里按步骤展示）。
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
        );
      }
      if (route == MaterialSupplyRoute.buy && safetyGap > 0) {
        return _StatusView(
          '本批需求已覆盖 · 公共补库在途 ${_qty(openSafety)} · '
          '待补 ${_qty(safetyGap)}',
          Icons.shield_outlined,
          theme.colorScheme.tertiary,
        );
      }
      return _StatusView(
        route == MaterialSupplyRoute.subcontract ? '委外准备处理中' : '等待采购入库',
        Icons.local_shipping_outlined,
        route == MaterialSupplyRoute.subcontract
            ? theme.colorScheme.secondary
            : theme.colorScheme.tertiary,
      );
    }
    // 未通知：先看路线是否确认（ADR-029 §6.1 硬门槛）。
    if (material.confirmedRoute == null) {
      return _StatusView(
        '路线待确认',
        Icons.help_outline_rounded,
        theme.colorScheme.error,
      );
    }
    if (material.lowerLevelPending) {
      return _StatusView(
        '下层缺料 · 可先创建子件任务',
        Icons.hourglass_bottom_rounded,
        theme.colorScheme.tertiary,
      );
    }
    final confirmedRoute = material.confirmedRoute;
    if (confirmedRoute != null &&
        _routeBlockedBySafetyGap(group, confirmedRoute)) {
      return _StatusView(
        '本版本仅采购路线支持公共安全补库',
        Icons.policy_outlined,
        theme.colorScheme.error,
      );
    }
    if (demandGap > 0) {
      return _StatusView(
        '本批需求待通知 ${_qty(demandGap)}',
        Icons.notifications_active_outlined,
        theme.colorScheme.tertiary,
      );
    }
    if (confirmedRoute == MaterialSupplyRoute.buy && safetyGap > 0) {
      return _StatusView(
        '本批需求已覆盖 · 待提交公共安全补库 ${_qty(safetyGap)}',
        Icons.shield_outlined,
        theme.colorScheme.tertiary,
      );
    }
    if (material.shortageQty > 0) {
      return _StatusView(
        '本批需求已覆盖 · 安全保护处理中',
        Icons.shield_outlined,
        theme.colorScheme.tertiary,
      );
    }
    return _StatusView(
      '已齐套',
      Icons.check_circle_outline_rounded,
      theme.colorScheme.primary,
    );
  }

  /// 该物料组当前有效的「已下达通知」目标（跳过已撤销 CANCELLED）。

  /// 物料类型三色角标（采购/委外/自制/待定）。与「层级 N」徽章同一套
  /// 外观（小胶囊：浅底 + 描边 + 彩色加粗字，上下内边距 2），仅颜色不同。
  Widget _typeBadge(ThemeData theme, MaterialSupplyRoute? route) {
    final (label, color) = switch (route) {
      MaterialSupplyRoute.make => ('自制', theme.colorScheme.primary),
      MaterialSupplyRoute.buy => ('采购', theme.colorScheme.tertiary),
      MaterialSupplyRoute.subcontract => ('委外', theme.colorScheme.secondary),
      null => ('待定', theme.colorScheme.error),
    };
    return _miniBadge(theme, label: label, color: color);
  }

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
