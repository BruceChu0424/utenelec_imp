part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisSupplyActionsState
    extends _MaterialAnalysisCandidatesState {
  Future<void> _confirmSuggestedRoute(_MaterialGroup group) async {
    final analysis = _analysis;
    final suggestion = group.representative.sourceSuggestion;
    if (analysis == null ||
        suggestion == null ||
        !_canRoute ||
        !group.actionable ||
        _busy) {
      return;
    }
    final actionGroupKey = group.representative.actionGroupKey;
    final decision = actionGroupKey == null
        ? MaterialRouteDecision(
            materialLineId: group.representative.materialLineId,
            route: suggestion,
          )
        : MaterialRouteDecision(
            actionGroupKey: actionGroupKey,
            route: suggestion,
          );
    final key = businessIdempotencyKey(
      'material-analysis-route-node',
      '${analysis.analysisId}|${analysis.version}|${analysis.fingerprint}|'
          '${actionGroupKey ?? group.representative.materialLineId}|'
          '${suggestion.wireName}',
    );
    setState(() => _savingRoutes = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .updateMaterialAnalysisRoutes(
            analysis: analysis,
            idempotencyKey: key,
            decisions: [decision],
          );
      if (!mounted) return;
      setState(() {
        _savingRoutes = false;
        _applyAnalysis(view);
      });
      context.appSuccess('已采用${suggestion.label}路线，可直接下达任务');
    } catch (error) {
      if (!mounted) return;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '采用建议路线',
        pendingRouteDrafts: {group.key: (route: suggestion, reason: null)},
      )) {
        if (!mounted) return;
        setState(() => _savingRoutes = false);
        return;
      }
      if (!mounted) return;
      setState(() => _savingRoutes = false);
      context.appError(
        productionErrorMessage(error, fallback: '路线确认失败，请刷新后重试'),
        force: true,
      );
    }
  }

  Future<String?> _promptRouteReason(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) => showDialog<String>(
    context: context,
    builder: (_) => MaterialRequiredReasonDialog(
      title: '填写路线覆盖原因',
      fieldKey: const Key('material-route-reason'),
      initialValue: _routeReasons[group.key] ?? '',
      info:
          '服务端建议 ${group.representative.sourceSuggestion?.label ?? '人工判断'}，'
          '当前选择 ${route.label}。取消不会改变原路线。',
      confirmLabel: '确认路线',
    ),
  );

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

  Future<void> _saveRoutes() async {
    final analysis = _analysis;
    if (analysis == null || !_canRoute || _savingRoutes) return;
    final groups = {
      for (final group in _materialGroups(analysis)) group.key: group,
    };
    final changes = <_PendingRouteDecision>[];
    final pendingDrafts =
        <String, ({MaterialSupplyRoute route, String? reason})>{};
    for (final key in _dirtyRouteGroups) {
      final group = groups[key];
      final route = _routeDraft[key];
      if (group == null || route == null) continue;
      final suggestion = group.representative.sourceSuggestion;
      final reason = _routeReasons[key]?.trim();
      if ((suggestion == null || suggestion != route) &&
          (reason == null || reason.isEmpty)) {
        context.appWarning('覆盖建议路线时必须填写原因');
        return;
      }
      pendingDrafts[key] = (route: route, reason: reason);
      final actionGroupKey = group.representative.actionGroupKey;
      if (actionGroupKey != null) {
        changes.add(
          _PendingRouteDecision(
            groupKey: key,
            decision: MaterialRouteDecision(
              actionGroupKey: actionGroupKey,
              route: route,
              reason: reason,
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
                reason: reason,
              ),
            ),
        ]);
      }
    }
    if (changes.isEmpty) {
      context.appInfo('没有待确认的路线变更');
      return;
    }
    changes.sort((left, right) => left.identity.compareTo(right.identity));
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
        _applyAnalysis(current);
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
        _applyAnalysis(current);
        final currentKeys = _materialGroups(
          current,
        ).map((group) => group.key).toSet();
        for (final groupKey in remainingGroupKeys) {
          final draft = pendingDrafts[groupKey];
          if (draft == null || !currentKeys.contains(groupKey)) continue;
          _routeDraft[groupKey] = draft.route;
          if (draft.reason?.isNotEmpty == true) {
            _routeReasons[groupKey] = draft.reason!;
          }
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

  /// One-click accepts every concrete BUY/SUBCONTRACT/MAKE suggestion as the
  /// confirmed route, so the planner is not forced to open 15 dropdowns before
  /// they can select shortages and notify. Suggestions equal to the chosen
  /// route need no reason (server contract). REVIEW / null-suggestion groups
  /// still require a manual decision and are reported back.
  Future<void> _acceptAllSuggestedRoutes() async {
    final analysis = _analysis;
    if (analysis == null || !_canRoute || _busy) return;
    final groups = _materialGroups(analysis);
    int accepted = 0;
    int manual = 0;
    setState(() {
      for (final group in groups) {
        if (!group.actionable) continue;
        if (group.representative.confirmedRoute != null) continue;
        final suggestion = group.representative.sourceSuggestion;
        if (suggestion == null) {
          manual++;
          continue;
        }
        _routeDraft[group.key] = suggestion;
        _routeReasons.remove(group.key);
        _dirtyRouteGroups.add(group.key);
        accepted++;
      }
      _planPreview = null;
      if (accepted > 0) _invalidateBucketRowsCache();
    });
    if (accepted == 0) {
      context.appInfo(
        manual == 0 ? '当前没有待确认的建议路线' : '剩余 $manual 条建议为空，需逐条人工选择路线',
      );
      return;
    }
    final manualAfter = manual;
    await _saveRoutes();
    if (manualAfter > 0 && mounted) {
      context.appInfo('已采纳 $accepted 条建议路线；另有 $manualAfter 条建议为空，需逐条人工选择路线');
    }
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
        if (target.target != route) continue;
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

  MaterialWarehouseStock? _selectedWarehouseStock(
    ProductionMaterialAnalysisMaterial material,
  ) {
    final warehouseId = _analysis?.warehouseId ?? _warehouseId;
    if (warehouseId == null || warehouseId.isEmpty) return null;
    return material.warehouseStocks
        .where((stock) => stock.warehouseId == warehouseId)
        .firstOrNull;
  }

  double _groupSafetyReplenishmentGapQty(_MaterialGroup group) => group.paths
      .map(_selectedWarehouseStock)
      .whereType<MaterialWarehouseStock>()
      .fold(
        0.0,
        (max, stock) => stock.safetyReplenishmentGapQty > max
            ? stock.safetyReplenishmentGapQty
            : max,
      );

  double _groupOpenSafetySupplyQty(_MaterialGroup group) => group.paths
      .map(_selectedWarehouseStock)
      .whereType<MaterialWarehouseStock>()
      .fold(
        0.0,
        (max, stock) =>
            stock.openSafetySupplyQty > max ? stock.openSafetySupplyQty : max,
      );

  bool _routeBlockedBySafetyGap(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) =>
      route != MaterialSupplyRoute.buy &&
      _groupSafetyReplenishmentGapQty(group) > 0;

  bool _hasSupplySubmitQty(_MaterialGroup group, MaterialSupplyRoute route) =>
      _residualSubmitQty(group, route) > 0 ||
      (route == MaterialSupplyRoute.buy &&
          _groupSafetyReplenishmentGapQty(group) > 0);

  bool _isExecutableSupplyGroup(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) =>
      group.actionable &&
      _routeDraft[group.key] == route &&
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
    if (executionStage != null) return executionStage.label;
    return child.readyNowQty > 0 ? '待安排生产' : '物料准备中';
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

  /// BOM 节点卡左侧状态栏：正需求明确表达“合格库存保障”，不把它伪装成
  /// 生产执行进度；零需求节点按 requirementState 朗读原因和恢复路径。
  /// 状态栏独立整高，右侧内容不会侵入。2026-08-18 起移除栏顶路线状态图标
  /// （路线状态由数量行的状态文字承担），栏体只表达层级 + 进度。
  Future<void> _arrangeMakeProduction({
    _MaterialGroup? onlyGroup,
    Set<String>? onlyGroupKeys,
  }) async {
    final analysis = _analysis;
    if (analysis == null || !_canNotify || _notifyingRoute != null) return;
    final groups = onlyGroupKeys != null
        ? _executableSupplyGroups(MaterialSupplyRoute.make)
              .where((group) => onlyGroupKeys.contains(group.key))
              .toList(growable: false)
        : onlyGroup != null
        ? <_MaterialGroup>[onlyGroup]
        : const <_MaterialGroup>[];
    if (groups.isEmpty) {
      context.appInfo('请先勾选要创建子件任务的自制件');
      return;
    }
    final view = await _notifyRoute(
      MaterialSupplyRoute.make,
      onlyGroupKeys: {for (final group in groups) group.key},
    );
    if (!mounted || view == null) return;
    final requestedLineIds = {
      for (final group in groups) group.representative.materialLineId,
    };
    var created = 0;
    var readySelected = 0;
    var waiting = 0;
    var refreshing = 0;
    var needPermission = 0;
    setState(() {
      for (final material in view.materials) {
        if (!requestedLineIds.contains(material.materialLineId)) continue;
        created++;
        final child = _makeChildProductOf(material);
        if (child == null) {
          refreshing++;
          continue;
        }
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
      _planPreview = null;
    });
    if (created == 0) {
      context.appWarning('所选自制件状态已变化，请刷新后重试');
      return;
    }
    final parts = <String>[
      '已创建 $created 个自制子件任务',
      if (readySelected > 0) '$readySelected 个已进入填写数量，核对后点「安排子件生产」提交计划单',
      if (waiting > 0) '$waiting 个子件状态已变化，请刷新后核对',
      if (refreshing > 0) '$refreshing 个子件分析正在刷新，稍后从本页继续',
      if (needPermission > 0) '请由有生产计划权限的员工继续填写计划单',
    ];
    context.appSuccess(parts.join('；'));
  }

  /// V458/ADR-062 修订一②：有子层级委外件与自制完全同构的第二段——「下达委外」
  /// 建 SUBCONTRACT_MAKE 前置自制任务后**留在本页**，已可生产的委外子件自动
  /// 勾选并预填「最多可生产量」，员工核对后点底部「安排子件生产」进入计划
  /// 向导；同批无子层委外件仍由服务端立即合并生成委外申请并通知委外部。
  Future<void> _arrangeSubcontractProduction({
    Set<String>? onlyGroupKeys,
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
      _planPreview = null;
    });
    // 全部为无子层时 _notifyRoute 的「合并为 N 张委外申请」提示已足够。
    if (created == 0) return;
    final parts = <String>[
      '已创建 $created 个委外子件任务',
      if (readySelected > 0) '$readySelected 个已进入填写数量，核对后点「安排子件生产」提交计划单',
      if (waiting > 0) '$waiting 个子件状态已变化，请刷新后核对',
      if (needPermission > 0) '请由有生产计划权限的员工继续填写计划单',
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
    final nodeKey = material.nodeKey;
    if (analysis == null || nodeKey == null || nodeKey.isEmpty) return false;
    return _analysisIndexes(analysis).childrenByParentNodeKey.containsKey((
      analysisLineId: material.analysisLineId,
      parentNodeKey: nodeKey,
    ));
  }

  /// 路线「学习预填」（/last-routes）：对新快照中「未确认路线」的缺料组带出
  /// 上次同物料（货品+颜色+单位）确认过的路线——无建议路线的物料、或上次确认
  /// 与本次建议不同的物料，默认带出上次选择（草稿态，须「确认路线」保存）。
  /// 记忆与本次建议一致的组保持建议待采用，不制造无谓的确认负担。
  /// 已有未保存路线修改时不打扰（轮询也会因草稿暂停，不会反复覆盖）。
  Future<void> _prefillRememberedRoutes(
    ProductionMaterialAnalysisView view,
  ) async {
    if (!_canRoute || !view.allowedActions.contains('CONFIRM_ROUTES')) return;
    if (_dirtyRouteGroups.isNotEmpty) return;
    final pendingGroups = _materialGroups(view)
        .where(
          (group) =>
              group.actionable &&
              group.representative.shortageQty > 0 &&
              group.representative.confirmedRoute == null,
        )
        .toList(growable: false);
    if (pendingGroups.isEmpty) return;
    final goodsIds = <String>{
      for (final group in pendingGroups)
        if (group.representative.goodsId != null) group.representative.goodsId!,
    };
    if (goodsIds.isEmpty) return;
    Map<String, List<MaterialRouteMemory>> memory;
    try {
      memory = await ref
          .read(productionPlanRepositoryProvider)
          .materialAnalysisLastRoutes(goodsIds);
    } catch (_) {
      return; // 学习预填失败静默：路线仍可手选/采用建议。
    }
    if (!mounted || _dirtyRouteGroups.isNotEmpty) return;
    MaterialRouteMemory? memoryFor(_MaterialGroup group) {
      final material = group.representative;
      for (final entry
          in memory[material.goodsId] ?? const <MaterialRouteMemory>[]) {
        final colorMatch =
            (entry.colorId == null &&
                (material.colorId == null || material.colorId!.isEmpty)) ||
            entry.colorId == material.colorId;
        if (colorMatch && entry.unitId == material.unitId) return entry;
      }
      return null;
    }

    var applied = 0;
    for (final group in pendingGroups) {
      final entry = memoryFor(group);
      if (entry == null) continue;
      final suggestion = group.representative.sourceSuggestion;
      if (suggestion == entry.route) continue; // 与建议一致：保持建议待采用
      _routeDraft[group.key] = entry.route;
      final reason = entry.reason?.trim();
      if (reason?.isNotEmpty == true) {
        _routeReasons[group.key] = reason!;
      } else {
        _routeReasons.remove(group.key);
      }
      _dirtyRouteGroups.add(group.key);
      applied++;
    }
    if (applied > 0) {
      _invalidateBucketRowsCache();
      setState(() {}); // 底部出现「确认路线(applied)」
      context.appInfo('已按上次选择带出 $applied 条路线草稿，请核对后点「确认路线」保存');
    }
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
      final childGroups = groups
          .where((group) => _analysisMaterialHasChildren(group.representative))
          .toList(growable: false);
      final leafGroups = groups
          .where((group) => !_analysisMaterialHasChildren(group.representative))
          .toList(growable: false);
      final childQuantities = childGroups.isEmpty
          ? <MaterialSupplyQuantityInput>[]
          : _fullResidualSupplyQuantities(
              route,
              _notificationTargetsForGroups(childGroups),
            );
      if (childQuantities == null) return null;
      final leafQuantities = leafGroups.isEmpty
          ? <MaterialSupplyQuantityInput>[]
          : await _promptSupplyQuantities(
              route,
              _notificationTargetsForGroups(leafGroups),
            );
      if (leafQuantities == null) return null;
      quantities = [...childQuantities, ...leafQuantities];
    } else {
      quantities = await _promptSupplyQuantities(route, targets);
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
      final message = switch (route) {
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
    if (entries.isEmpty || entries.any((entry) => entry.maxQty <= 0)) {
      context.appWarning('当前自制任务已无可安排余量，请刷新后重试');
      return null;
    }
    return [
      for (final entry in entries)
        entry.toInput(entry.maxQty, allowOverDemand: false),
    ];
  }

  /// 「提交采购/委外」前的数量确认：每个提交单元一行。
  ///
  /// 本批生产需求默认/上限来自 demandSupplyGapQty − 已在途需求；公共安全
  /// 库存补库仅 BUY 支持，并按 goods/color/unit 去重后作为固定数量显式回传。
  /// 前端绝不在确认后静默追加数量。取消返回 null，调用方整批放弃。
  /// MAKE 因父树尚无 delegated_qty 只允许全量，走 [_fullResidualSupplyQuantities]。
  Future<List<MaterialSupplyQuantityInput>?> _promptSupplyQuantities(
    MaterialSupplyRoute route,
    List<_SupplyNotificationTarget> targets,
  ) {
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
    return showDialog<List<MaterialSupplyQuantityInput>>(
      context: context,
      builder: (_) => MaterialSupplyQuantityDialog(
        route: route,
        entries: entries,
        qtyText: _qty,
        // 采购/委外允许超量下单（富余入库后转公共可用，供后续分析使用）；
        // 自制走全量剩余需求，不弹本对话框。
        allowOverDemand:
            _canOverSupply &&
            (route == MaterialSupplyRoute.buy ||
                route == MaterialSupplyRoute.subcontract),
      ),
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
                    material.actionable &&
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
      final stock = _selectedWarehouseStock(material);
      if (stock != null) {
        if (stock.publicAvailableQty > publicAvailable) {
          publicAvailable = stock.publicAvailableQty;
        }
        if (stock.openSafetySupplyQty > openSafetySupply) {
          openSafetySupply = stock.openSafetySupplyQty;
        }
        if (stock.safetyReplenishmentGapQty > safetyGap) {
          safetyGap = stock.safetyReplenishmentGapQty;
        }
      }
      for (final notified in material.notifiedTargets) {
        if (notified.target != route) continue;
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
      safetyStockQty: safetyStock,
      publicAvailableQty: publicAvailable,
      openSafetySupplyQty: openSafetySupply,
      safetyReplenishmentGapQty: safetyGap,
      allowPublicExtra:
          route == MaterialSupplyRoute.buy ||
          (route == MaterialSupplyRoute.subcontract && !hasProductionChildren),
    );
  }

  /// 保存成功后按钮即变深绿。已下达任务/无需补货/已齐套的节点不再改路线。
  Widget? _nodeRouteButton(
    ThemeData theme,
    _MaterialGroup group,
    MaterialSupplyRoute? route,
  ) {
    final material = group.representative;
    if (!group.actionable || !_canRoute) return null;
    if (_notifiedTargetOf(material) != null) return null;
    if (material.requiredQty <= 0 || material.shortageQty <= 0) return null;
    final confirmed = material.confirmedRoute;
    if (confirmed != null && !_dirtyRouteGroups.contains(group.key)) {
      return FilledButton.icon(
        key: ValueKey('material-route-change-${material.materialLineId}'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          backgroundColor: UtenColors.deepGreen,
          foregroundColor: Colors.white,
        ),
        onPressed: _busy ? null : () => _pickRoute(group),
        icon: const Icon(Icons.alt_route_rounded, size: 18),
        label: Text('路线 · ${confirmed.label}'),
      );
    }
    if (confirmed == null && material.sourceSuggestion == null) {
      return OutlinedButton.icon(
        key: ValueKey('material-route-pick-${material.materialLineId}'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy ? null : () => _pickRoute(group),
        icon: const Icon(Icons.alt_route_rounded, size: 18),
        label: const Text('选择路线'),
      );
    }
    return OutlinedButton.icon(
      key: ValueKey('material-route-change-${material.materialLineId}'),
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: _busy ? null : () => _pickRoute(group),
      icon: const Icon(Icons.alt_route_rounded, size: 18),
      label: const Text('更换路线'),
    );
  }

  /// 路线选择面板：列出采购/委外/自制三条路线，标注服务端建议与当前已确认
  /// 路线。选中与建议一致的路线直接保存；偏离建议先填覆盖原因再保存。
  Future<void> _pickRoute(_MaterialGroup group) async {
    if (_busy || !_canRoute || !group.actionable) return;
    final material = group.representative;
    final suggestion = material.sourceSuggestion;
    final confirmed = material.confirmedRoute;
    final chosen = await showModalBottomSheet<MaterialSupplyRoute>(
      context: context,
      builder: (sheetContext) {
        final sheetTheme = Theme.of(sheetContext);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s16,
                  UtenSpacing.s16,
                  UtenSpacing.s16,
                  UtenSpacing.s8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '选择供料路线',
                      style: sheetTheme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      material.goodsName ?? material.goodsCode ?? '当前物料',
                      style: sheetTheme.textTheme.bodySmall?.copyWith(
                        color: sheetTheme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              for (final option in MaterialSupplyRoute.values)
                ListTile(
                  leading: Icon(switch (option) {
                    MaterialSupplyRoute.buy => Icons.shopping_cart_outlined,
                    MaterialSupplyRoute.subcontract =>
                      Icons.precision_manufacturing_outlined,
                    MaterialSupplyRoute.make => Icons.factory_outlined,
                  }),
                  title: Text(option.label),
                  trailing: Wrap(
                    spacing: UtenSpacing.s8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (option == suggestion)
                        _miniBadge(
                          sheetTheme,
                          label: '建议',
                          color: sheetTheme.colorScheme.tertiary,
                        ),
                      if (option == confirmed)
                        Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: sheetTheme.colorScheme.primary,
                        ),
                    ],
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(option),
                ),
              const SizedBox(height: UtenSpacing.s8),
            ],
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    if (chosen == confirmed && !_dirtyRouteGroups.contains(group.key)) {
      context.appInfo('路线未变化，当前已是${chosen.label}');
      return;
    }
    String? reason;
    if (suggestion == null || suggestion != chosen) {
      // 偏离服务端建议（或无建议）时必须填写覆盖原因（服务端契约）。
      reason = await _promptRouteReason(group, chosen);
      if (reason == null || !mounted) return;
    }
    await _persistRouteChoice(group, chosen, reason);
  }

  /// 立即保存单条路线选择（与「采用建议」同一接口与幂等键口径），成功后
  /// 整树刷新为最新分析视图，「更换路线」按钮随即显示深绿已确认态。
  Future<void> _persistRouteChoice(
    _MaterialGroup group,
    MaterialSupplyRoute route,
    String? reason,
  ) async {
    final analysis = _analysis;
    if (analysis == null || !_canRoute || !group.actionable || _busy) return;
    final actionGroupKey = group.representative.actionGroupKey;
    final decision = actionGroupKey == null
        ? MaterialRouteDecision(
            materialLineId: group.representative.materialLineId,
            route: route,
            reason: reason,
          )
        : MaterialRouteDecision(
            actionGroupKey: actionGroupKey,
            route: route,
            reason: reason,
          );
    final key = businessIdempotencyKey(
      'material-analysis-route-node',
      '${analysis.analysisId}|${analysis.version}|${analysis.fingerprint}|'
          '${actionGroupKey ?? group.representative.materialLineId}|'
          '${route.wireName}|${reason ?? ''}',
    );
    setState(() => _savingRoutes = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .updateMaterialAnalysisRoutes(
            analysis: analysis,
            idempotencyKey: key,
            decisions: [decision],
          );
      if (!mounted) return;
      setState(() {
        _savingRoutes = false;
        _applyAnalysis(view);
      });
      context.appSuccess('已确认${route.label}路线');
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingRoutes = false);
      context.appError(
        productionErrorMessage(error, fallback: '路线确认失败，请刷新后重试'),
        force: true,
      );
    }
  }

  /// 已下达供给任务的节点状态可点：弹出该物料的供给全链路进度
  /// （提交需求 → 下单 → 财务批准 → 仓库收货 → 品质验收 → 入库）。
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
