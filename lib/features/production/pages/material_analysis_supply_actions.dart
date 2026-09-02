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
    final preservedSelections = _supplySelectionSnapshot();
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
        _restoreValidSupplySelections(preservedSelections);
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
      helperMessage:
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
    final preservedSelections = _supplySelectionSnapshot();
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
        _restoreValidSupplySelections(preservedSelections);
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
        _restoreValidSupplySelections(preservedSelections);
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
      !(route == MaterialSupplyRoute.make &&
          group.representative.lowerLevelPending) &&
      !_routeBlockedBySafetyGap(group, route) &&
      _hasSupplySubmitQty(group, route);

  @override
  List<_MaterialGroup> _executableSupplyGroups(MaterialSupplyRoute route) {
    final analysis = _analysis;
    if (analysis == null) return const [];
    return _materialGroups(analysis)
        .where((group) => _isExecutableSupplyGroup(group, route))
        .toList(growable: false);
  }

  int _selectedExecutableCount(MaterialSupplyRoute route) {
    final selected = _selectedSupplyGroups[route]!;
    return _executableSupplyGroups(
      route,
    ).where((group) => selected.contains(group.key)).length;
  }

  String _notifyLabel(MaterialSupplyRoute route) {
    final count = _selectedExecutableCount(route);
    return switch (route) {
      MaterialSupplyRoute.buy => '提交采购需求($count)',
      // V458：无子层立即通知委外部；有子层由服务端转前置自制，不惊动委外。
      MaterialSupplyRoute.subcontract => '下达委外($count)',
      // 两段式第一步：创建任务后留在本页填数量，不直接进计划向导。
      MaterialSupplyRoute.make =>
        _canGenerate ? '创建子件并填写生产数量($count)' : '创建自制子件任务($count)',
    };
  }

  bool? _supplyHeaderValue(MaterialSupplyRoute route) {
    final eligible = _executableSupplyGroups(route);
    if (eligible.isEmpty) return false;
    final selected = _selectedSupplyGroups[route]!;
    final selectedCount = eligible
        .where((group) => selected.contains(group.key))
        .length;
    if (selectedCount == 0) return false;
    if (selectedCount == eligible.length) return true;
    return null;
  }

  void _toggleSupplyGroup(
    MaterialSupplyRoute route,
    _MaterialGroup group,
    bool selected,
  ) {
    if (!_isExecutableSupplyGroup(group, route) || _busy) return;
    setState(() {
      final values = _selectedSupplyGroups[route]!;
      selected ? values.add(group.key) : values.remove(group.key);
      _planPreview = null;
    });
  }

  void _toggleAllSupplyGroups(MaterialSupplyRoute route, bool selected) {
    if (_busy) return;
    final eligible = _executableSupplyGroups(route);
    setState(() {
      final values = _selectedSupplyGroups[route]!;
      if (selected) {
        values.addAll(eligible.map((group) => group.key));
      } else {
        values.removeAll(eligible.map((group) => group.key));
      }
      _planPreview = null;
    });
  }

  /// 行首选择控件：固定 48px，只改变本地批量选择，不写业务事实。
  ///
  /// - 已下达且余量已闭合 → 显示「已下达」标记，不再参与勾选；
  /// - 已下达但仍有剩余缺口（分批提交的第二批起）→ 继续显示勾选框，
  ///   数量在提交对话框里按「缺口 − 在途」给默认与上限；
  /// - 库存已覆盖（无缺口）→ 显示「已齐」标记，不出现死勾选框；
  /// - 路线已确认且可执行 → 直接勾选/取消；
  /// - 路线未确认但有主档建议 → 固定宽图标，点按给出明确引导，不把普通
  ///   勾选伪装成一次 PUT 写入；
  /// - 无建议路线 / 下层未齐套等 → 点按给出明确引导，不静默无响应。
  Widget _nodeSelectionControl(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route,
    bool selected,
  ) {
    final notified = _notifiedTargetOf(material);
    if (material.requiredQty > 0 &&
        notified != null &&
        (route == null ||
            (!_routeBlockedBySafetyGap(group, route) &&
                !_hasSupplySubmitQty(group, route)))) {
      return Tooltip(
        message: '已下达${notified.target?.label ?? ''}任务，无需重复选择',
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            Icons.check_circle_rounded,
            size: 22,
            color: selected ? Colors.white : theme.colorScheme.primary,
          ),
        ),
      );
    }
    if (material.requiredQty <= 0) {
      final inactive = _requirementStateView(theme, material);
      return Tooltip(
        message: '${inactive.title}：${inactive.detail}',
        child: Semantics(
          container: true,
          label: '${inactive.title}。${inactive.detail}',
          child: ExcludeSemantics(
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: Text(
                  '—',
                  style: TextStyle(
                    color: selected
                        ? Colors.white70
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (material.requiredQty > 0 && material.shortageQty <= 0) {
      return Tooltip(
        message: '库存已覆盖，无需下达',
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            Icons.inventory_2_outlined,
            size: 20,
            color: selected ? Colors.white70 : theme.colorScheme.primary,
          ),
        ),
      );
    }
    final makeGated =
        route == MaterialSupplyRoute.make && material.lowerLevelPending;
    final label = '选择${material.goodsName ?? material.goodsCode ?? '当前物料'}';
    if (!_canNotify) {
      return _nodeGateIcon(
        theme,
        material,
        label: '仅查看',
        message: '没有下达采购、委外或生产任务的权限',
        icon: Icons.visibility_outlined,
      );
    }
    if (_dirtyRouteGroups.contains(group.key)) {
      return _nodeGateIcon(
        theme,
        material,
        label: '先保存路线',
        message: '路线有未保存修改，保存后才可加入批量下达',
        icon: Icons.save_outlined,
      );
    }
    if (route == null || material.confirmedRoute == null) {
      return _nodeGateIcon(
        theme,
        material,
        label: '先确认路线',
        message: '先采用建议路线，或在右侧详情中选择采购、委外或自制',
        icon: Icons.route_outlined,
      );
    }
    if (makeGated) {
      return _nodeGateIcon(
        theme,
        material,
        label: '下层未齐',
        message: '下层物料未齐套，暂不能安排生产，请先处理下层缺料',
        icon: Icons.account_tree_outlined,
      );
    }
    if (_routeBlockedBySafetyGap(group, route)) {
      return _nodeGateIcon(
        theme,
        material,
        label: '仅采购可补安全库存',
        message: '本版本仅采购路线支持公共安全补库；请改为采购路线，或先处理安全库存策略',
        icon: Icons.policy_outlined,
      );
    }
    if (!_isExecutableSupplyGroup(group, route)) {
      return _nodeGateIcon(
        theme,
        material,
        label: '暂不可选',
        message: '当前节点暂不可加入批量下达，请查看右侧状态和详情',
        icon: Icons.info_outline_rounded,
      );
    }
    return Tooltip(
      message: label,
      child: Semantics(
        container: true,
        checked: selected,
        enabled: !_busy,
        label: label,
        onTap: _busy
            ? null
            : () => _handleSupplyCheckbox(group, route, selected),
        child: InkWell(
          key: ValueKey('material-bom-select-${material.materialLineId}'),
          borderRadius: UtenRadius.smAll,
          onTap: _busy
              ? null
              : () => _handleSupplyCheckbox(group, route, selected),
          child: SizedBox(
            width: 48,
            height: 48,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Checkbox(
                  value: selected,
                  onChanged: _busy ? null : (_) {},
                  fillColor: selected
                      ? const WidgetStatePropertyAll(Colors.white)
                      : null,
                  checkColor: selected ? UtenColors.deepGreen : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 固定 48px 的行首门禁图标：不撑开行头宽度，保持整列对齐；
  /// 点按弹出大白话引导（适老：不依赖悬停 tooltip 才能看到原因）。
  Widget _nodeGateIcon(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material, {
    required String label,
    required String message,
    required IconData icon,
  }) => Tooltip(
    message: '$label：$message',
    child: Semantics(
      container: true,
      button: true,
      label: '$label：$message',
      child: InkWell(
        key: ValueKey('material-bom-gate-${material.materialLineId}'),
        borderRadius: UtenRadius.smAll,
        onTap: _busy ? null : () => context.appInfo(message),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            icon,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );

  /// 行首路线确认状态的视觉描述：待确认 / 已确认 / 已下达 / 分批在途 /
  /// 已齐 / 需求未激活或已转交。汇总路径行的行首状态列使用（BOM 节点卡
  /// 左栏已改为纯层级底色 + 竖向保障进度条，不再显示该图标）。
  ({IconData icon, Color color, String tip, String? tapMessage})
  _routeStateVisual(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool selected,
  }) {
    final onSelected = selected ? Colors.white : null;
    final onSelectedSoft = selected ? Colors.white70 : null;
    IconData icon;
    Color color;
    String tip;
    String? tapMessage;
    final notified = _notifiedTargetOf(material);
    if (material.requiredQty > 0 && notified != null) {
      final residual = route == null ? 0.0 : _residualSubmitQty(group, route);
      final safetyGap = _groupSafetyReplenishmentGapQty(group);
      if (route != null && _routeBlockedBySafetyGap(group, route)) {
        icon = Icons.policy_outlined;
        color = onSelected ?? theme.colorScheme.error;
        tip = '本版本仅采购路线支持公共安全补库';
        tapMessage =
            '当前路线为${route.label}，公共安全库存还差 ${_qty(safetyGap)}；本版本不能沿该路线继续下达';
      } else if (residual > 0 ||
          (route == MaterialSupplyRoute.buy && safetyGap > 0)) {
        icon = Icons.timelapse_rounded;
        color = onSelected ?? theme.colorScheme.secondary;
        tip = residual > 0 ? '分批在途：仍有本批生产需求可继续提交' : '本批生产需求已覆盖，仍有公共安全库存补库待确认';
      } else {
        icon = Icons.check_circle_rounded;
        color = onSelected ?? theme.colorScheme.primary;
        tip = '已下达${notified.target?.label ?? ''}任务';
      }
    } else if (material.requiredQty <= 0) {
      final inactive = _requirementStateView(theme, material);
      icon = Icons.remove_rounded;
      color = onSelectedSoft ?? inactive.color;
      tip = inactive.title;
      tapMessage = inactive.detail;
    } else if (material.shortageQty <= 0) {
      icon = Icons.inventory_2_outlined;
      color = onSelected ?? theme.colorScheme.primary;
      tip = '库存已覆盖，本层已齐';
    } else if (_dirtyRouteGroups.contains(group.key)) {
      icon = Icons.save_outlined;
      color = onSelected ?? Colors.orange.shade700;
      tip = '路线已改未保存';
      tapMessage = '路线有未保存修改，请先点底部「确认路线」保存，再提交任务';
    } else if (material.confirmedRoute == null) {
      icon = Icons.route_outlined;
      color = onSelected ?? theme.colorScheme.error;
      tip = '先确认路线';
      tapMessage = '先点右侧「采用建议」或「更换路线」选择采购/委外/自制，再提交任务';
    } else {
      icon = Icons.check_circle_outline_rounded;
      color = onSelected ?? theme.colorScheme.primary;
      tip = '路线已确认(${route?.label ?? ''})，可勾选提交';
    }
    return (icon: icon, color: color, tip: tip, tapMessage: tapMessage);
  }

  /// 行首第一列（固定宽）：只显示「路线确认状态」一个图标。
  /// 宽屏 56px，紧凑屏 44px（横向空间紧张时给物料名让位）。
  Widget _routeStateCell(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool selected,
    bool compact = false,
  }) {
    final visual = _routeStateVisual(
      theme,
      material,
      group,
      route,
      selected: selected,
    );
    final child = SizedBox(
      width: compact ? 44 : 56,
      height: 48,
      child: Center(child: Icon(visual.icon, size: 24, color: visual.color)),
    );
    return Tooltip(
      message: visual.tip,
      child: Semantics(
        container: true,
        button: visual.tapMessage != null,
        label: visual.tip,
        child: visual.tapMessage == null
            ? child
            : InkWell(
                key: ValueKey(
                  'material-route-state-${material.materialLineId}',
                ),
                borderRadius: UtenRadius.smAll,
                onTap: _busy ? null : () => context.appInfo(visual.tapMessage!),
                child: child,
              ),
      ),
    );
  }

  /// 节点“本批生产需求”覆盖口径 =（需求 − demandSupplyGapQty）÷ 需求。
  /// 安全库存保护与公共补库在途在卡片上独立展示，不能再把安全库存缺口伪装
  /// 成本批生产需求未到货。不混用报工 fqty / 成品入库 iqty。
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

  /// 覆盖进度配色：已齐=主题色，0%=错误色，中间=tertiary。
  Color _coverageColor(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    double ratio,
  ) {
    if (material.demandSupplyGapQty <= 0) return theme.colorScheme.primary;
    return ratio <= 0 ? theme.colorScheme.error : theme.colorScheme.tertiary;
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
    final child = _makeChildProductOf(material);
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
  Widget _nodeStatusRail(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool selected,
  }) {
    final bandColor = selected
        ? Colors.white
        : _levelBandColor(theme, material.level);
    final coverage = _coverageOf(material);
    final barColor = coverage == null
        ? bandColor.withValues(alpha: selected ? 0.9 : 0.6)
        : selected
        ? Colors.white
        : _coverageColor(theme, material, coverage.ratio);
    final progressLabel = coverage == null
        ? null
        : '合格库存保障 ${_qty(coverage.covered)}/${_qty(material.requiredQty)}'
              '(${(coverage.ratio * 100).toStringAsFixed(0)}%)';
    final inactiveView = coverage == null
        ? _requirementStateView(theme, material)
        : null;
    return Container(
      width: 44,
      decoration: BoxDecoration(
        // 层级底色加明显（0.12 → 0.24），与右侧内容区一眼区分层级。
        color: bandColor.withValues(alpha: selected ? 0.16 : 0.24),
        border: Border(
          right: BorderSide(
            color: selected ? Colors.white24 : theme.colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
        child: coverage == null
            ? Semantics(
                container: true,
                label: '${inactiveView!.title}。${inactiveView.detail}',
                child: ExcludeSemantics(
                  child: Center(
                    child: Container(
                      width: 4,
                      decoration: BoxDecoration(
                        color: barColor,
                        borderRadius: UtenRadius.smAll,
                      ),
                    ),
                  ),
                ),
              )
            : Tooltip(
                message: progressLabel!,
                child: Semantics(
                  container: true,
                  button: true,
                  label: '$progressLabel，点按显示数字',
                  child: GestureDetector(
                    key: ValueKey(
                      'material-node-rail-progress-${material.materialLineId}',
                    ),
                    behavior: HitTestBehavior.opaque,
                    onTap: _busy
                        ? null
                        : () => setState(
                            () => _progressPeekLineId = material.materialLineId,
                          ),
                    // 整个 44px 状态栏都是点按热区；Stack 只把可见轨道固定
                    // 在中间 10px，并继承整卡紧高度。避免 loose Container 高度
                    // 退化为 0，也不用 IntrinsicHeight 不兼容的 double.infinity。
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned(
                          left: 17,
                          right: 17,
                          top: 0,
                          bottom: 0,
                          child: DecoratedBox(
                            key: ValueKey(
                              'material-node-rail-fill-${material.materialLineId}',
                            ),
                            decoration: _verticalRailProgressDecoration(
                              background: selected
                                  ? Colors.white24
                                  : barColor.withValues(alpha: 0.22),
                              fill: barColor,
                              ratio: coverage.ratio,
                            ),
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

  BoxDecoration _verticalRailProgressDecoration({
    required Color background,
    required Color fill,
    required double ratio,
  }) {
    final progress = ratio.clamp(0.0, 1.0);
    return BoxDecoration(
      color: progress <= 0
          ? background
          : progress >= 1
          ? fill
          : null,
      gradient: progress <= 0 || progress >= 1
          ? null
          : LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [fill, fill, background, background],
              stops: [0, progress, progress, 1],
            ),
      borderRadius: UtenRadius.smAll,
    );
  }

  /// 勾选框统一点按入口。可执行节点只切换本地选择；路线确认、任务下达
  /// 都由旁边的显式操作或底部批量按钮完成。
  Future<void> _handleSupplyCheckbox(
    _MaterialGroup group,
    MaterialSupplyRoute? route,
    bool selected,
  ) async {
    if (_busy) return;
    final material = group.representative;
    if (!_canNotify) {
      context.appWarning('没有下达采购/委外/生产任务的权限');
      return;
    }
    if (route == null) {
      context.appInfo('该物料没有建议路线，请点右侧「选择路线」');
      return;
    }
    if (_routeBlockedBySafetyGap(group, route)) {
      context.appWarning('本版本仅采购路线支持公共安全补库；当前${route.label}路线不能继续下达');
      return;
    }
    if (_isExecutableSupplyGroup(group, route)) {
      _toggleSupplyGroup(route, group, !selected);
      return;
    }
    if (_dirtyRouteGroups.contains(group.key)) {
      context.appInfo('该物料的路线有未保存修改，请先保存路线');
      return;
    }
    if (material.confirmedRoute == null && material.sourceSuggestion == route) {
      context.appInfo('请先点右侧“采用${route.label}”确认路线，再勾选加入批量下达');
      return;
    }
    if (route == MaterialSupplyRoute.make && material.lowerLevelPending) {
      context.appInfo('下层物料未齐套，暂不能安排生产，请先处理下层缺料');
      return;
    }
    context.appInfo('当前节点暂不可选择，请展开节点详情查看原因');
  }

  /// 创建自制子件任务（两段式第一步，与采购/委外批量下达同款交互）：按全部
  /// 剩余需求幂等创建 MAKE_COMPONENT 子任务后**留在本页**——已可生产的子件
  /// 自动勾选并预填「最多可生产量」，员工核对后点底部「安排子件生产」才进入
  /// 计划向导。取消勾选或关闭页面都不会撤销已创建的子件任务（需求登记是既成
  /// 事实，与旧流程「取消向导不撤销 child」口径一致）。仅勾选可安排（下层已
  /// 齐套）的候选；提交时快照变化导致子件暂不可生产的，留在本页继续备料。
  Future<void> _arrangeMakeProduction({_MaterialGroup? onlyGroup}) async {
    final analysis = _analysis;
    if (analysis == null || !_canNotify || _notifyingRoute != null) return;
    final groups = onlyGroup != null
        ? <_MaterialGroup>[onlyGroup]
        : _executableSupplyGroups(MaterialSupplyRoute.make)
              .where(
                (group) => _selectedSupplyGroups[MaterialSupplyRoute.make]!
                    .contains(group.key),
              )
              .toList(growable: false);
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
        final controller = _batchQtyControllers[child.analysisLineId];
        if (controller != null && controller.text.trim().isEmpty) {
          controller.text = _qty(child.readyNowQty);
        }
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
      if (waiting > 0) '$waiting 个待下层齐套后继续备料',
      if (refreshing > 0) '$refreshing 个子件分析正在刷新，稍后从本页继续',
      if (needPermission > 0) '请由有生产计划权限的员工继续填写计划单',
    ];
    context.appSuccess(parts.join('；'));
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
    final selected = _selectedSupplyGroups[route]!;
    final groups = _executableSupplyGroups(route)
        .where((group) {
          if (onlyGroupKeys != null) return onlyGroupKeys.contains(group.key);
          return selected.contains(group.key);
        })
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
    // BUY/SUBCONTRACT 允许按余量分批提交；MAKE 当前只有节点级 child
    // ownership，没有父件输出层 delegated_qty，必须全量创建 child，真正
    // 的本批生产数量在 child 返回后的计划向导中填写。
    final quantities = route == MaterialSupplyRoute.make
        ? _fullResidualSupplyQuantities(route, targets)
        : await _promptSupplyQuantities(route, targets);
    if (quantities == null || !mounted) return null;
    final quantityByIdentity = {
      for (final input in quantities)
        input.actionGroupKey != null
                ? 'GROUP|${input.actionGroupKey}'
                : 'LINE|${input.materialLineId}':
            input,
    };
    final batches = _chunked(targets);
    final preservedSelections = _supplySelectionSnapshot();
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
                  '${input.qty}:${input.safetyReplenishmentQty}',
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
        _restoreValidSupplySelections(preservedSelections);
      });
      final message = switch (route) {
        MaterialSupplyRoute.buy => '采购需求已提交并通知采购',
        // V458：有子层级的委外件由服务端转前置自制，成品入库后才通知委外部。
        MaterialSupplyRoute.subcontract =>
          '委外任务已下达：无子层已通知委外部；有子层已转前置自制，入库后自动通知',
        MaterialSupplyRoute.make => '自制备料任务已创建',
      };
      context.appSuccess(
        batches.length == 1
            ? '$message(${groups.length} 条)'
            : '$message(${groups.length} 条，分 ${batches.length} 批完成)',
      );
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
        _restoreValidSupplySelections(preservedSelections);
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
    return [for (final entry in entries) entry.toInput(entry.maxQty)];
  }

  String _fullMakeQuantityLabel(_MaterialGroup group) {
    final entries = [
      for (final target in _notificationTargetsForGroups([group]))
        _supplyQuantityEntry(target, MaterialSupplyRoute.make),
    ];
    if (entries.isEmpty || entries.any((entry) => entry.maxQty <= 0)) {
      return '全部剩余需求';
    }
    final units = entries
        .map((entry) => entry.unitName?.trim())
        .whereType<String>()
        .where((unit) => unit.isNotEmpty)
        .toSet();
    if (units.length > 1) return '全部剩余需求';
    final total = entries.fold<double>(0, (sum, entry) => sum + entry.maxQty);
    return '全部 ${_qty(total)} ${units.isEmpty ? '个' : units.single}';
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
    );
  }

  /// 保存成功后按钮即变深绿。已下达任务/无需补货/已齐套的节点不再改路线。
  Widget? _nodeRouteButton(
    ThemeData theme,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool selected,
  }) {
    final material = group.representative;
    if (!group.actionable || !_canRoute) return null;
    if (_notifiedTargetOf(material) != null) return null;
    if (material.requiredQty <= 0 || material.shortageQty <= 0) return null;
    final confirmed = material.confirmedRoute;
    if (confirmed != null && !_dirtyRouteGroups.contains(group.key)) {
      return FilledButton.icon(
        key: ValueKey('material-route-change-${material.materialLineId}'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 40),
          backgroundColor: selected ? Colors.white : UtenColors.deepGreen,
          foregroundColor: selected ? UtenColors.deepGreen : Colors.white,
        ),
        onPressed: _busy ? null : () => _pickRoute(group),
        icon: const Icon(Icons.alt_route_rounded, size: 18),
        label: Text('路线 · ${confirmed.label}'),
      );
    }
    if (confirmed == null && material.sourceSuggestion == null) {
      return OutlinedButton.icon(
        key: ValueKey('material-route-pick-${material.materialLineId}'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 40),
          foregroundColor: selected ? Colors.white : null,
        ),
        onPressed: _busy ? null : () => _pickRoute(group),
        icon: const Icon(Icons.alt_route_rounded, size: 18),
        label: const Text('选择路线'),
      );
    }
    return OutlinedButton.icon(
      key: ValueKey('material-route-change-${material.materialLineId}'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 40),
        foregroundColor: selected ? Colors.white : null,
      ),
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
    final preservedSelections = _supplySelectionSnapshot();
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
        _restoreValidSupplySelections(preservedSelections);
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
