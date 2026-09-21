part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisSupplyActionsState
    extends _MaterialAnalysisCandidatesState {
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
    // 2026-09-15 用户口径「点了在等没反馈像卡住」：路线确认同样是分批网络
    // 提交，与下达采购/委外共用同一条全屏加载遮罩通道（宿主页、级联页都听
    // 这份消息）。挂在分批循环起点 = 换桶/数量类确认弹窗已收口的纯网络段。
    bucketActionBusyMessage.value = '正在确认物料路线';
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
    } finally {
      // 与 _notifyRoute 同款兜底：success/conflict/error 各分支漏清任何一条，
      // 这份消息驱动的全屏遮罩就会一直盖住整页吃掉点击。
      bucketActionBusyMessage.value = null;
    }
  }

  /// 分桶详情里就地改供料方式（2026-09-14 用户口径「下达车间/委外/采购里面
  /// 供应方式也可以改变，改变了自动换到其他地方」）。
  ///
  /// 桶归属只认服务端的 `confirmed_route`，所以「换桶」必须真的写一次路线确认；
  /// 主表和分桶复用明确确认后的即时保存；批量入口仍用于采用未确认建议。
  /// 确认同时回写货品主档的默认供应方式，新分析直接从主档读取。
  Future<bool> _confirmRouteChange(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) => _confirmRouteChanges([group], route);

  /// Main preparation table and bucket detail use the same persisted decision.
  Future<bool> _confirmRouteChanges(
    List<_MaterialGroup> groups,
    MaterialSupplyRoute route,
  ) async {
    if (_busy) return false;
    if (!_canRoute) {
      context.appWarning('没有确认物料路线权限');
      return false;
    }
    if (groups.isEmpty ||
        groups.any((group) => !_canEditMaterialRoute(group))) {
      context.appWarning('本行已有下游行动或已被阻断，供料方式不可改');
      return false;
    }
    final material = groups.first.representative;
    final name = material.goodsName ?? material.goodsCode ?? '该物料';
    final current = material.confirmedRoute;
    final ok = await UtenDialog.show(
      context,
      title: '改变供料方式',
      content: Text(
        '把「$name」的供料方式'
        '${current == null ? '确认为' : '从「${current.label}」改为'}'
        '「${route.label}」？\n\n'
        '确认后所选 ${groups.length} 个物料节点立即按新路线归类'
        '(有自制子层的委外件进入「下达车间」先做前置自制)。'
        '同时更新货品资料中的默认供应方式，下次分析默认带出。',
      ),
      confirmLabel: '确认并换桶',
    );
    if (ok != true || !mounted) return false;
    if (_busy) return false;
    setState(() {
      for (final group in groups) {
        _routeDraft[group.key] = route;
        _dirtyRouteGroups.add(group.key);
      }
      _invalidateBucketRowsCache();
    });
    final keys = groups.map((group) => group.key).toSet();
    await _saveRoutes(onlyGroupKeys: keys);
    if (!mounted) return false;
    final analysis = _analysis;
    if (analysis == null) return false;
    return _materialGroups(analysis)
            .where((group) => keys.contains(group.key))
            .every((group) => group.representative.confirmedRoute == route) &&
        keys.every((key) => !_dirtyRouteGroups.contains(key));
  }

  /// Dropdown changes are local. Only selected task identities are submitted.
  Future<void> _createSelectedRoutes() async {
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

  /// 本组「还可下达」的权威量。
  ///
  /// **唯一主口径是服务端投影的 `additionalSupplyRecommendedQty`**
  /// （= max(0, 本批缺口 − 有效在途覆盖)，见 MaterialAnalysisService 的
  /// ACTIVE_FUTURE_COVERAGE_SQL：采购/委外在途、公共认领、以及委外前置自制台账的
  /// `required_qty − notified_qty` 都在里面）。
  ///
  /// 2026-09-15 修正：这个判定原来还捆着「sharedFuturePendingQty 非空 或 已认领 > 0」
  /// 两个条件，读起来像「只有用了公共在途的行才走服务端口径」，实际上服务端恒定
  /// 下发 `sharedFuturePendingQty = 0`（ClaimedFutureState.NONE），条件恒真——
  /// 也就是说下面那条 `缺口 − 已在途` 的回退在真实服务端**永不执行**，却被注释和
  /// ADR-081 §3.1 当成主口径，而全部分桶用例的夹具又只覆盖这条死分支。
  /// 现在把优先级写明白：有服务端字段就用服务端的，回退只服务于缺该字段的旧载荷。
  double _residualSubmitQty(_MaterialGroup group, MaterialSupplyRoute route) {
    if (_isPriorityMakeSupplementGroup(group, route)) {
      // The backend has already deducted issued replenishment responsibility.
      // Do not subtract old MAKE events again or reconstruct from shortage.
      return group.paths.fold(
        0.0,
        (sum, path) =>
            sum +
            (path.hasPriorityMakeSupplement
                ? path.priorityMakeSupplementQty
                : 0),
      );
    }
    return group.paths.fold(
      0.0,
      (sum, path) => sum + path.additionalSupplyRecommendedQty,
    );
  }

  /// 下达数量的默认值。采购桶在「还需安排量」之上，按货品主档的最小起订量
  /// 与订货倍数向上抬一次：`向上取整到倍数( max(还需安排量, 最小起订量) )`。
  ///
  /// 这是**软约束**：抬出来的富余部分走既有公共备货通道，计划员可以改小，
  /// 服务端不硬拦。还需安排量为 0 时不抬量——没有需求就不该因为起订量凭空
  /// 下单。委外与车间桶不抬量（它们会产生下层责任，数量必须与需求一致）。
  double _defaultSubmitQty(_MaterialGroup group, MaterialSupplyRoute route) {
    final residual = _residualSubmitQty(group, route);
    return _submitQtyWithOrderPolicy(group, route, residual);
  }

  /// Apply the goods policy to this batch, never substitute the whole analysis.
  double _submitQtyWithOrderPolicy(
    _MaterialGroup group,
    MaterialSupplyRoute route,
    double quantity,
  ) {
    if (route != MaterialSupplyRoute.buy || quantity <= 0) return quantity;
    // 抬出来的富余是公共备货，没有超量下达权限的人填了也提交不了。
    // 这种情况下只填净需求，由「起订量提示」告诉他要找有权限的人。
    if (!_canOverSupply) return quantity;
    return _raiseToOrderPolicy(
      quantity,
      group.representative.minOrderQty,
      group.representative.orderMultipleQty,
    );
  }

  /// 下达数量格的提示：起订量抬量（默认值被抬高时告诉计划员抬到了多少、富余
  /// 多少；没有超量下达权限时提示「低于起订量」，不静默降级）+ 公共在途自动
  /// 认领（ADR-099：下达时服务端先认领同主仓公共在途，只为余下部分新下单）。
  String? _orderPolicyHint(_MaterialGroup group, MaterialSupplyRoute route) {
    final residual = _residualSubmitQty(group, route);
    if (residual <= 0) return null;
    final claimable = route == MaterialSupplyRoute.make
        ? 0.0
        : group.representative.sharedFutureClaimableQty;
    final claimNote = claimable > 0.0001
        ? '其中 ${_qty(claimable > residual ? residual : claimable)} 可从公共在途自动认领：'
              '下达时服务端先认领、只为余下部分新下单'
        : null;
    if (route != MaterialSupplyRoute.buy) return claimNote;
    final minOrderQty = group.representative.minOrderQty;
    final multiple = group.representative.orderMultipleQty;
    final raised = _raiseToOrderPolicy(residual, minOrderQty, multiple);
    String? policyNote;
    if (raised > residual + 0.0001) {
      policyNote = !_canOverSupply
          ? '本次 ${_qty(residual)} 低于起订量 ${_qty(minOrderQty ?? 0)}，'
                '需由有超量下达权限的人抬量'
          : '已按起订量与整包装抬至 ${_qty(raised)}，'
                '富余 ${_qty(raised - residual)} 归公共备货';
    }
    final notes = [?policyNote, ?claimNote];
    return notes.isEmpty ? null : notes.join('；');
  }

  /// 起订量与整包装的取整规则，单独抽出以便复用与单测。
  static double _raiseToOrderPolicy(
    double quantity,
    double? minOrderQty,
    double? orderMultipleQty,
  ) {
    var target = quantity;
    if (minOrderQty != null && minOrderQty > target) target = minOrderQty;
    if (orderMultipleQty != null && orderMultipleQty > 0) {
      final batches = (target / orderMultipleQty).ceil();
      target = batches * orderMultipleQty;
    }
    // 数量统一保留 4 位小数，避免二进制浮点误差写进下达数量。
    return double.parse(target.toStringAsFixed(4));
  }

  bool _hasIssuedMakeOwnership(ProductionMaterialAnalysisMaterial material) =>
      _taskChildProductOf(material) != null ||
      _hasUnlinkedIssuedPlan(material) ||
      material.notifiedTargets.any(
        (target) =>
            target.status?.toUpperCase() != 'CANCELLED' &&
            (target.documentType == 'PREPLAN_MAKE_TASK' ||
                target.documentType == 'SUBCONTRACT_MAKE_TASK'),
      );

  bool _isPriorityMakeSupplementGroup(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) =>
      route == MaterialSupplyRoute.make &&
      group.paths.any(
        (path) =>
            path.priorityPendingQty > 0.000001 &&
            (path.hasPriorityMakeSupplement || _hasIssuedMakeOwnership(path)),
      );

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
      _isPriorityMakeSupplementGroup(group, route)
      ? _residualSubmitQty(group, route) > 0
      : _residualSubmitQty(group, route) > 0 ||
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

  /// [allowExtra]：还需安排为 0 的组也算可执行（ADR-099 父层级追加：填的量
  /// 就是追加量，服务端按超量分账为公共备货）。
  bool _isExecutableSupplyGroup(
    _MaterialGroup group,
    MaterialSupplyRoute route, {
    bool allowExtra = false,
  }) =>
      (group.actionable ||
          group.paths.any((path) => path.hasPriorityMakeSupplement) ||
          _hasRootStockToAllocate(group, route)) &&
      _planningBlockForGroup(group) == null &&
      group.paths.every(_hasResolvedMaterialSource) &&
      !group.paths.any(
        (path) =>
            _hasUnlinkedIssuedPlan(path) && !path.hasPriorityMakeSupplement,
      ) &&
      (route != MaterialSupplyRoute.make ||
          !group.paths.any(
            (path) =>
                _hasIssuedMakeOwnership(path) &&
                !path.hasPriorityMakeSupplement,
          )) &&
      group.representative.confirmedRoute == route &&
      _draftRoute(group) == route &&
      !_dirtyRouteGroups.contains(group.key) &&
      !_routeBlockedBySafetyGap(group, route) &&
      (allowExtra || _hasSupplySubmitQty(group, route));

  /// 当前路线下仍可执行（路线已确认、有真实余量、未被通知闭合）的操作组。
  List<_MaterialGroup> _executableSupplyGroups(
    MaterialSupplyRoute route, {
    bool allowExtra = false,
  }) {
    final analysis = _analysis;
    if (analysis == null) return const [];
    return _materialGroups(analysis)
        .where(
          (group) =>
              _isExecutableSupplyGroup(group, route, allowExtra: allowExtra),
        )
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
  ///
  /// [silent] = 父件段由「一起下单」弹窗编排（ADR-081，2026-09-14 弹窗前置）：
  /// 只做 notify，跳过两段式自动勾选与总结提示（下层由弹窗接手），返回是否
  /// 提交成功。
  Future<bool> _arrangeSubcontractProduction({
    Set<String>? onlyGroupKeys,
    Map<String, String>? qtyByActionGroupKey,
    bool silent = false,
    bool allowExtra = false,
  }) async {
    final analysis = _analysis;
    if (analysis == null || !_canNotify || _notifyingRoute != null) {
      return false;
    }
    final groups = onlyGroupKeys != null
        ? _executableSupplyGroups(
                MaterialSupplyRoute.subcontract,
                allowExtra: allowExtra,
              )
              .where((group) => onlyGroupKeys.contains(group.key))
              .toList(growable: false)
        : const <_MaterialGroup>[];
    if (groups.isEmpty) {
      if (!silent) context.appInfo('请先勾选要下达的委外件');
      return false;
    }
    final view = await _notifyRoute(
      MaterialSupplyRoute.subcontract,
      onlyGroupKeys: {for (final group in groups) group.key},
      qtyByActionGroupKey: qtyByActionGroupKey,
      silent: silent,
      allowExtra: allowExtra,
    );
    if (!mounted || view == null) return false;
    if (silent) return true;
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
        // 直接外发的委外件（无子层，或 V581 只有一个叶子子件）不建前置自制
        // 子任务：已直接合并生成委外申请，不进入两段式。
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
    if (created > 0) {
      final parts = <String>[
        _l10n.materialPreparedChildCreated(created),
        if (readySelected > 0) _l10n.materialPreparedChildNext,
        if (waiting > 0) '$waiting 个子件状态已变化，请刷新后核对',
        if (needPermission > 0) _l10n.materialPreparedChildNeedPlanner,
      ];
      context.appSuccess(parts.join('；'));
    }
    return true;
  }

  /// 该分析节点在当前快照内是否还有下层节点。**只回答 BOM 形状**：本节点下面
  /// 还有没有东西要办。是不是要先自制目标件再发外，另见
  /// `_subcontractNeedsPreparation`——V581 起「只有一个叶子子件」的委外件有下层
  /// 却直接外发，两者不再等价。经父节点索引判定（原为全表扫描）。
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

  /// 这个产品行在当前快照里还有没有下层（= 点下达会不会把人带进
  /// 「父件 + 下层一起下单」整页）。只看 BOM 形状，供按钮文案使用；真正的
  /// 进页判定仍由 `_pendingChildCascadeRows` 一处给出。
  bool _productHasCascadeChildren(ProductionMaterialAnalysisProduct product) {
    final analysis = _analysis;
    if (analysis == null) return false;
    final root = _rootSupplyMaterialOf(product);
    if (root != null) return _analysisMaterialHasChildren(root);
    final indexes = _analysisIndexes(analysis);
    return indexes
                .productsById[product.analysisLineId]
                ?.hasProductionMaterialChildren ==
            true ||
        (indexes.materialsByProduct[product.analysisLineId]?.any(
              (node) => !node.isRootSupply && node.level == 1,
            ) ??
            false);
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

  /// [silent] = 调用方已经做过一次总结确认、并会自己汇报结果（下层办齐编排，
  /// ADR-081）：跳过本函数的数量确认弹窗与成功提示，避免一次一键下单连弹三层
  /// 确认、连报三条成功。失败提示与 409 恢复照旧。
  Future<ProductionMaterialAnalysisView?> _notifyRoute(
    MaterialSupplyRoute route, {
    Set<String>? onlyGroupKeys,
    Map<String, String>? qtyByActionGroupKey,
    bool silent = false,
    bool allowExtra = false,
  }) async {
    final analysis = _analysis;
    if (analysis == null || !_canNotify || _notifyingRoute != null) {
      return null;
    }
    final groups = _executableSupplyGroups(route, allowExtra: allowExtra)
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
        silent: silent,
      );
    } else {
      quantities = await _resolveSupplyQuantities(
        route,
        targets,
        qtyByActionGroupKey,
        silent: silent,
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
    // 2026-09-12 用户口径「点了没反应像卡住」：采购/委外分块提交期间屏幕中间
    // 给加载遮罩。挂在这里（数量确认弹窗已收口、纯网络段）——挂早了会把确认
    // 弹窗也盖在背后转圈，pumpAndSettle 永不落定（planSubmissionProgress 同款教训）。
    bucketActionBusyMessage.value = switch (route) {
      MaterialSupplyRoute.buy => '正在下达采购任务',
      MaterialSupplyRoute.subcontract => '正在下达委外任务',
      MaterialSupplyRoute.make => '正在创建自制备料任务',
    };
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
      bucketActionBusyMessage.value = null;
      // 服务端**只有真的写了东西才会重建快照**（refreshLocked 换 version/
      // fingerprint）。版本与指纹都没动 = 这次提交一条下达都没产生：可能是别人
      // 刚下达过、在途已完全覆盖，也可能是同一份请求的幂等回放。原来这种情况
      // 照样弹「委外任务已下达」，而那一行一个字节没动，再点一次还是如此——
      // 用户反复遇到的「点了下达、提示成功、行还在未下达」就是它（2026-09-15）。
      // 不当成功：如实说明并返回 null，让「一起下单」的编排在这一段停下。
      final producedNothing =
          current.version == analysis.version &&
          current.fingerprint == analysis.fingerprint;
      setState(() {
        _notifyingRoute = null;
        _clearBulkOperation();
        _applyAnalysis(current);
      });
      if (producedNothing) {
        context.appWarning(
          '本次没有产生任何${route.label}下达：所选行在服务端已无可下达余量'
          '（可能刚被他人下达、或在途已完全覆盖），也可能是同一份请求被幂等回放。'
          '页面已刷新，请重新核对后再提交。',
          force: true,
        );
        return null;
      }
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
      if (!silent) context.appSuccess(message);
      return current;
    } catch (error) {
      if (!mounted) return null;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '提交${route.label}需求',
      )) {
        if (!mounted) return null;
        bucketActionBusyMessage.value = null;
        setState(() {
          _notifyingRoute = null;
          _clearBulkOperation();
        });
        return null;
      }
      if (!mounted) return null;
      bucketActionBusyMessage.value = null;
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
    } finally {
      // 兜底清场（2026-09-14）：忙标志与全屏遮罩原来只在各 return 分支上手动清，
      // 漏任何一条，`_busy` 就永久为真、`bucketActionBusyMessage` 的
      // Positioned.fill 遮罩会一直盖在整页上吃掉所有点击——表现就是用户说的
      // 「按钮点了没反应」，而且刷新页面前好不了。这类状态必须由 finally 收口，
      // 不能指望每条分支都记得清。
      bucketActionBusyMessage.value = null;
      if (mounted && _notifyingRoute != null) {
        setState(() {
          _notifyingRoute = null;
          _clearBulkOperation();
        });
      }
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
    return [for (final entry in entries) entry.toInput(entry.maxQty)];
  }

  /// 委外「下达委外」的数量裁决 + 总结确认（2026-09-06 对齐采购口径）：
  /// **要先自制目标件**的委外件 = 与自制同构的全量剩余（服务端转前置自制，
  /// 不可改量）；**直接外发**的委外件 = 行内数量裁决（校验同采购）。
  /// 两类合并为**一张**总结弹窗二次确认，取消整批放弃。
  ///
  /// V581 起「直接外发」含两种：无子层的纯外协，以及只有一个叶子子件、由我方
  /// 发那颗子件的件——后者也是一张普通委外订货，可分批、可按权限超量，
  /// 不再被当成「创建子件任务必须整量接管」。
  Future<List<MaterialSupplyQuantityInput>?> _resolveSubcontractQuantities(
    List<_MaterialGroup> groups,
    Map<String, String>? qtyByActionGroupKey, {
    bool silent = false,
  }) async {
    const route = MaterialSupplyRoute.subcontract;
    // 要不要先自制目标件再发外：有下层**且**不是 V581「只有一个叶子子件」的
    // 直接外发件。形态由服务端 subcontractOutboundForm 明确告知，旧服务端
    // 返回 null 时 isComponentOutbound 为 false，自然回落旧口径。
    bool needsPreparation(_MaterialGroup group) =>
        !group.representative.isComponentOutbound &&
        _analysisMaterialHasChildren(group.representative);
    final childGroups = groups.where(needsPreparation).toList(growable: false);
    final leafGroups = groups
        .where((group) => !needsPreparation(group))
        .toList(growable: false);
    // 先自制：显式创建 child 时必须全量接管剩余需求（仅当选中含这类行时校验）。
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
    final confirmed =
        silent ||
        await showDialog<bool>(
              context: context,
              builder: (_) => MaterialSupplySubmitConfirmDialog(
                route: route,
                entries: entries,
                quantities: quantities,
                qtyText: _qty,
              ),
            ) ==
            true;
    if (!confirmed) return null;
    return [
      for (var i = 0; i < entries.length; i++)
        // 前 childEntries.length 个是「要先自制」的行——恒不许超量；其后是
        // 直接外发段（无子层 + V581 单一子件），按行内裁决结果决定。
        entries[i].toInput(quantities[i]),
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
    List<_SupplyNotificationTarget> targets,
    Map<String, String>? qtyByActionGroupKey, {
    bool silent = false,
  }) async {
    final adjudicated = _adjudicateSupplyQuantities(
      route,
      targets,
      qtyByActionGroupKey,
    );
    if (adjudicated == null) return null;
    final confirmed =
        silent ||
        await showDialog<bool>(
              context: context,
              builder: (_) => MaterialSupplySubmitConfirmDialog(
                route: route,
                entries: adjudicated.entries,
                quantities: adjudicated.quantities,
                qtyText: _qty,
              ),
            ) ==
            true;
    if (!confirmed) return null;
    return [
      for (var i = 0; i < adjudicated.entries.length; i++)
        adjudicated.entries[i].toInput(adjudicated.quantities[i]),
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
          entry.maxQty <= 0.0001
              ? '「${entry.label}」还需安排 0，填的 ${_qty(qty)} 全是追加的公共备货，'
                    '需要超量下达权限'
              : '「${entry.label}」最多下达 ${_qty(entry.maxQty)}'
                    '（本批缺口 − 已在途需求），超出部分属公共备货、需要超量下达权限，'
                    '请在表格中修改后重试',
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
                    (material.actionable ||
                        material.isRootSupply ||
                        material.hasPriorityMakeSupplement) &&
                    material.actionGroupKey == target.actionGroupKey,
              )
              .toList(growable: false)
        : materials
              .where(
                (material) => material.materialLineId == target.materialLineId,
              )
              .toList(growable: false);
    final representative = lines.isEmpty ? null : lines.first;
    var open = 0.0;
    var safetyStock = 0.0;
    var publicAvailable = 0.0;
    var openSafetySupply = 0.0;
    var safetyGap = 0.0;
    for (final material in lines) {
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
    // 「我方供料的委外件不能吃公共超量备货」——多出来的量会凭空产生一份
    // 无人负责的子件需求，服务端与数据库
    //（preplan_public_surplus_subcontract_leaf_guard）都拒绝。
    //
    // 这里问的是**有没有生产性子层**（V581 的单一子件委外同样有，同样不许超量），
    // 不是「要不要先自制」。原先这一处内联判定只查 childrenByParentNodeKey、
    // 没有根行回退，导致 ROOT_SUPPLY 顶层直委外行被判成「无子层」而放开超量，
    // 与同一批数量裁决的判定相反；改用带根行回退的 _analysisMaterialHasChildren
    // （它不排除 SHIP/REFERENCE，恰好与数据库那条「有任意活动 BOM 边即拒」同口径）。
    final hasProductionChildren =
        representative != null && _analysisMaterialHasChildren(representative);
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
      maxQty: lines.isEmpty
          ? 0
          : _residualSubmitQty(
              _MaterialGroup(key: target.identity, paths: lines),
              route,
            ),
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
