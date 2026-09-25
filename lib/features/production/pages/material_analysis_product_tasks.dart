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
  // ===== 所属仓库(V587): 三张表共用的读写口径 =====
  //
  // 为什么落在宿主状态链上: 主表、分桶详情、「父件+下层一起下单」三处都要显示并
  // 允许改同一个货品级事实。分桶页与级联页是各自独立的 StatefulWidget, 但两边的
  // `_host` 都声明成本类型, 所以把覆盖表与选择动作放这里, 三处才是同一份真相——
  // 分头实现会出现「在 A 表改完, 切到 B 表还是旧值」。

  /// 本次会话里改过的货品所属仓库(goodsId -> warehouseId, null = 已清空)。
  ///
  /// 服务端写成功后**不刷分析快照**: 所属仓库刻意不进快照指纹(服务端同款口径),
  /// 重拉快照既慢又会把别人在编的 CAS 令牌搅乱。所以本地留一份覆盖表, 读的时候
  /// 优先于快照值, 下次真正重拉分析时自然归一。
  final Map<String, String?> _owningWarehouseIdOverrides = {};
  final Map<String, String?> _owningWarehouseNameOverrides = {};

  /// 这一行该显示的所属仓库名: 先看本次会话改过没有, 再回落快照下发值。
  String? owningWarehouseNameOf(String? goodsId, String? snapshotName) {
    if (goodsId == null || goodsId.isEmpty) return snapshotName;
    if (_owningWarehouseNameOverrides.containsKey(goodsId)) {
      return _owningWarehouseNameOverrides[goodsId];
    }
    return snapshotName;
  }

  /// 这一行当前的所属仓库 id(同上口径), 供选择面板回显选中项。
  String? owningWarehouseIdOf(String? goodsId, String? snapshotId) {
    if (goodsId == null || goodsId.isEmpty) return snapshotId;
    if (_owningWarehouseIdOverrides.containsKey(goodsId)) {
      return _owningWarehouseIdOverrides[goodsId];
    }
    return snapshotId;
  }

  /// 表头筛选用的桶值: 没登记归属的行统一落到「未登记」一桶, 不建空桶。
  static const String owningWarehouseUnsetLabel = '未登记';

  /// 归属车间(V590)筛选的未学习桶标签（与「未登记」同款沉底口径）。
  static const String owningWorkshopUnsetLabel = '未学习';

  String owningWarehouseFilterValue(String? goodsId, String? snapshotName) {
    final name = owningWarehouseNameOf(goodsId, snapshotName)?.trim();
    return name == null || name.isEmpty ? owningWarehouseUnsetLabel : name;
  }

  /// 弹仓库选择面板并回写货品主档。返回 true = 真的改了(调用方据此 setState)。
  ///
  /// allowParent: true —— 所属仓库是主档归属不是过账落点, V476 的叶子仓约束不适用,
  /// 而且「成品仓库」这类合法值本身可能挂着不良子仓, 限叶子会把它挡在外面。
  Future<bool> pickOwningWarehouse(
    BuildContext context, {
    required String goodsId,
    String? currentWarehouseId,
  }) async {
    if (goodsId.isEmpty) return false;
    final names = ref.read(masterNameServiceProvider);
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: names.warehouseHierarchy
          .where((warehouse) => !warehouse.isLineSide)
          .toList(),
      initialWarehouseId: currentWarehouseId,
      title: '选择所属仓库', // TODO(l10n): 补 arb
      allowParent: true,
    );
    if (picked == null || !mounted) return false;
    final nextId = picked.isAll ? null : picked.id;
    if (nextId == currentWarehouseId) return false;
    try {
      await ref
          .read(productionPlanRepositoryProvider)
          .updateGoodsOwningWarehouses({goodsId: nextId});
    } catch (error) {
      if (!mounted) return false;
      // 用宿主 State 自己的 context 报错: 传进来的那个可能属于已被回收的行/弹窗。
      this.context.appError('所属仓库保存失败: $error'); // TODO(l10n): 补 arb
      return false;
    }
    if (!mounted) return false;
    // 名称直接取面板回传的 label, 不再二次查字典(字典没有按 id 取名的入口,
    // 而 label 就是面板刚刚展示给用户的那一个, 两者必然一致)。
    final nextName = nextId == null ? null : picked.label;
    setState(() {
      _owningWarehouseIdOverrides[goodsId] = nextId;
      _owningWarehouseNameOverrides[goodsId] = nextName;
    });
    return true;
  }

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

  /// 与流程徽章共用同一份色表（2026-09-11 起 6 档一色一步）。
  Color _productExecutionColor(ThemeData theme, ProductionFlowStage stage) =>
      productionFlowToneColor(theme, stage.tone);

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
      final supplement = material.hasPriorityMakeSupplement;
      if (isRootLine &&
          material.confirmedRoute == MaterialSupplyRoute.make &&
          !supplement) {
        continue;
      }
      if (material.shortageQty <= 0 && !supplement) continue;
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
      final futureRemainder =
          (material.sharedFuturePendingQty ?? 0) > 0 &&
          material.additionalSupplyRecommendedQty > 0 &&
          !_hasIssuedMakeOwnership(material);
      if (!supplement &&
          ((hasActiveTask && !futureRemainder) ||
              existingChild != null ||
              _hasUnlinkedIssuedPlan(material))) {
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

  /// 该委外件是否**必须先自制目标件再发外**（MAKE_THEN_OUTBOUND 两段式）。
  ///
  /// 与 [_hasProductionBomChildren] 的分工要分清：
  /// - 「BOM 上还有没有下层要办」→ 用 [_hasProductionBomChildren]（纯结构问题）；
  /// - 「父件自己走哪条通道、能不能改量」→ 用本方法。
  ///
  /// V581 起「只有一个叶子子件」的委外件虽然有下层，却**不进车间**：仓库直接把
  /// 那个子件发给委外商。服务端以 `subcontractOutboundForm` 明确告知
  /// （判据含 PER_UNIT / 投入阶段 / 子件无下层，前端无法从快照可靠推断），
  /// 旧服务端返回 null 时按原口径回退。
  bool _subcontractNeedsPreparation(
    ProductionMaterialAnalysisMaterial material,
    ProductionMaterialAnalysisView analysis,
  ) {
    if (material.isComponentOutbound) return false;
    return _hasProductionBomChildren(material, analysis);
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
        LayoutBuilder(
          builder: (context, constraints) {
            final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final cardWidth = constraints.maxWidth.clamp(0.0, 244 * textScale);
            return Wrap(
              key: const Key('material-analysis-bucket-entries'),
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s12,
              children: [
                for (final bucket in _AnalysisBucket.values)
                  SizedBox(width: cardWidth, child: _bucketEntryTile(bucket)),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 进行中与未下达分别计数；部分下达任务可同时出现在两侧。
  Widget _bucketEntryTile(_AnalysisBucket bucket) {
    final rows = _bucketRows(bucket);
    final issued = rows.where((row) => _bucketRowHasIssued(row, bucket)).length;
    final inProgress = rows
        .where((row) => _bucketRowInProgress(row, bucket))
        .length;
    final pending = rows
        .where((row) => _bucketRowHasPending(row, bucket))
        .length;
    return MaterialPreparationRouteCard(
      routeId: bucket.name,
      title: bucket == _AnalysisBucket.workshop
          ? '下达自制'
          : bucket.countLabel(_l10n),
      compactTitle: switch (bucket) {
        _AnalysisBucket.buy => '采购',
        _AnalysisBucket.subcontract => '委外',
        _AnalysisBucket.workshop => '自制',
      },
      hint: '${bucket.semanticHint(_l10n)} 黄色为进行中，红色为未下达；部分下达任务可同时计入。',
      icon: _bucketIcon(bucket),
      inProgressLabel: '进行中',
      pendingLabel: '未下达',
      inProgressCount: inProgress,
      pendingCount: pending,
      onOpen: rows.isNotEmpty && !_busy
          ? () => _openBucketDetail(
              bucket,
              initialFilter: pending == 0 && issued > 0
                  ? _PreparationTaskFilter.issued
                  : _PreparationTaskFilter.pending,
            )
          : null,
      onInProgress: inProgress > 0 && !_busy
          ? () => _openBucketDetail(
              bucket,
              initialFilter: _PreparationTaskFilter.inProgress,
            )
          : null,
      onPending: pending > 0 && !_busy ? () => _openBucketDetail(bucket) : null,
    );
  }

  IconData _bucketIcon(_AnalysisBucket bucket) => switch (bucket) {
    _AnalysisBucket.buy => Icons.shopping_cart_outlined,
    _AnalysisBucket.subcontract => Icons.precision_manufacturing_outlined,
    _AnalysisBucket.workshop => Icons.factory_outlined,
  };

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

  bool _bucketRowInProgress(_BucketRow row, _AnalysisBucket bucket) {
    final product = row.product;
    if (product != null) {
      final status = product.planExecutionStatus?.trim().toUpperCase();
      if (status != null && status.isNotEmpty) {
        return const {
          'SUBMITTED',
          'APPROVED',
          'WAITING',
          'READY',
          'DISPATCHED',
          'IN_PROGRESS',
        }.contains(status);
      }
      // Old snapshots must still have a real plan fact; fully transferred
      // demand alone does not prove that a plan is running.
      return product.approvedQty > 0 ||
          product.submittedQty > 0 ||
          product.latestPlanId?.isNotEmpty == true;
    }
    final route = bucket.supplyRoute;
    if (route == null) return false;
    return row.group?.paths.any(
          (path) => path.notifiedTargets.any((target) {
            if (target.target != route) return false;
            final status = target.status?.trim().toUpperCase();
            if (status != null && status.isNotEmpty) {
              return const {'OPEN', 'CREATED', 'IN_PROGRESS'}.contains(status);
            }
            // Missing legacy action status may only use an explicit ongoing
            // flow stage, never an already-stocked or unknown state.
            return const {
              'BUY_REQUESTED',
              'BUY_PENDING_FINANCE',
              'BUY_WAIT_RECEIPT',
              'BUY_WAIT_IQC',
              'BUY_WAIT_STOCK_IN',
              'SC_REQUESTED',
              'SC_PENDING_FINANCE',
              'SC_WAIT_OUTBOUND',
              'SC_WAIT_RETURN',
              'SC_WAIT_IQC',
              'SC_WAIT_STOCK_IN',
            }.contains(path.flowStage?.trim().toUpperCase());
          }),
        ) ??
        false;
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

  /// ADR-099 父层级追加（用户口径 2026-09-21「即使采购、委外已下达甚至已处理，
  /// 还是可以追加下单；多下的属于公共的」）：已下达段里仍可再下的行。
  ///
  /// 采购 / 直接外发委外 = 路线已确认且未被挡住（不看余量：填的就是追加量，
  /// 服务端按超量分账为公共备货，未处理的申请就地改大、已处理的另立）；
  /// 下达车间 = 需求已全部转入计划、服务端允许再下一批纯公共备货产出的产品行
  /// （`canIssueSurplus`；委外前置自制锚点不放开，它的追加走委外超量通道）；
  /// 自制候选不放开（服务端对已覆盖候选拒绝建锚）。
  bool _bucketRowCanAppend(_BucketRow row, _AnalysisBucket bucket) {
    final analysis = _analysis;
    if (analysis == null || !_bucketRowHasIssued(row, bucket)) return false;
    final product = row.product;
    if (product != null) {
      return bucket == _AnalysisBucket.workshop &&
          _canGenerate &&
          product.canIssueSurplus &&
          !product.canSchedule &&
          product.sourceType != 'SUBCONTRACT_MAKE' &&
          product.sourceType != 'AGGREGATE_MAKE' &&
          _productRouteConfirmedForWorkshop(product);
    }
    final group = row.group;
    final route = bucket.supplyRoute;
    if (group == null || route == null || !_canNotify) return false;
    if (route == MaterialSupplyRoute.subcontract &&
        _subcontractNeedsPreparation(group.representative, analysis)) {
      return false;
    }
    // 余量为 0 时填的全是公共备货，服务端要超量下达权限——没有的账号这里就
    // 不给勾，不让人填完再被拒。
    return group.representative.confirmedRoute == route &&
        _isExecutableSupplyGroup(group, route, allowExtra: true) &&
        (_canOverSupply || _residualSubmitQty(group, route) > 0.0001);
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
  Future<void> _openBucketDetail(
    _AnalysisBucket bucket, {
    _PreparationTaskFilter initialFilter = _PreparationTaskFilter.pending,
  }) async {
    if (_busy) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _MaterialAnalysisBucketPage(
          host: this,
          bucket: bucket,
          initialFilter: initialFilter,
        ),
      ),
    );
  }

  /// 分桶详情页发起的批量动作（详情页保持在前台时执行）：数量确认弹窗、
  /// 分批、幂等、409 恢复和计划向导仍由宿主页状态统一编排——实现只此一份，
  /// 避免详情页与宿主页各自漂移；弹层经 root Navigator 显示在详情页之上，
  /// 动作完成后详情页按最新快照刷新行集。
  // Only successful workshop issuance returns true to close its bucket after
  // the result dialog. Procurement/subcontract actions always keep their page.
  // [silent] = 父件段由「一起下单」弹窗编排（ADR-081）：成功提示与结果弹层
  // 由弹窗统一汇报，避免一次一键下单连弹多层结果。
  Future<bool> _executeBucketAction(
    _BucketActionRequest request, {
    bool silent = false,
  }) async {
    // 遮罩挂在 _notifyRoute 的纯网络段（数量确认弹窗之后），见 supply_actions。
    //
    // 2026-09-14（ADR-081）：返回值语义收敛为**本次命令是否提交成功**。
    // 原来采购/委外两支丢掉结果直接落到末尾的 `return false`，用的是
    // 「要不要关掉分桶页」那套语义——而 ADR-081 的父件段拿同一个返回值判定
    // 「父件下达成功没有」，于是从「下达委外」进级联页时父件明明已经提交，
    // 编排却永远报「父件未提交成功，下层未动」，下层一行都下不出去。
    // 「要不要关页」改由调用方 [_run] 按 request.type 自己决定。
    switch (request.type) {
      // allowExtra：分桶页明确勾选的行即使余量为 0 也能提交——已下达段的追加
      //（ADR-099），服务端按超量分账为公共备货。
      case _BucketActionType.buy:
        return await _notifyRoute(
              MaterialSupplyRoute.buy,
              onlyGroupKeys: request.groupKeys,
              qtyByActionGroupKey: request.qtyByActionGroupKey,
              silent: silent,
              allowExtra: true,
            ) !=
            null;
      case _BucketActionType.subcontractOnly:
        return _arrangeSubcontractProduction(
          onlyGroupKeys: request.groupKeys,
          qtyByActionGroupKey: request.qtyByActionGroupKey,
          silent: silent,
          allowExtra: true,
        );
      case _BucketActionType.createProductionPlans:
        // 2026-09-05 ADR-071：车间桶单按钮「创建生产计划」——所有自制行
        // 一视同仁，单次原子调用服务端 issue-plans（候选行建子件任务、逐行
        // 出计划、有审核权限同事务审核下达）；任一行失败整体回滚，不再有
        // 「已建子件、未出计划」的残留行。
        return _issueWorkshopPlans(
          candidateInputs: request.candidateInputs,
          planDrafts: request.planDrafts,
          silent: silent,
        );
    }
  }

  /// 下达车间（ADR-071）：把分桶页收集的行输入交给服务端原子执行。数量/
  /// 车间/负责人在分桶页已校验；这里组幂等键、处理 409 冲突恢复并展示
  /// 生成结果（计划单/领料单一屏）。齐不齐料由车间侧执行段自行判断等待。
  /// [silent] = 下层办齐编排在调用（ADR-081）：跳过成功提示与生成结果弹层，
  /// 由编排方在最后统一汇报，避免一次一键下单弹出多层结果。
  Future<bool> _issueWorkshopPlans({
    List<_BucketCandidatePlanInput>? candidateInputs,
    List<_BucketPlanDraft>? planDrafts,
    bool silent = false,
  }) async {
    final analysis = _analysis;
    final warehouseId = _warehouseId;
    final candidates = candidateInputs ?? const <_BucketCandidatePlanInput>[];
    final products = planDrafts ?? const <_BucketPlanDraft>[];
    if (analysis == null || warehouseId == null) return false;
    if (candidates.isEmpty && products.isEmpty) return false;
    final lines = <MaterialAnalysisIssueLine>[
      for (final input in candidates)
        MaterialAnalysisIssueLine(
          materialLineId: input.materialLineId,
          qty: input.qty,
          allowedOverproductionRate: input.allowedOverproductionRate,
          departmentId: input.departmentId,
          workshopName: input.workshopName,
          workerId: input.workerId,
          publicSurplusOnly: input.publicSurplusOnly,
        ),
      for (final draft in products)
        MaterialAnalysisIssueLine(
          analysisLineId: draft.analysisLineId,
          qty: draft.qty,
          allowedOverproductionRate: draft.allowedOverproductionRate,
          departmentId: draft.departmentId,
          workshopName: draft.workshopName,
          workerId: draft.workerId,
          publicSurplusOnly: draft.publicSurplusOnly,
        ),
    ];
    if (lines.any(
      (line) => line.materialLineId != null
          ? _materialAggregateOwnsLine(line.materialLineId!)
          : line.analysisLineId != null &&
                _materialAggregateOwnsProductLine(line.analysisLineId!),
    )) {
      context.appWarning('此来源已有未提交的汇总总量，请在汇总行下达或撤销草稿');
      return false;
    }
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
      if (!mounted) return false;
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
      _lastIssuedPlans = plans;
      if (silent) return true;
      // ADR-104：追加并入了还没开工的原计划(同一单号)时不说「已生成」——那会让人去找
      // 一张不存在的新单。全部并入 / 部分并入 / 全部新建三种口径分开说。
      final mergedCount = plans.where((plan) => plan.mergedIntoExisting).length;
      final allMerged = plans.isNotEmpty && mergedCount == plans.length;
      context.appSuccess(
        allMerged
            ? (approved ? '追加数量已加到原生产计划和车间工单' : '追加数量已并入原生产计划草稿，待审核')
            : approved
            ? plans.any((plan) => plan.drawDocuments.isNotEmpty)
                  ? '生产计划已审核下达，物料提货单已生成'
                  : mergedCount > 0
                  ? '生产计划已审核下达；其中 $mergedCount 张是并入原计划'
                  : '生产计划已审核下达；当前待料，齐套后自动生成提货单'
            : mergedCount > 0
            ? '生产计划已生成并提交审批；其中 $mergedCount 张是并入原计划草稿'
            : '生产计划已生成并提交审批',
      );
      await _showGeneratedPlans(plans);
      return true;
    } catch (error) {
      if (!mounted) return false;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '创建生产计划',
      )) {
        if (mounted) setState(() => _setGenerating(false));
        return false;
      }
      if (!mounted) return false;
      setState(() => _setGenerating(false));
      context.appError(
        productionErrorMessage(error, fallback: '创建生产计划失败，请刷新后重试'),
        force: true,
      );
      return false;
    } finally {
      // 兜底清场（2026-09-14，与 _notifyRoute 同一口径）：_generating 只要有一条
      // 分支忘了清，`_busy` 就永久为真——整页按钮（含「取消分析」「刷新分析」）
      // 全部变灰，用户看到的是「点了没反应」，且刷新页面前好不了。
      if (mounted && (_generating || _planSubmissionApproveNow)) {
        setState(() {
          _setGenerating(false);
          _planSubmissionApproveNow = false;
        });
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
      if (material.hasPriorityMakeSupplement)
        '让料后可补自制 ${_qty(material.priorityMakeSupplementQty)}（已扣除已有补供）',
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
          if (!group.actionable && !material.hasPriorityMakeSupplement)
            _inactiveNodeHint(theme, material),
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
    if (material.hasPriorityMakeSupplement) {
      return _StatusView(
        '让料后待补自制 ${_qty(material.priorityMakeSupplementQty)}',
        Icons.factory_outlined,
        theme.colorScheme.tertiary,
        facetKey: 'pendingIssue',
      );
    }
    if ((material.sharedFuturePendingQty ?? 0) > 0) {
      return _StatusView(
        '公共已认领未实收 ${_qty(material.sharedFuturePendingQty)} · 尚需下达 ${_qty(material.additionalSupplyRecommendedQty)}',
        Icons.schedule_outlined,
        theme.colorScheme.secondary,
        facetKey: 'inTransit',
      );
    }
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
  Widget _factChip(
    ThemeData theme,
    IconData icon,
    String label, {
    double? height,
  }) => Container(
    constraints: const BoxConstraints(maxWidth: 280),
    // 指定 height（如顶部与「主仓库」字段等高）时内容垂直居中。
    height: height,
    alignment: height == null ? null : Alignment.center,
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
