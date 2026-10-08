part of 'production_material_analysis_page.dart';

extension _MaterialAggregateActions on _MaterialAggregateTableController {
  Widget actionCell(_MaterialAggregate aggregate) {
    final analysis = owner._analysis;
    final sources = analysis == null
        ? null
        : owner
              ._analysisIndexes(analysis)
              .sourceGraph
              .resolve(aggregate.paths.map((path) => path.materialLineId));
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
    if (actionIds.isEmpty) {
      if (orderedQty(aggregate) > 0) {
        final issued = Tooltip(
          message: sources?.complete == false
              ? '来源单据关联尚未完整返回，请刷新后核对。'
              : '已有下单记录，当前没有可撤回的供给任务；请在单据详情核对处理状态。',
          child: Text(
            '已下单，暂无可撤回任务',
            key: ValueKey('material-aggregate-issued-${aggregate.key}'),
          ),
        );
        return note == null
            ? issued
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [issued, note],
              );
      }
      return note ?? const Text('勾选后下单');
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final id in actionIds)
          TextButton(
            key: ValueKey('material-aggregate-cancel-$id'),
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
