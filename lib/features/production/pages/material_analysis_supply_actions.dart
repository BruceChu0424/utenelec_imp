part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisSupplyActionsState
    extends _MaterialAnalysisCandidatesState {
  /// Read-only defaults are frozen for this analysis and never become writes on load.
  Future<void> _prefillRememberedRoutes(
    ProductionMaterialAnalysisView view,
  ) async {
    if (!mounted ||
        !identical(_analysis, view) ||
        !_canRoute ||
        !_permissions.contains(Perm.productionMaterialAnalysisView)) {
      return;
    }
    final scope = _routeMemoryScopeKey();
    if (_routeMemoryScope != null && _routeMemoryScope != scope) {
      _clearRememberedRoutes();
    }
    _routeMemoryScope = scope;
    final goodsIds = <String>{
      for (final material in view.materials)
        if (material.goodsId?.trim().isNotEmpty == true)
          material.goodsId!.trim(),
      for (final product in view.products)
        if (product.goodsId?.trim().isNotEmpty == true) product.goodsId!.trim(),
    }..removeAll(_routeMemoryResolvedGoods);
    if (goodsIds.isEmpty) return;
    final orderedIds = goodsIds.toList()..sort();
    final pendingKey =
        '${view.analysisId}|${view.version}|${view.fingerprint}|'
        '$scope|${orderedIds.join(',')}';
    if (_routeMemoryPendingKey == pendingKey) return;
    final generation = ++_routeMemoryGeneration;
    setState(() {
      _loadingRouteMemory = true;
      _routeMemoryPendingKey = pendingKey;
    });
    bool current() =>
        mounted &&
        generation == _routeMemoryGeneration &&
        identical(_analysis, view) &&
        _routeMemoryScopeKey() == scope &&
        _canRoute;
    try {
      final memories = await ref
          .read(productionPlanRepositoryProvider)
          .materialAnalysisLastRoutes(goodsIds);
      if (!current()) return;
      setState(() {
        for (final entry in memories.entries) {
          if (!goodsIds.contains(entry.key)) continue;
          for (final memory in entry.value) {
            _rememberedRouteDimensions.putIfAbsent((
              goodsId: entry.key,
              colorId: memory.colorId?.trim().isNotEmpty == true
                  ? memory.colorId!.trim()
                  : null,
              unitId: memory.unitId?.trim().isNotEmpty == true
                  ? memory.unitId!.trim()
                  : null,
            ), () => memory.route);
          }
        }
        _routeMemoryResolvedGoods.addAll(goodsIds);
        if (_serverRefreshNotice == _l10n.materialRouteMemoryUnavailable) {
          _serverRefreshNotice = null;
        }
        _invalidateBucketRowsCache();
      });
    } catch (_) {
      if (current()) {
        setState(
          () => _serverRefreshNotice ??= _l10n.materialRouteMemoryUnavailable,
        );
      }
    } finally {
      if (current()) {
        setState(() {
          _loadingRouteMemory = false;
          _routeMemoryPendingKey = null;
        });
      }
    }
  }

  List<List<T>> _chunked<T>(List<T> values) {
    final result = <List<T>>[];
    for (
      var start = 0;
      start < values.length;
      start += _MaterialAnalysisPageBase._requestChunkSize
    ) {
      final proposedEnd = start + _MaterialAnalysisPageBase._requestChunkSize;
      final end = proposedEnd < values.length ? proposedEnd : values.length;
      result.add(values.sublist(start, end));
    }
    return result;
  }

  void _clearBulkOperation() {
    _bulkOperationLabel = null;
    _bulkOperationCompleted = 0;
    _bulkOperationTotal = 0;
  }

  Future<void> _saveRoutes({Set<String>? onlyGroupKeys}) async {
    final analysis = _analysis;
    if (analysis == null || !_canRoute || _savingRoutes) return;
    final groups = {
      for (final group in _materialGroups(analysis)) group.key: group,
    };
    final changes = <_PendingRouteDecision>[];
    final pendingDrafts = <String, MaterialSupplyRoute>{};
    for (final key in _dirtyRouteGroups.where(
      (key) => onlyGroupKeys == null || onlyGroupKeys.contains(key),
    )) {
      final group = groups[key];
      final route = _routeDraft[key];
      if (group == null || route == null) continue;
      pendingDrafts[key] = route;
      final actionGroupKey = group.representative.actionGroupKey;
      if (actionGroupKey != null) {
        changes.add(
          _PendingRouteDecision(
            groupKey: key,
            decision: MaterialRouteDecision(
              actionGroupKey: actionGroupKey,
              route: route,
            ),
          ),
        );
      } else {
        changes.addAll([
          for (final path in group.paths)
            _PendingRouteDecision(
              groupKey: key,
              decision: MaterialRouteDecision(
                materialLineId: path.materialLineId,
                route: route,
              ),
            ),
        ]);
      }
    }
    if (changes.isEmpty) {
      context.appInfo('没有待确认的路线变更');
      return;
    }
    changes.sort((left, right) {
      final leftMaterial = groups[left.groupKey]!.representative;
      final rightMaterial = groups[right.groupKey]!.representative;
      final leftDepth = leftMaterial.isRootSupply ? 0 : leftMaterial.level;
      final rightDepth = rightMaterial.isRootSupply ? 0 : rightMaterial.level;
      // Confirm descendants before an external parent/root deactivates their next-chunk lookup.
      final byDepth = rightDepth.compareTo(leftDepth);
      return byDepth != 0 ? byDepth : left.identity.compareTo(right.identity);
    });
    var current = analysis;
    var completed = 0;
    final batches = _chunked(changes);
    setState(() {
      _savingRoutes = true;
      _bulkOperationLabel = '正在保存物料路线';
      _bulkOperationCompleted = 0;
      _bulkOperationTotal = changes.length;
    });
    try {
      for (final batch in batches) {
        final key = businessIdempotencyKey(
          'material-analysis-routes-chunk',
          [
            current.analysisId,
            current.version,
            current.fingerprint,
            for (final change in batch)
              '${change.decision.actionGroupKey ?? change.decision.materialLineId}:'
                  '${change.decision.route.wireName}:'
                  '${change.decision.reason ?? ''}',
          ].join('|'),
        );
        current = await ref
            .read(productionPlanRepositoryProvider)
            .updateMaterialAnalysisRoutes(
              analysis: current,
              idempotencyKey: key,
              decisions: [for (final change in batch) change.decision],
            );
        completed += batch.length;
        if (!mounted) return;
        setState(() => _bulkOperationCompleted = completed);
      }
      if (!mounted) return;
      setState(() {
        _savingRoutes = false;
        _clearBulkOperation();
        _applyAnalysisPreservingRouteDrafts(current);
        _selectedMaterialGroupKeys.removeAll(
          changes.take(completed).map((change) => change.groupKey),
        );
      });
      context.appSuccess(
        batches.length == 1 ? '物料路线已确认' : '物料路线已分 ${batches.length} 批全部确认',
      );
    } catch (error) {
      if (!mounted) return;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '批量保存物料路线',
      )) {
        if (!mounted) return;
        setState(() {
          _savingRoutes = false;
          _clearBulkOperation();
        });
        return;
      }
      if (!mounted) return;
      final remainingGroupKeys = changes
          .skip(completed)
          .map((change) => change.groupKey)
          .toSet();
      setState(() {
        _savingRoutes = false;
        _clearBulkOperation();
        _applyAnalysisPreservingRouteDrafts(current);
        _selectedMaterialGroupKeys.removeAll(
          changes.take(completed).map((change) => change.groupKey),
        );
        final currentKeys = _materialGroups(
          current,
        ).map((group) => group.key).toSet();
        for (final groupKey in remainingGroupKeys) {
          final draft = pendingDrafts[groupKey];
          if (draft == null || !currentKeys.contains(groupKey)) continue;
          _routeDraft[groupKey] = draft;
          _dirtyRouteGroups.add(groupKey);
        }
        _invalidateBucketRowsCache();
      });
      final message = productionErrorMessage(error, fallback: '路线确认失败，请刷新后重试');
      context.appError(
        completed == 0
            ? message
            : '已保存 $completed / ${changes.length} 条；剩余路线仍保留在页面，可直接重试。$message',
        force: true,
      );
    }
  }

  /// Dropdown changes are local. Only selected task identities are submitted.
  Future<void> _createSelectedRoutes() async {
    if (_loadingRouteMemory) {
      context.appInfo(_l10n.materialRouteMemoryLoading);
      return;
    }
    final analysis = _analysis;
    if (analysis == null || !_canRoute || _busy) return;
    final groups = _materialGroups(analysis)
        .where(
          (group) =>
              _selectedMaterialGroupKeys.contains(group.key) &&
              _canEditMaterialRoute(group) &&
              _routeGroupSelectable(group),
        )
        .toList(growable: false);
    if (groups.isEmpty) return;
    final decisions = {
      for (final group in groups) group.key: _draftRoute(group),
    };
    // A poll must not turn a stale dropdown decision into a different write.
    if (!identical(analysis, _analysis) || !_canRoute || _busy) {
      context.appWarning(_l10n.materialRouteChangedRetry);
      return;
    }
    setState(() {
      for (final group in groups) {
        _routeDraft[group.key] = decisions[group.key]!;
        _dirtyRouteGroups.add(group.key);
      }
      _invalidateBucketRowsCache();
    });
    await _saveRoutes(onlyGroupKeys: decisions.keys.toSet());
  }

  /// 指定路线下「仍在途」的已提交量估算：汇总各路径下游引用中
  /// OPEN/CREATED/IN_PROGRESS 任务的分摊量（已撤销/已完成不计）。
  /// 仅用于界面默认值与提示；服务端提交时按实时「缺口 − 在途」复核。
  /// 历史投影缺分摊量（allocatedQty 为空）时保守按全额在途处理，
  /// 避免把「已整单提交」误当成可再次全量提交。
  double _openSubmittedQty(_MaterialGroup group, MaterialSupplyRoute route) {
    var total = 0.0;
    for (final path in group.paths) {
      for (final target in path.notifiedTargets) {
        if (target.target != route || target.isRootOutput) continue;
        final status = target.status;
        if (status == 'CANCELLED' || status == 'DONE') continue;
        total +=
            target.allocatedQty ??
            (path.shortageQty > 0 ? path.shortageQty : 0);
      }
    }
    return total;
  }

  /// 本组尚未被已分配现货或 exact 到货权益覆盖的生产需求合计。
  /// shortageQty 仍可能包含安全库存硬保护，不能再作为采购需求上限。
  double _groupDemandSupplyGapQty(_MaterialGroup group) => group.paths.fold(
    0.0,
    (sum, path) =>
        sum + (path.demandSupplyGapQty > 0 ? path.demandSupplyGapQty : 0),
  );

  /// 剩余本批生产需求 = demandSupplyGapQty − 已在途生产需求（下限 0）。
  /// 公共安全库存补库是另一条显式数量切片，不得混入本值。
  double _residualSubmitQty(_MaterialGroup group, MaterialSupplyRoute route) {
    final residual =
        _groupDemandSupplyGapQty(group) - _openSubmittedQty(group, route);
    return residual > 0 ? residual : 0;
  }

  /// Each path repeats the authoritative main-warehouse budget. Never sum it
  /// across BOM roots or rebuild it from the selected/default leaf warehouse.
  double _groupSafetyReplenishmentGapQty(_MaterialGroup group) => group.paths
      .map((material) => material.mainWarehouseSafetyReplenishmentGapQty)
      .fold(
        0.0,
        (largest, quantity) => quantity > largest ? quantity : largest,
      );

  double _groupOpenSafetySupplyQty(_MaterialGroup group) => group.paths
      .map((material) => material.mainWarehouseOpenSafetySupplyQty)
      .fold(
        0.0,
        (largest, quantity) => quantity > largest ? quantity : largest,
      );

  bool _routeBlockedBySafetyGap(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) =>
      route != MaterialSupplyRoute.buy &&
      _groupSafetyReplenishmentGapQty(group) > 0;

  bool _hasRootStockToAllocate(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) =>
      route != MaterialSupplyRoute.make &&
      group.paths.any(
        (material) =>
            material.isRootSupply &&
            material.confirmedRoute == route &&
            material.requiredQty > 0 &&
            material.allocatedAvailableQty > 0,
      );

  bool _hasSupplySubmitQty(_MaterialGroup group, MaterialSupplyRoute route) =>
      _residualSubmitQty(group, route) > 0 ||
      _hasRootStockToAllocate(group, route) ||
      (route != MaterialSupplyRoute.make &&
          _groupCoveredByStock(group, route)) ||
      (route == MaterialSupplyRoute.buy &&
          _groupSafetyReplenishmentGapQty(group) > 0);

  /// 仓库现货已覆盖需求（2026-09-06 用户口径：仓库够货不跳过采购/委外流程）。
  ///
  /// 需求仍在行内（required>0，未整批转出）、本批缺口与剩余下达量均已归零、
  /// 且该路线尚无未撤销的下游行动：仍进对应桶的「未下达」段——计划员可按
  /// 富余量下单（下达数量默认 0，填写的量经公共超量备货通道下达，不绑定本
  /// 需求；仓库余量维持与需求的现货绑定，剩余新采购的进富余池）。
  /// 已转出（required=0）或已有行动（含已完成 DONE）的行不在此列——后者在
  /// 「已下达」段沿单据链跟踪。
  bool _groupCoveredByStock(_MaterialGroup group, MaterialSupplyRoute route) {
    final material = group.representative;
    if (!material.actionable || material.requiredQty <= 0) return false;
    final hasIssuedOnRoute = group.paths.any(
      (path) => path.notifiedTargets.any(
        (target) => target.target == route && target.status != 'CANCELLED',
      ),
    );
    return !hasIssuedOnRoute &&
        material.demandSupplyGapQty <= 0 &&
        material.shortageQty <= 0;
  }

  bool _isExecutableSupplyGroup(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) =>
      (group.actionable || _hasRootStockToAllocate(group, route)) &&
      _planningBlockForGroup(group) == null &&
      group.paths.every(_hasResolvedMaterialSource) &&
      !group.paths.any(_hasUnlinkedIssuedPlan) &&
      group.representative.confirmedRoute == route &&
      _draftRoute(group) == route &&
      !_dirtyRouteGroups.contains(group.key) &&
      !_routeBlockedBySafetyGap(group, route) &&
      _hasSupplySubmitQty(group, route);

  /// 当前路线下仍可执行（路线已确认、有真实余量、未被通知闭合）的操作组。
  List<_MaterialGroup> _executableSupplyGroups(MaterialSupplyRoute route) {
    final analysis = _analysis;
    if (analysis == null) return const [];
    return _materialGroups(analysis)
        .where((group) => _isExecutableSupplyGroup(group, route))
        .toList(growable: false);
  }

  /// 本批生产需求覆盖口径 =（需求 − demandSupplyGapQty）÷ 需求。
  /// 安全库存、公共补库与生产执行分别展示，不混进这个比例。
  ({double covered, double ratio})? _coverageOf(
    ProductionMaterialAnalysisMaterial material,
  ) {
    if (material.requiredQty <= 0) return null;
    final covered = (material.requiredQty - material.demandSupplyGapQty).clamp(
      0.0,
      material.requiredQty,
    );
    return (
      covered: covered,
      ratio: (covered / material.requiredQty).clamp(0.0, 1.0),
    );
  }

  /// A zero requirement is not one generic “no replenishment” state. The
  /// server owns the reason; every branch includes both the cause and the next
  /// useful recovery path so staff do not have to infer it from a row of zeroes.
  ({String title, String detail, IconData icon, Color color})
  _requirementStateView(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
  ) => switch (material.effectiveRequirementState) {
    MaterialRequirementState.delegatedToMakeChild => (
      title: '需求已转交自制子任务',
      detail: '本节点不再重复备料',
      icon: Icons.account_tree_outlined,
      color: theme.colorScheme.primary,
    ),
    MaterialRequirementState.delegatedToSubcontractPreparation => (
      title: '需求已由委外前置自制接管',
      detail: '本节点不再重复采购或生产；请在委外订货进度中跟踪',
      icon: Icons.precision_manufacturing_outlined,
      color: theme.colorScheme.primary,
    ),
    MaterialRequirementState.inactiveParentCovered => (
      title: '上级件已由合格库存覆盖',
      detail: '本节点本批不激活；上级出现新缺口后会自动重算',
      icon: Icons.inventory_2_outlined,
      color: theme.colorScheme.primary,
    ),
    MaterialRequirementState.inactiveParentRoute => (
      title: '上级路线不展开本节点',
      detail: '若上级改为自制或供料委外，刷新后会重新计算',
      icon: Icons.route_outlined,
      color: theme.colorScheme.onSurfaceVariant,
    ),
    MaterialRequirementState.inactiveReference => (
      title: '参考节点，不形成本批备料需求',
      detail: '如需参与生产备料，请核对 BOM 控制阶段',
      icon: Icons.visibility_outlined,
      color: theme.colorScheme.onSurfaceVariant,
    ),
    MaterialRequirementState.transferredToPlan => (
      title: '本批需求已转入生产计划',
      detail: '请从关联生产计划继续跟踪领料与执行',
      icon: Icons.assignment_turned_in_outlined,
      color: theme.colorScheme.secondary,
    ),
    MaterialRequirementState.inactive => (
      title: '本批需求未激活',
      detail: '刷新后仍无需求时，请核对上级路线和 BOM',
      icon: Icons.pause_circle_outline_rounded,
      color: theme.colorScheme.onSurfaceVariant,
    ),
    MaterialRequirementState.active => (
      title: '需求状态已变化',
      detail: '当前数量与状态不一致，请刷新物料分析',
      icon: Icons.sync_problem_outlined,
      color: theme.colorScheme.error,
    ),
  };

  String? _delegatedOwnerLabel(ProductionMaterialAnalysisMaterial material) {
    final sourceRef = material.delegatedToSourceRef?.trim();
    if (sourceRef?.isNotEmpty == true) return sourceRef;
    final analysisLineId = material.delegatedToAnalysisLineId?.trim();
    if (analysisLineId == null || analysisLineId.isEmpty) return null;
    final shortId = analysisLineId.length <= 8
        ? analysisLineId
        : analysisLineId.substring(0, 8);
    return '自制子任务 $shortId';
  }

  String? _delegatedChildStatusLabel(
    ProductionMaterialAnalysisMaterial material,
  ) {
    if (material.effectiveRequirementState !=
        MaterialRequirementState.delegatedToMakeChild) {
      return null;
    }
    final child = _taskChildProductOf(material);
    if (child == null) return null;
    final executionStage = _productExecutionStage(child);
    if (executionStage != null) return executionStage.displayLabel;
    // 2026-09-06 词表：未下达子件任务显示「等待下达车间」。
    return '等待下达车间';
  }

  Widget _semanticFact(
    String label, {
    Key? key,
    TextStyle? style,
    int? maxLines,
  }) => Semantics(
    key: key,
    container: true,
    label: label,
    child: ExcludeSemantics(
      child: Text(
        label,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: style,
      ),
    ),
  );

  /// V458/ADR-062 修订一②：有子层级委外件与自制完全同构的第二段——「下达委外」
  /// 建 SUBCONTRACT_MAKE 前置自制任务后**留在本页**，已可生产的委外子件自动
  /// 勾选并预填「最多可生产量」，员工核对后点底部「安排子件生产」进入计划
  /// 向导；同批无子层委外件仍由服务端立即合并生成委外申请并通知委外部。
  Future<void> _arrangeSubcontractProduction({
    Set<String>? onlyGroupKeys,
    Map<String, String>? qtyByActionGroupKey,
  }) async {
    final analysis = _analysis;
    if (analysis == null || !_canNotify || _notifyingRoute != null) return;
    final groups = onlyGroupKeys != null
        ? _executableSupplyGroups(MaterialSupplyRoute.subcontract)
              .where((group) => onlyGroupKeys.contains(group.key))
              .toList(growable: false)
        : const <_MaterialGroup>[];
    if (groups.isEmpty) {
      context.appInfo('请先勾选要下达的委外件');
      return;
    }
    final view = await _notifyRoute(
      MaterialSupplyRoute.subcontract,
      onlyGroupKeys: {for (final group in groups) group.key},
      qtyByActionGroupKey: qtyByActionGroupKey,
    );
    if (!mounted || view == null) return;
    final requestedLineIds = {
      for (final group in groups) group.representative.materialLineId,
    };
    var created = 0;
    var readySelected = 0;
    var waiting = 0;
    var needPermission = 0;
    setState(() {
      for (final material in view.materials) {
        if (!requestedLineIds.contains(material.materialLineId)) continue;
        // 无子层委外件没有子件任务：已直接合并生成委外申请，不进入两段式。
        final child = _subcontractMakeChildProductOf(material);
        if (child == null) continue;
        created++;
        if (!_canSelectProduct(child)) {
          waiting++;
          continue;
        }
        if (!_canGenerate) {
          needPermission++;
          continue;
        }
        _selectedPlanLineIds.add(child.analysisLineId);
        _seedSuggestedPlanBatchQty(child);
        readySelected++;
      }
    });
    // 全部为无子层时 _notifyRoute 的「合并为 N 张委外申请」提示已足够。
    if (created == 0) return;
    final parts = <String>[
      _l10n.materialPreparedChildCreated(created),
      if (readySelected > 0) _l10n.materialPreparedChildNext,
      if (waiting > 0) '$waiting 个子件状态已变化，请刷新后核对',
      if (needPermission > 0) _l10n.materialPreparedChildNeedPlanner,
    ];
    context.appSuccess(parts.join('；'));
  }

  /// 该分析节点在当前快照内是否还有下层节点（与服务端「有子层级委外件」
  /// 的 BOM 分流同向：分析节点来自货品 BOM，节点有子 ⇒ 货品必有活动子层，
  /// 不会把无子层叶子误当两段式自动下达）。经父节点索引判定（原为全表扫描）。
  bool _analysisMaterialHasChildren(
    ProductionMaterialAnalysisMaterial material,
  ) {
    final analysis = _analysis;
    if (analysis != null && material.isRootSupply) {
      final indexes = _analysisIndexes(analysis);
      return indexes
                  .productsById[material.analysisLineId]
                  ?.hasProductionMaterialChildren ==
              true ||
          (indexes.materialsByProduct[material.analysisLineId]?.any(
                (node) => !node.isRootSupply && node.level == 1,
              ) ??
              false);
    }
    final nodeKey = material.nodeKey;
    if (analysis == null || nodeKey == null || nodeKey.isEmpty) return false;
    return _analysisIndexes(analysis).childrenByParentNodeKey.containsKey((
      analysisLineId: material.analysisLineId,
      parentNodeKey: nodeKey,
    ));
  }

  List<_SupplyNotificationTarget> _notificationTargetsForGroups(
    Iterable<_MaterialGroup> groups,
  ) {
    final targets = <_SupplyNotificationTarget>[];
    final seenTargets = <String>{};
    for (final group in groups) {
      final actionGroupKey = group.representative.actionGroupKey;
      if (actionGroupKey != null) {
        final identity = 'GROUP|$actionGroupKey';
        if (seenTargets.add(identity)) {
          targets.add(
            _SupplyNotificationTarget(actionGroupKey: actionGroupKey),
          );
        }
        continue;
      }
      for (final path in group.paths) {
        final identity = 'LINE|${path.materialLineId}';
        if (seenTargets.add(identity)) {
          targets.add(
            _SupplyNotificationTarget(materialLineId: path.materialLineId),
          );
        }
      }
    }
    targets.sort((left, right) => left.identity.compareTo(right.identity));
    return targets;
  }

  Future<ProductionMaterialAnalysisView?> _notifyRoute(
    MaterialSupplyRoute route, {
    Set<String>? onlyGroupKeys,
    Map<String, String>? qtyByActionGroupKey,
  }) async {
    final analysis = _analysis;
    if (analysis == null || !_canNotify || _notifyingRoute != null) {
      return null;
    }
    final groups = _executableSupplyGroups(route)
        .where(
          (group) => onlyGroupKeys == null || onlyGroupKeys.contains(group.key),
        )
        .toList(growable: false);
    if (groups.isEmpty) {
      context.appInfo('请先勾选要提交的${route.label}缺料');
      return null;
    }
    if (_dirtyRouteGroups.isNotEmpty) {
      context.appWarning('请先确认路线，再通知对应部门');
      return null;
    }
    final targets = _notificationTargetsForGroups(groups);
    // MAKE / 有子层委外当前仍是整节点 ownership，显式创建
    // child 时必须全量接管剩余需求。下层未齐不再阻止创建；
    // child 后续可按 maxSchedulableQty 先排车间，审批后进 WAITING。
    // 无子层委外和采购仍可分批/公共超量。
    List<MaterialSupplyQuantityInput>? quantities;
    if (route == MaterialSupplyRoute.make) {
      quantities = _fullResidualSupplyQuantities(route, targets);
    } else if (route == MaterialSupplyRoute.subcontract) {
      quantities = await _resolveSubcontractQuantities(
        groups,
        qtyByActionGroupKey,
      );
    } else {
      quantities = await _resolveSupplyQuantities(
        route,
        targets,
        qtyByActionGroupKey,
      );
    }
    if (quantities == null || !mounted) return null;
    final quantityByIdentity = {
      for (final input in quantities)
        input.actionGroupKey != null
                ? 'GROUP|${input.actionGroupKey}'
                : 'LINE|${input.materialLineId}':
            input,
    };
    final batches = _chunked(targets);
    var current = analysis;
    var completed = 0;
    setState(() {
      _notifyingRoute = route;
      _bulkOperationLabel = switch (route) {
        MaterialSupplyRoute.buy => '正在提交采购需求',
        MaterialSupplyRoute.subcontract => '正在下达委外任务',
        MaterialSupplyRoute.make => '正在创建自制备料任务',
      };
      _bulkOperationCompleted = 0;
      _bulkOperationTotal = targets.length;
    });
    try {
      for (final batch in batches) {
        final actionGroupKeys = batch
            .map((target) => target.actionGroupKey)
            .whereType<String>()
            .toList(growable: false);
        final materialLineIds = batch
            .map((target) => target.materialLineId)
            .whereType<String>()
            .toList(growable: false);
        final batchQuantities = [
          for (final target in batch)
            if (quantityByIdentity[target.identity] != null)
              quantityByIdentity[target.identity]!,
        ];
        final key = businessIdempotencyKey(
          'material-analysis-notify-chunk',
          [
            current.analysisId,
            current.version,
            current.fingerprint,
            route.wireName,
            ...actionGroupKeys,
            ...materialLineIds,
            for (final input in batchQuantities)
              '${input.actionGroupKey ?? input.materialLineId}:'
                  '${input.qty}:${input.safetyReplenishmentQty}:'
                  '${input.publicExtraQty}',
          ].join('|'),
        );
        current = await ref
            .read(productionPlanRepositoryProvider)
            .notifyMaterialAnalysis(
              analysis: current,
              idempotencyKey: key,
              target: route,
              actionGroupKeys: actionGroupKeys,
              materialLineIds: materialLineIds,
              quantities: batchQuantities,
            );
        completed += batch.length;
        if (!mounted) return null;
        setState(() => _bulkOperationCompleted = completed);
      }
      if (!mounted) return null;
      setState(() {
        _notifyingRoute = null;
        _clearBulkOperation();
        _applyAnalysis(current);
      });
      final usedRootStock = groups.any(
        (group) => _hasRootStockToAllocate(group, route),
      );
      final message = usedRootStock
          ? _l10n.materialRootSupplyProcessed
          : switch (route) {
              // ADR-065：同批多货品在服务端合并为一张采购需求单（明细逐货品），
              // 超大批次分批提交时每批一张；订货侧仍按供应商分组拆订货单。
              MaterialSupplyRoute.buy =>
                '采购需求已提交：${groups.length} 条货品合并为 '
                    '${batches.length} 张采购需求单，已通知采购',
              // V458：有子层级的委外件由服务端转前置自制，成品入库后才通知委外部。
              // ADR-065：无子层委外同批合并为一张委外申请（分批提交时每批一张）。
              MaterialSupplyRoute.subcontract =>
                '委外任务已下达：无子层合并为 '
                    '${batches.length} 张委外申请并通知委外部；有子层已转前置自制，入库后自动通知',
              MaterialSupplyRoute.make => '自制备料任务已创建（${groups.length} 条）',
            };
      context.appSuccess(message);
      return current;
    } catch (error) {
      if (!mounted) return null;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '提交${route.label}需求',
      )) {
        if (!mounted) return null;
        setState(() {
          _notifyingRoute = null;
          _clearBulkOperation();
        });
        return null;
      }
      if (!mounted) return null;
      setState(() {
        _notifyingRoute = null;
        _clearBulkOperation();
        _applyAnalysis(current);
      });
      final message = productionErrorMessage(error, fallback: '通知失败，请稍后重试');
      context.appError(
        completed == 0
            ? message
            : '已提交 $completed / ${targets.length} 项；未完成项仍保持勾选，可直接重试。$message',
        force: true,
      );
      return null;
    }
  }

  List<MaterialSupplyQuantityInput>? _fullResidualSupplyQuantities(
    MaterialSupplyRoute route,
    List<_SupplyNotificationTarget> targets,
  ) {
    final entries = [
      for (final target in targets) _supplyQuantityEntry(target, route),
    ];
    if (entries.isEmpty ||
        entries.any(
          (entry) => entry.maxQty <= 0 && entry.rootAllocatedStockQty <= 0,
        )) {
      context.appWarning('当前自制任务已无可安排余量，请刷新后重试');
      return null;
    }
    return [
      for (final entry in entries)
        entry.toInput(entry.maxQty, allowOverDemand: false),
    ];
  }

  /// 委外「下达委外」的数量裁决 + 总结确认（2026-09-06 对齐采购口径）：
  /// 有子层=与自制同构的全量剩余（服务端转前置自制，不可改量）；无子层=行内
  /// 数量裁决（校验同采购）。两类合并为**一张**总结弹窗二次确认，取消整批放弃
  ///（此前有子层路径不弹任何确认直接下达）。
  Future<List<MaterialSupplyQuantityInput>?> _resolveSubcontractQuantities(
    List<_MaterialGroup> groups,
    Map<String, String>? qtyByActionGroupKey,
  ) async {
    const route = MaterialSupplyRoute.subcontract;
    final childGroups = groups
        .where((group) => _analysisMaterialHasChildren(group.representative))
        .toList(growable: false);
    final leafGroups = groups
        .where((group) => !_analysisMaterialHasChildren(group.representative))
        .toList(growable: false);
    // 有子层：显式创建 child 时必须全量接管剩余需求（仅当选中含有子层行时校验）。
    final childEntries = [
      for (final target in _notificationTargetsForGroups(childGroups))
        _supplyQuantityEntry(target, route),
    ];
    if (childGroups.isNotEmpty &&
        (childEntries.isEmpty ||
            childEntries.any(
              (entry) => entry.maxQty <= 0 && entry.rootAllocatedStockQty <= 0,
            ))) {
      context.appWarning('当前自制任务已无可安排余量，请刷新后重试');
      return null;
    }
    // 无子层：行内数量裁决（公共补库 fail-closed、超上限拦截同采购），不单独弹窗。
    final leaf = _adjudicateSupplyQuantities(
      route,
      _notificationTargetsForGroups(leafGroups),
      qtyByActionGroupKey,
    );
    if (leaf == null) return null;
    final entries = [...childEntries, ...leaf.entries];
    final quantities = [
      for (final entry in childEntries) entry.maxQty,
      ...leaf.quantities,
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => MaterialSupplySubmitConfirmDialog(
        route: route,
        entries: entries,
        quantities: quantities,
        qtyText: _qty,
      ),
    );
    if (confirmed != true) return null;
    return [
      for (var i = 0; i < entries.length; i++)
        entries[i].toInput(
          quantities[i],
          allowOverDemand:
              i >= childEntries.length &&
              leaf.allowOverDemand &&
              entries[i].allowPublicExtra,
        ),
    ];
  }

  /// 「提交采购/委外」前的数量裁决与总结确认（2026-09-05 改版；2026-09-06 拆出
  /// 无弹窗裁决段 [_adjudicateSupplyQuantities] 供委外混合批次复用）：
  ///
  /// 数量编辑已前移到分桶表格行内（默认/上限来自 demandSupplyGapQty −
  /// 已在途需求），这里只做三件事：按 [qtyByActionGroupKey]（行内编辑值，
  /// 键=actionGroupKey）裁决每个提交单元的数量并校验；公共安全库存补库
  /// 仅 BUY 支持，并按 goods/color/unit 去重后作为固定数量显式回传；
  /// 最后弹「品种数 + 合计」的总结确认弹窗。取消返回 null，调用方整批放弃。
  /// MAKE 因父树尚无 delegated_qty 只允许全量，走 [_fullResidualSupplyQuantities]。
  Future<List<MaterialSupplyQuantityInput>?> _resolveSupplyQuantities(
    MaterialSupplyRoute route,
    List<_SupplyNotificationTarget> targets, [
    Map<String, String>? qtyByActionGroupKey,
  ]) async {
    final adjudicated = _adjudicateSupplyQuantities(
      route,
      targets,
      qtyByActionGroupKey,
    );
    if (adjudicated == null) return null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => MaterialSupplySubmitConfirmDialog(
        route: route,
        entries: adjudicated.entries,
        quantities: adjudicated.quantities,
        qtyText: _qty,
      ),
    );
    if (confirmed != true) return null;
    return [
      for (var i = 0; i < adjudicated.entries.length; i++)
        adjudicated.entries[i].toInput(
          adjudicated.quantities[i],
          allowOverDemand:
              adjudicated.allowOverDemand &&
              adjudicated.entries[i].allowPublicExtra,
        ),
    ];
  }

  /// 纯数量裁决（不弹窗）：校验行内编辑值（无效/负数/超上限/全零）与公共补库
  /// fail-closed（仅采购）。校验失败向用户提示并返回 null。
  ({
    List<MaterialSupplyQuantityEntry> entries,
    List<double> quantities,
    bool allowOverDemand,
  })?
  _adjudicateSupplyQuantities(
    MaterialSupplyRoute route,
    List<_SupplyNotificationTarget> targets, [
    Map<String, String>? qtyByActionGroupKey,
  ]) {
    final rawEntries = [
      for (final target in targets) _supplyQuantityEntry(target, route),
    ];
    final safetyGapByDimension = <String, double>{};
    for (final entry in rawEntries) {
      final previous = safetyGapByDimension[entry.dimensionKey] ?? 0;
      if (entry.safetyReplenishmentGapQty > previous) {
        safetyGapByDimension[entry.dimensionKey] =
            entry.safetyReplenishmentGapQty;
      }
    }
    final safetyDimensionsIncluded = <String>{};
    final entries = <MaterialSupplyQuantityEntry>[];
    for (final entry in rawEntries) {
      final dimensionGap = safetyGapByDimension[entry.dimensionKey] ?? 0;
      final includeHere =
          route == MaterialSupplyRoute.buy &&
          dimensionGap > 0 &&
          safetyDimensionsIncluded.add(entry.dimensionKey);
      entries.add(
        entry.withSafetyReplenishment(
          includeHere ? dimensionGap : 0,
          deduplicatedElsewhere:
              route == MaterialSupplyRoute.buy &&
              dimensionGap > 0 &&
              !includeHere,
        ),
      );
    }
    // 委外遇到公共安全缺口：fail-closed（本版本仅采购路线支持补库）。
    if (route != MaterialSupplyRoute.buy &&
        entries.any((entry) => entry.safetyReplenishmentGapQty > 0)) {
      context.appError('本版本仅采购路线支持公共安全补库，请改用采购路线下达');
      return null;
    }
    // 采购/委外允许超量下单（富余入库后转公共可用，供后续分析使用）；
    // 自制走全量剩余需求，不进本函数。
    final allowOverDemand =
        _canOverSupply &&
        (route == MaterialSupplyRoute.buy ||
            route == MaterialSupplyRoute.subcontract);
    final quantities = <double>[];
    for (final entry in entries) {
      final edited = entry.actionGroupKey == null
          ? null
          : qtyByActionGroupKey?[entry.actionGroupKey!];
      final qty = edited == null || edited.trim().isEmpty
          ? entry.maxQty
          : double.tryParse(edited.trim());
      if (qty == null || !qty.isFinite || qty < 0) {
        context.appError('「${entry.label}」的下达数量无效，请在表格中修改后重试');
        return null;
      }
      final canOverThis = allowOverDemand && entry.allowPublicExtra;
      if (!canOverThis && qty > entry.maxQty + 0.0001) {
        context.appError(
          '「${entry.label}」最多下达 ${_qty(entry.maxQty)}'
          '（本批缺口 − 已在途需求），请在表格中修改后重试',
        );
        return null;
      }
      if (qty <= 0 &&
          entry.safetyReplenishmentQty <= 0 &&
          entry.rootAllocatedStockQty <= 0) {
        context.appError('「${entry.label}」下达数量为 0 且无安全补库/现货可交接，请填正数');
        return null;
      }
      quantities.add(qty);
    }
    return (
      entries: entries,
      quantities: quantities,
      allowOverDemand: allowOverDemand,
    );
  }

  /// 组装一个提交单元的展示与口径数据。actionGroupKey 单元的缺口/在途
  /// 按整个操作组汇总（与服务端分组口径一致），不按本页单个勾选行。
  MaterialSupplyQuantityEntry _supplyQuantityEntry(
    _SupplyNotificationTarget target,
    MaterialSupplyRoute route,
  ) {
    final materials =
        _analysis?.materials ?? const <ProductionMaterialAnalysisMaterial>[];
    final lines = target.actionGroupKey != null
        ? materials
              .where(
                (material) =>
                    (material.actionable || material.isRootSupply) &&
                    material.actionGroupKey == target.actionGroupKey,
              )
              .toList(growable: false)
        : materials
              .where(
                (material) => material.materialLineId == target.materialLineId,
              )
              .toList(growable: false);
    final representative = lines.isEmpty ? null : lines.first;
    var demandGap = 0.0;
    var open = 0.0;
    var safetyStock = 0.0;
    var publicAvailable = 0.0;
    var openSafetySupply = 0.0;
    var safetyGap = 0.0;
    for (final material in lines) {
      if (material.demandSupplyGapQty > 0) {
        demandGap += material.demandSupplyGapQty;
      }
      if (material.safetyStockQty > safetyStock) {
        safetyStock = material.safetyStockQty;
      }
      if (material.mainWarehousePublicAvailableQty > publicAvailable) {
        publicAvailable = material.mainWarehousePublicAvailableQty;
      }
      if (material.mainWarehouseOpenSafetySupplyQty > openSafetySupply) {
        openSafetySupply = material.mainWarehouseOpenSafetySupplyQty;
      }
      if (material.mainWarehouseSafetyReplenishmentGapQty > safetyGap) {
        safetyGap = material.mainWarehouseSafetyReplenishmentGapQty;
      }
      for (final notified in material.notifiedTargets) {
        if (notified.target != route || notified.isRootOutput) continue;
        final status = notified.status;
        if (status == 'CANCELLED' || status == 'DONE') continue;
        // 历史投影缺分摊量时保守按全额在途，防止重复全量提交。
        open +=
            notified.allocatedQty ??
            (material.demandSupplyGapQty > 0 ? material.demandSupplyGapQty : 0);
      }
    }
    final residual = demandGap - open;
    final nodeKey = representative?.nodeKey;
    final analysis = _analysis;
    final hasProductionChildren =
        representative != null &&
        nodeKey != null &&
        analysis != null &&
        (_analysisIndexes(analysis).childrenByParentNodeKey[(
                  analysisLineId: representative.analysisLineId,
                  parentNodeKey: nodeKey,
                )] ??
                const <ProductionMaterialAnalysisMaterial>[])
            .any((child) {
              final stage = child.controlStage?.trim().toUpperCase();
              return stage != 'SHIP' && stage != 'REFERENCE';
            });
    return MaterialSupplyQuantityEntry(
      actionGroupKey: target.actionGroupKey,
      materialLineId: target.materialLineId,
      label: representative?.goodsName ?? representative?.goodsCode ?? '该物料',
      spec: representative?.spec,
      unitName: representative?.unitName,
      dimensionKey: representative == null
          ? target.identity
          : _materialDimensionKey(representative),
      openQty: open,
      maxQty: residual > 0 ? residual : 0,
      rootAllocatedStockQty: lines
          .where((material) => material.isRootSupply)
          .fold(0, (sum, material) => sum + material.allocatedAvailableQty),
      safetyStockQty: safetyStock,
      publicAvailableQty: publicAvailable,
      openSafetySupplyQty: openSafetySupply,
      safetyReplenishmentGapQty: safetyGap,
      allowPublicExtra:
          route == MaterialSupplyRoute.buy ||
          (route == MaterialSupplyRoute.subcontract && !hasProductionChildren),
    );
  }

  Future<void> _showSupplyProgress(_MaterialGroup group) async {
    final analysis = _analysis;
    if (analysis == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => MaterialSupplyProgressDialog(
        analysisId: analysis.analysisId,
        material: group.representative,
        canViewProductionPlans: _canViewPlans,
      ),
    );
  }

  /// 层级色板：相邻层级色相明显拉开（青/蓝/橙/紫/品红/橄榄），白底与浅红
  /// 缺料底上都清晰可读。整卡阶梯缩进、状态栏竖线、「层级 N」徽章共用
  /// 同一色板，三处冗余表达层级。注意不要再退回主题
}
