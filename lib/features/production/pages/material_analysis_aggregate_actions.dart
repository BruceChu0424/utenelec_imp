part of 'production_material_analysis_page.dart';

extension _MaterialAggregateActions on _MaterialAggregateTableController {
  Widget actionCell(_MaterialAggregate aggregate) {
    // 来源车间 / 负责人 / 比例不同时，这一行下单会自动分成几张工单
    // (ADR-120 §8)：在办理列直接写明，悬浮逐张列出参数和数量。
    final split = splitNote(aggregate);
    final note = split == null
        ? null
        : Tooltip(
            message: split.detail,
            child: Text(
              split.headline,
              key: ValueKey('material-aggregate-split-${aggregate.key}'),
            ),
          );
    final withdraw = withdrawCell(
      materialLineIds: aggregate.paths.map((path) => path.materialLineId),
      hasOrdered: orderedQty(aggregate) > 0.000000001,
      note: note,
      groups: groupsOf(aggregate).toList(growable: false),
    );
    if (withdraw != null) return withdraw;
    // 一张单都没下：只给调拨入口（2026-10-10 用户口径二次修订——「勾选后下单」
    // 提示文字删除，分单说明保留）。调拨是「不买现货先从别的计划调入」的替代
    // 路线，放在与下单同级的办理列。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [aggregateTransferCell(aggregate), ?note],
    );
  }

  /// 聚合行（未下单）的调拨按钮。调拨落点是**一条具体来源路径**（让料关系按
  /// 物料行记账），聚合行只做入口：
  /// - 可调量按**货品+颜色+单位维度的供方池**显示——服务端对同维度每条合格
  ///   路径给的是同一个池量，取路径最大值即池量，不逐路径相加（见
  ///   [_MaterialAnalysisMaterialTableState._tableAggregateTransferableInQty]）。
  /// - 只有一条合格路径（有池量且未锁进汇总草稿）直接开调拨选择器；多条先
  ///   弹路径选择（缺口大者在前），选完再开——调进哪条路径记在哪行的账上。
  Widget aggregateTransferCell(_MaterialAggregate aggregate) {
    final owner = this.owner;
    final pool = owner._tableAggregateTransferableInQty(aggregate.paths);
    final candidates = owner._aggregateTransferPaths(aggregate);
    String? reason;
    if (!owner._canCrossReallocate) {
      reason = '你没有「跨计划调拨」的权限，请找管理员开通';
    } else if (candidates.isEmpty) {
      reason = pool > 0 ? '来源路径都已锁进汇总草稿，先下达或撤销草稿再调拨' : '现在没有别的计划锁着这个物料可以调给你';
    }
    return owner._materialTableHandleButton(
      Theme.of(owner.context),
      key: 'material-aggregate-transfer-${aggregate.key}',
      icon: Icons.swap_horiz_rounded,
      label: '调拨',
      tooltip: reason ?? '可从别的计划调入 ${owner._qty(pool)}（同料各来源共享同一供方池）',
      onTap: reason == null && !owner._busy
          ? () => unawaited(_openAggregateTransfer(aggregate, candidates))
          : null,
    );
  }

  Future<void> _openAggregateTransfer(
    _MaterialAggregate aggregate,
    List<ProductionMaterialAnalysisMaterial> candidates,
  ) async {
    final owner = this.owner;
    if (candidates.isEmpty) return;
    final target = candidates.length == 1
        ? candidates.single
        : await _pickAggregateTransferPath(candidates);
    if (target == null || !owner.mounted) return;
    final analysis = owner._analysis;
    if (analysis == null) return;
    final group = owner
        ._analysisIndexes(analysis)
        .groupsByLine[target.materialLineId];
    if (group != null) {
      await owner._showTransferLauncher(group);
    }
  }

  Future<ProductionMaterialAnalysisMaterial?> _pickAggregateTransferPath(
    List<ProductionMaterialAnalysisMaterial> candidates,
  ) async {
    final owner = this.owner;
    return showDialog<ProductionMaterialAnalysisMaterial>(
      context: owner.context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('material-aggregate-transfer-path-picker'),
        title: const Text('调入到哪条来源路径？'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                child: Text(
                  '调拨量记到所选路径的物料行上，其余路径缺口不变；同料各来源'
                  '共享同一供方池。',
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final path in candidates)
                      ListTile(
                        key: ValueKey(
                          'material-aggregate-transfer-path-${path.materialLineId}',
                        ),
                        dense: true,
                        title: Text(sourceLabel(path)),
                        subtitle: Text(
                          '缺口 ${owner._qty(path.shortageQty)} · 可调入 '
                          '${owner._qty(owner._tableTransferableIn[path.materialLineId] ?? 0)}',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(dialogContext).pop(path),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('material-aggregate-transfer-path-back'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }

  /// 按物料汇总视图顶层产品行的办理格（2026-10-09 用户口径「明明已下单，
  /// 顶层的物料办理不该还是调拨」）：已下单后与聚合行同一撤回口径——有可
  /// 撤回任务给撤回按钮、自制计划给「查看计划 + 整批撤回」；一张单
  /// 都没下时返回 null，调用方回落到调拨入口（2026-10-10 根供给行开放
  /// 跨计划调拨后与按产品视图同一枚按钮）。
  Widget? topLevelWithdrawCell(_MaterialGroup group) => withdrawCell(
    materialLineIds: group.paths.map((path) => path.materialLineId),
    hasOrdered: owner._tableGroupIssuedQty(group) > 0.000000001,
    keyPrefix: 'material-top-level',
    groups: [group],
  );

  /// 可撤回供给任务按钮列 + 「已下单，暂无可撤回任务」空态。沿同一精确来源图
  /// 解析 [materialLineIds] 的真实单据（聚合行与汇总视图顶层产品行共用，2026-10-09
  /// 抽出）；既没有可撤回任务也没有下单记录时返回 null，空态交还调用方。
  /// [keyPrefix] 只是测试锚点前缀，两个入口各自稳定。
  ///
  /// [groups] 供空态分流（2026-10-10）：自制组的下达走 issue-plans 生成生产计划，
  /// 不进供给行动表——actionIds 为空是常态。全部组都按自制锚点计划下达时不显
  /// 示「已下达车间计划 N」文字行（2026-10-10 二次修订，说明进整批撤回的悬浮），
  /// 锚点带计划号且有查看权限时给「查看计划」入口（与按产品视图的计划引用同
  /// 一路由），有取消计划包权限时给「整批撤回 单号」（取消最新计划包，与子
  /// 层级撤回按钮同一形态）；真下了供给单而无可撤回任务的行维持
  /// 「已下单，暂无可撤回任务」。
  Widget? withdrawCell({
    required Iterable<String> materialLineIds,
    required bool hasOrdered,
    Widget? note,
    String keyPrefix = 'material-aggregate',
    List<_MaterialGroup>? groups,
  }) {
    final analysis = owner._analysis;
    final sources = analysis == null
        ? null
        : owner._analysisIndexes(analysis).sourceGraph.resolve(materialLineIds);
    final pendingReversals =
        sources?.pendingReversalActionIds ?? const <String>{};
    final actionIds =
        sources?.activeActionIds
            .where((id) {
              final action = owner._supplyActionOf(id);
              return action != null &&
                  (!const {
                        'CANCELLED',
                        'REVERSED',
                        'WITHDRAWN',
                      }.contains(action.status) ||
                      pendingReversals.contains(id)) &&
                  action.operationType != 'FUTURE_TRANSFER';
            })
            .toList(growable: false) ??
        const <String>[];
    if (actionIds.isEmpty) {
      if (!hasOrdered) return null;
      final makePlan = _issuedMakePlanOf(groups ?? const []);
      if (makePlan != null) {
        final anchor = makePlan.anchor;
        final viewPlan = anchor == null || !owner._canViewPlans || owner._busy
            ? null
            : TextButton(
                key: ValueKey('$keyPrefix-view-plan'),
                onPressed: () => unawaited(
                  owner.context.push(
                    RoutePath.productionPlanDetail(anchor.planId),
                  ),
                ),
                child: Text(anchor.planNo ?? '查看计划'),
              );
        // 2026-10-10 用户口径二次修订：不再显示「已下达车间计划 N」文字行；
        // 整批撤回（=取消最新生产计划包，与生产计划详情同一端点/必填原因/
        // 幂等键）与子层级撤回按钮同一形态——默认色 TextButton + 单号，说明
        // 进悬浮。仅未开工且无执行事实的计划包可取消，取消后分析静默重载。
        final planNo = anchor?.planNo?.trim();
        final cancelPlan = anchor == null || !owner._canCancelPlanningPackage
            ? null
            : Tooltip(
                message:
                    '已下达车间计划 ${owner._qty(makePlan.qty)}'
                    '${makePlan.unit == null ? '' : ' ${makePlan.unit}'}。'
                    '整批撤回 = 取消最新计划包'
                    '${(planNo ?? '').isEmpty ? '' : '（$planNo）'}，'
                    '仅未开工且没有执行事实的计划包可取消，系统会原子释放占用并'
                    '关闭可撤销的下游草稿；已开工计划的撤回在生产计划里办理。',
                child: TextButton(
                  key: ValueKey('$keyPrefix-cancel-plan'),
                  onPressed: owner._busy
                      ? null
                      : () => unawaited(
                          owner._cancelIssuedPlanningPackage(
                            planId: anchor.planId,
                            planNo: planNo,
                          ),
                        ),
                  child: Text(
                    '整批撤回${(planNo ?? '').isEmpty ? '' : ' $planNo'}',
                  ),
                ),
              );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [?viewPlan, ?cancelPlan, ?note],
        );
      }
      final issued = Tooltip(
        message: sources?.complete == false
            ? '来源单据关联尚未完整返回，请刷新后核对。'
            : '已有下单记录，当前没有可撤回的供给任务；请在单据详情核对处理状态。',
        child: Text('已下单，暂无可撤回任务', key: ValueKey('$keyPrefix-issued')),
      );
      return note == null
          ? issued
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [issued, note],
            );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final id in actionIds)
          TextButton(
            key: ValueKey('$keyPrefix-cancel-$id'),
            onPressed:
                owner._busy ||
                    sources?.complete != true ||
                    !owner._canCancelSpecificAction(id)
                ? null
                : () => unawaited(owner._cancelMaterialAction(id)),
            child: Text(
              '${pendingReversals.contains(id)
                  ? owner._l10n.materialNotificationReversalReconcile
                  : owner._supplyOperationType(id) == 'AGGREGATE_SUPPLY'
                  ? '整批撤回'
                  : owner._isSharedFutureClaimAction(id)
                  ? '撤回认领'
                  : '撤回'} '
              '${owner._supplyActionOf(id)?.documentNo ?? ''}',
            ),
          ),
        ?note,
      ],
    );
  }

  /// 空态分流的「已下达车间计划」事实：[groups] 非空且**全部**按自制锚点计划
  /// 下达（[_tableUsesMakeAnchor] 且锚点 issuedPlanQty>0，判据与
  /// [_tableGroupIssuedQty] 的自制分支同源）才成立；锚点按 analysisLineId 去重
  /// 后累计已下达量（同一锚点多路径可见时只算一次），并带上锚点最新计划号供
  /// 入口跳转。混有供给单 / 锚点未建 / 未下达的返回 null，空态走原文案。
  ({double qty, String? unit, ({String planId, String? planNo})? anchor})?
  _issuedMakePlanOf(List<_MaterialGroup> groups) {
    if (groups.isEmpty) return null;
    var qty = 0.0;
    final seenAnchors = <String>{};
    ({String planId, String? planNo})? anchor;
    for (final group in groups) {
      final product = owner._tableIssuedMakeAnchorOf(
        group,
        authoritative: true,
      );
      if (product == null) return null;
      if (seenAnchors.add(product.analysisLineId)) {
        qty +=
            product.issuedPlanQty * owner._tableAnchorUnitRate(group, product);
        final planId = product.latestPlanId?.trim();
        if (anchor == null && planId != null && planId.isNotEmpty) {
          anchor = (planId: planId, planNo: product.latestPlanNo?.trim());
        }
      }
    }
    return (
      qty: qty,
      unit: groups.first.representative.unitName?.trim(),
      anchor: anchor,
    );
  }

  Future<bool> cancelAction(String actionId) async {
    final analysis = owner._analysis;
    if (analysis == null ||
        owner._busy ||
        !owner._canCancelSpecificAction(actionId)) {
      return false;
    }
    final sessionScope = owner._sessionScopeKey();
    final affected = <ProductionMaterialAnalysisMaterial, BigInt>{};
    for (final material in analysis.materials) {
      for (final target in material.notifiedTargets) {
        if (target.actionId == actionId && target.status != 'CANCELLED') {
          final allocated = financeExactDecimalUnits(
            materialPresentationFact(
              target.quantityFactsExact,
              'allocatedQty',
              target.allocatedQty,
            ),
          );
          if (allocated == null || allocated.isNegative) {
            owner.context.appWarning('此批次缺少完整来源份额，请刷新核对后再整批撤回');
            return false;
          }
          affected.update(
            material,
            (value) => value + allocated,
            ifAbsent: () => allocated,
          );
        }
      }
    }
    final graph = owner._analysisIndexes(analysis).sourceGraph;
    if (analysis.materials.any(
      (material) =>
          ownsLine(material.materialLineId) &&
          graph
              .resolve([material.materialLineId])
              .activeActionIds
              .contains(actionId),
    )) {
      owner.context.appWarning('此批次来源仍有汇总草稿，请先下达或撤销草稿再整批撤回');
      return false;
    }
    final action = owner._supplyActionOf(actionId)!;
    final allocated = affected.values.fold<BigInt>(
      BigInt.zero,
      (sum, value) => sum + value,
    );
    BigInt? actionUnits(String key, double value) => financeExactDecimalUnits(
      materialPresentationFact(action.quantityFactsExact, key, value),
    );
    final requested = actionUnits('requestedQty', action.requestedQty);
    final public = actionUnits('publicSurplusQty', action.publicSurplusQty);
    final safety = actionUnits(
      'safetyReplenishmentQty',
      action.safetyReplenishmentQty,
    );
    if (requested == null ||
        public == null ||
        safety == null ||
        requested.isNegative ||
        public.isNegative ||
        safety.isNegative ||
        allocated != requested ||
        affected.isEmpty) {
      owner.context.appWarning('此批次来源资料不完整，请刷新核对后再整批撤回');
      return false;
    }
    String quantity(BigInt units) =>
        financeExactTrimmed(financeExactDecimalFromUnits(units))!;
    final total = allocated + public + safety;
    var reason = '';
    final confirmed = await UtenDialog.show(
      owner.context,
      title: '整批撤回供给任务？',
      confirmLabel: '确认整批撤回',
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '将撤回本批全部来源，总量 ${quantity(total)}，其中公共备货 ${quantity(public)}${safety == BigInt.zero ? '' : '，安全补库 ${quantity(safety)}'}。',
              ),
              for (final entry in affected.entries)
                Text(
                  '${sourceLabel(entry.key)}：${quantity(entry.value)} ${entry.key.unitName ?? ''}',
                ),
              const Text('已实际领用、报工或有后续单据的批次会由系统核对后阻止撤回。'),
              TextField(
                key: const Key('material-aggregate-cancel-reason'),
                onChanged: (value) => reason = value,
                maxLength: 1000,
                decoration: const InputDecoration(labelText: '撤回原因（选填）'),
              ),
            ],
          ),
        ),
      ),
    );
    reason = reason.trim();
    if (confirmed != true || !owner.mounted) return false;
    if (!owner._cancellationStillCurrent(analysis, actionId, sessionScope)) {
      return false;
    }
    final key = businessIdempotencyKey(
      'material-aggregate-cancel',
      '$actionId|${analysis.analysisId}|${analysis.version}|${analysis.fingerprint}|$reason',
    );
    owner._mutateAggregateTable(() => owner._cancellingAction = true);
    try {
      final current = await owner.ref
          .read(productionPlanRepositoryProvider)
          .cancelAggregateMaterialOrder(
            analysis: analysis,
            actionId: actionId,
            idempotencyKey: key,
            reason: reason,
          );
      if (!owner.mounted ||
          !owner._sameAnalysisSnapshot(analysis, sessionScope)) {
        return false;
      }
      owner._mutateAggregateTable(() => owner._applyAnalysis(current));
      owner.context.appSuccess('整批任务已撤回，来源需求已按最新事实更新');
      return true;
    } catch (failure) {
      if (owner.mounted &&
          owner._sameAnalysisSnapshot(analysis, sessionScope)) {
        owner.context.appWarning(
          productionErrorMessage(failure, fallback: '整批撤回失败，请核对后重试'),
        );
      }
      return false;
    } finally {
      if (owner.mounted) {
        owner._mutateAggregateTable(() => owner._cancellingAction = false);
      }
    }
  }
}
