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
    final hasOrdered = orderedQty(aggregate) > 0;
    final withdraw = withdrawCell(
      materialLineIds: aggregate.paths.map((path) => path.materialLineId),
      hasOrdered: hasOrdered,
      note: hasOrdered ? note : null,
      groups: groupsOf(aggregate).toList(growable: false),
    );
    if (hasOrdered) return withdraw ?? const Text('已下单');
    // Claims can be withdrawn without an order ever having been placed. Keep
    // their reversal entry alongside transfer until authoritative ordered
    // quantity becomes positive; neither history nor a claim locks transfer.
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (withdraw != null) Semantics(container: true, child: withdraw),
          Semantics(container: true, child: aggregateTransferCell(aggregate)),
          ?note,
        ],
      ),
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
      builder: (dialogContext) => UtenDialogFrame(
        key: const Key('material-aggregate-transfer-path-picker'),
        maxWidth: 560,
        child: CustomScrollView(
          primary: false,
          shrinkWrap: true,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      namesRoute: true,
                      header: true,
                      child: Text(
                        '调入到哪条来源路径？',
                        style: Theme.of(dialogContext).textTheme.titleLarge,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      '调拨量记到所选路径的物料行上，其余路径缺口不变；同料各来源'
                      '共享同一供方池。',
                      style: Theme.of(dialogContext).textTheme.bodySmall
                          ?.copyWith(
                            color: Theme.of(
                              dialogContext,
                            ).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final path = candidates[index];
                return ListTile(
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
                );
              }, childCount: candidates.length),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(UtenSpacing.s8),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: TextButton(
                    key: const ValueKey(
                      'material-aggregate-transfer-path-back',
                    ),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('返回'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 按物料汇总视图顶层产品行的办理格（2026-10-09 用户口径「明明已下单，
  /// 顶层的物料办理不该还是调拨」）：已下单后与聚合行同一撤回口径——有可
  /// 撤回任务给「整批撤回 + 单号」文字入口；一张单
  /// 都没下时返回 null，调用方回落到调拨入口（2026-10-10 根供给行开放
  /// 跨计划调拨后与按产品视图同一枚按钮）。
  Widget? topLevelWithdrawCell(_MaterialGroup group) => withdrawCell(
    materialLineIds: group.paths.map((path) => path.materialLineId),
    hasOrdered: owner._tableGroupIssuedPositive(group),
    keyPrefix: 'material-top-level',
    groups: [group],
  );

  /// 顶层、普通子件和共享批次共用「整批撤回 + 真实计划号」文字入口；
  /// 展示引用与撤回身份分开，历史供给行动仍按原 UUID 办理。
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
    final entries = <Widget>[];
    final shownPlanIds = <String>{};

    // 共享批次只沿行动的准确锚点取计划，不能用同货品或首个来源猜测。
    for (final id in actionIds) {
      final action = owner._supplyActionOf(id)!;
      final product = _actionMakeProduct(action);
      final shared = product?.sourceType == 'AGGREGATE_MAKE';
      final plans = _actionMakePlans(action);
      if (plans.isNotEmpty) {
        var planIndex = 0;
        for (final plan in plans) {
          if (!shownPlanIds.add(plan.planId)) continue;
          final suffix = planIndex++ == 0 ? '' : '-${plan.planId}';
          entries.add(
            _planHandleEntry(
              plan,
              cancelKey: '$keyPrefix-cancel-$id$suffix',
              canCancel: shared
                  ? owner._canCancelSpecificAction(id) &&
                        owner._hasPlanLifecyclePermission(plan)
                  : owner._canWithdrawIssuedAnalysisPlan(plan),
              cancelTooltip: shared
                  ? '整批撤回 ${_planLabel(plan)}。撤回本批全部来源，确认时逐条核对来源数量；已领用、报工或有后续单据的批次由系统核对后阻止撤回。'
                  : '整批撤回 ${_planLabel(plan)}。撤回此生产计划及有效执行安排，恢复对应来源的待安排量；已有执行或库存依赖时阻止撤回。',
              onCancel: sources?.complete == true && !owner._busy
                  ? () => unawaited(
                      shared
                          ? owner._cancelMaterialAction(id)
                          : owner._withdrawIssuedAnalysisPlan(plan),
                    )
                  : null,
            ),
          );
        }
        continue;
      }
      if (action.route == MaterialSupplyRoute.make &&
          action.documentType == 'PREPLAN_MAKE_TASK') {
        if (product?.sourceType == 'MAKE_COMPONENT' &&
            product!.issuedPlanQty == 0) {
          entries.add(const Text('待下达生产计划'));
          continue;
        }
        entries.add(
          _unresolvedMakeTaskEntry(
            action,
            keyPrefix: keyPrefix,
            complete: sources?.complete == true,
          ),
        );
        continue;
      }
      // 采购、委外、公共认领和待核对冲正沿用其原单据与撤回流程。
      entries.add(
        _withdrawHandleButton(
          key: '$keyPrefix-cancel-$id',
          onTap:
              owner._busy ||
                  sources?.complete != true ||
                  !owner._canCancelSpecificAction(id)
              ? null
              : () => unawaited(owner._cancelMaterialAction(id)),
          label:
              '${pendingReversals.contains(id)
                  ? owner._l10n.materialNotificationReversalReconcile
                  : action.operationType == 'AGGREGATE_SUPPLY'
                  ? '整批撤回'
                  : owner._isSharedFutureClaimAction(id)
                  ? '撤回认领'
                  : '撤回'} ${action.documentNo ?? ''}',
        ),
      );
    }

    // 原产品自己的多个有效计划也逐张列出，不能用最新计划冒充全部计划。
    var ordinaryIndex = 0;
    for (final group in groups ?? const <_MaterialGroup>[]) {
      final product =
          owner._tableIssuedMakeAnchorOf(group, authoritative: true) ??
          owner._tableLegacyAnchorWithSharedSupply(group, authoritative: true);
      if (product == null || product.sourceType == 'AGGREGATE_MAKE') continue;
      for (final plan in _productPlans(product)) {
        if (!shownPlanIds.add(plan.planId)) continue;
        final suffix = ordinaryIndex++ == 0 ? '' : '-${plan.planId}';
        entries.add(
          _planHandleEntry(
            plan,
            cancelKey: '$keyPrefix-cancel-plan$suffix',
            canCancel: owner._canWithdrawIssuedAnalysisPlan(plan),
            cancelTooltip:
                '整批撤回 ${_planLabel(plan)}。撤回此生产计划及有效执行安排，'
                '恢复对应来源的待安排量；已领用、报工或有后续单据时系统阻止撤回。',
            onCancel: sources?.complete == true && !owner._busy
                ? () => unawaited(owner._withdrawIssuedAnalysisPlan(plan))
                : null,
          ),
        );
      }
    }
    if (entries.isEmpty) {
      if (!hasOrdered) return null;
      entries.add(
        Tooltip(
          message: sources?.complete == false
              ? '来源单据关联尚未完整返回，请刷新后核对。'
              : '已有下单记录，当前没有可撤回的供给任务；请在单据详情核对处理状态。',
          child: Text('已下单，暂无可撤回任务', key: ValueKey('$keyPrefix-issued')),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [...entries, ?note],
    );
  }

  List<MaterialAnalysisPlanReference> _productPlans(
    ProductionMaterialAnalysisProduct product,
  ) {
    final references = product.planReferences;
    if (references.isNotEmpty) {
      return references.where((plan) => plan.planId.trim().isNotEmpty).toList();
    }
    // 兼容旧服务器，回退仍使用准确产品身份对应的最新计划。
    final planId = product.latestPlanId?.trim();
    return planId == null || planId.isEmpty
        ? const []
        : [
            MaterialAnalysisPlanReference(
              planId: planId,
              planNo: product.latestPlanNo,
            ),
          ];
  }

  /// 表格排序和导出沿用界面准确计划引用，不回显内部制造任务编号。
  String? planText({
    required Iterable<String> materialLineIds,
    required Iterable<_MaterialGroup> groups,
  }) {
    final analysis = owner._analysis;
    if (analysis == null) return null;
    final sources = owner
        ._analysisIndexes(analysis)
        .sourceGraph
        .resolve(materialLineIds);
    final plans = <String, String>{};
    var unresolved = false;
    var pendingPlan = false;
    for (final id in sources.activeActionIds) {
      final action = owner._supplyActionOf(id);
      if (action == null ||
          const {
            'CANCELLED',
            'REVERSED',
            'WITHDRAWN',
          }.contains(action.status)) {
        continue;
      }
      final references = _actionMakePlans(action);
      for (final plan in references) {
        plans[plan.planId] = _planLabel(plan);
      }
      if (references.isEmpty &&
          action.route == MaterialSupplyRoute.make &&
          action.documentType == 'PREPLAN_MAKE_TASK') {
        final product = _actionMakeProduct(action);
        if (product?.sourceType == 'MAKE_COMPONENT' &&
            product!.issuedPlanQty == 0) {
          pendingPlan = true;
        } else {
          unresolved = true;
        }
      }
    }
    for (final group in groups) {
      final product =
          owner._tableIssuedMakeAnchorOf(group, authoritative: true) ??
          owner._tableLegacyAnchorWithSharedSupply(group, authoritative: true);
      if (product == null || product.sourceType == 'AGGREGATE_MAKE') continue;
      for (final plan in _productPlans(product)) {
        plans[plan.planId] = _planLabel(plan);
      }
    }
    final labels = [
      ...plans.values,
      if (pendingPlan) '待下达生产计划',
      if (unresolved) '生产任务待核对',
    ];
    return labels.isEmpty ? null : labels.join('、');
  }

  List<MaterialAnalysisPlanReference> _actionMakePlans(
    MaterialAnalysisSupplyAction action,
  ) {
    final product = _actionMakeProduct(action);
    return product == null ? const [] : _productPlans(product);
  }

  ProductionMaterialAnalysisProduct? _actionMakeProduct(
    MaterialAnalysisSupplyAction action,
  ) {
    if (action.route != MaterialSupplyRoute.make ||
        action.documentType != 'PREPLAN_MAKE_TASK') {
      return null;
    }
    final analysis = owner._analysis;
    if (analysis == null) return null;
    final product = owner
        ._analysisIndexes(analysis)
        .productsById[action.documentId];
    if (product == null ||
        !const {
          'AGGREGATE_MAKE',
          'MAKE_COMPONENT',
        }.contains(product.sourceType)) {
      return null;
    }
    return product;
  }

  String _planLabel(MaterialAnalysisPlanReference plan) =>
      plan.planNo?.trim().isNotEmpty == true
      ? plan.planNo!.trim()
      : '生产计划（单号待核对）';

  /// 相同的文字入口：计划号只显示一次，点击后先弹窗核对撤回。
  Widget _planHandleEntry(
    MaterialAnalysisPlanReference plan, {
    required String cancelKey,
    required bool canCancel,
    required String cancelTooltip,
    required VoidCallback? onCancel,
  }) {
    return _withdrawHandleButton(
      key: cancelKey,
      label: '整批撤回 ${_planLabel(plan)}',
      tooltip: canCancel
          ? cancelTooltip
          : '当前没有整批撤回权限或计划审核状态尚未完整返回。$cancelTooltip',
      onTap: canCancel ? onCancel : null,
    );
  }

  /// 各供给路线使用同一紧凑按钮，长单号省略但悬浮说明保持完整。
  Widget _withdrawHandleButton({
    required String key,
    required String label,
    String? tooltip,
    required VoidCallback? onTap,
  }) => Tooltip(
    message: tooltip ?? label,
    child: TextButton(
      key: ValueKey(key),
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.all(UtenSpacing.s4),
        minimumSize: Size(
          UtenControlMetrics.minimumHitExtent(owner.context, desktop: 24),
          UtenControlMetrics.controlHeight(owner.context, desktop: 32),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );

  Widget _unresolvedMakeTaskEntry(
    MaterialAnalysisSupplyAction action, {
    required String keyPrefix,
    required bool complete,
  }) => _withdrawHandleButton(
    key: '$keyPrefix-cancel-${action.actionId}',
    label: '整批撤回 · 生产任务待核对',
    tooltip: '没有完整的生产计划关联，请刷新核对。整批撤回生产任务时核对全部来源和实际执行事实。',
    onTap:
        complete &&
            !owner._busy &&
            owner._canCancelSpecificAction(action.actionId)
        ? () => unawaited(owner._cancelMaterialAction(action.actionId))
        : null,
  );

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
                decoration: const UtenInputDecoration(
                  InputDecoration(labelText: '撤回原因（选填）'),
                ),
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
