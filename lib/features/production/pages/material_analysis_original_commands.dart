part of 'production_material_analysis_page.dart';

/// Notify and root-plan requests share the existing preparation draft owner.
extension _MaterialOriginalCommandOwner on _MaterialAggregateTableController {
  Future<T> legacyAction<T>(
    Future<T> Function() action, {
    required T busyValue,
  }) async {
    if (legacyUiBusy) return busyValue;
    legacyUiBusy = true;
    if (!owner._preparationSubmissionActive) {
      legacyConfirmedRows.clear();
      legacyRejectedRows.clear();
    }
    try {
      return await owner._withPreparationSubmissionScope(action);
    } finally {
      legacyUiBusy = false;
    }
  }

  List<_MaterialGroup> legacyGroups({
    Set<String> materialIds = const {},
    Set<String> actionKeys = const {},
    Set<String> productIds = const {},
  }) {
    final analysis = owner._analysis;
    if (analysis == null) return const [];
    return owner
        ._analysisIndexes(analysis)
        .groupsByKey
        .values
        .where(
          (group) => group.paths.any(
            (path) =>
                materialIds.contains(path.materialLineId) ||
                actionKeys.contains(path.actionGroupKey) ||
                path.level == 0 && productIds.contains(path.analysisLineId),
          ),
        )
        .toList();
  }

  Map<String, String> legacyLabels(Iterable<_MaterialGroup> groups) => {
    for (final group in groups) group.key: owner._tableGroupLabel(group),
  };
  Set<String> legacyLines(Iterable<_MaterialGroup> groups) => {
    for (final group in groups)
      for (final path in group.paths) path.materialLineId,
  };
  void beginLegacyOriginal(MaterialPreparationOriginalCommand command) {
    if (hasLegacyUnknown || _submittedRequest != null) {
      throw StateError('原下单结果尚未确认，只能核对原票据');
    }
    legacyRejectedRows.removeWhere(
      (key, _) => command.rowLabels.containsKey(key),
    );
    legacyCommand = command;
    legacyCommandScope = owner._sessionScopeKey();
    _legacyUnknown = false;
    error = null;
    legacyDispatchStarted = false;
    draftPulse.value++;
  }

  Future<T> sendLegacyOriginal<T>(Future<T> Function() send) =>
      withDraftMutation(() {
        legacyDispatchStarted = true;
        return send();
      });
  Set<String> get unknownCommandRows {
    if (hasLegacyUnknown) return legacyCommand!.rowLabels.keys.toSet();
    if (!_aggregateUnknown || _submittedRequest == null) return const {};
    final ids = {
      for (final group in _submittedRequest!.groups) ...group.materialLineIds,
    };
    return {
      for (final draft in drafts.values)
        for (final entry in draft.paths.entries)
          if (ids.contains(entry.key)) entry.value.groupKey,
    };
  }

  Future<void> failLegacyOriginal(
    Object failure, {
    bool received = false,
  }) async {
    if (legacyCommand == null) return;
    final rejected =
        !_legacyUnknown &&
        !received &&
        (!legacyDispatchStarted || isDefiniteFreshFormDraftRejection(failure));
    error = productionErrorMessage(failure, fallback: '原下单尚未完成');
    if (!rejected) error = '$error；原编号和原内容已保留，只能原样重试核对';
    if (rejected) {
      for (final key in legacyCommand!.rowLabels.keys) {
        legacyRejectedRows[key] = error!;
      }
      legacyCommand = null;
      legacyCommandScope = null;
      _legacyUnknown = false;
    } else {
      _legacyUnknown = true;
    }
    if (!owner.mounted) return;
    owner._mutateAggregateTable(() {});
    draftPulse.value++;
    if (rejected) {
      try {
        await draftHost?.checkpointFormDraftAfterConfirmedMutation();
      } catch (_) {
        /* durable pre-send evidence is retained */
      }
    } else {
      try {
        await draftHost?.saveFormDraftNow();
      } catch (_) {
        /* the pre-dispatch marker already owns the original request */
      }
    }
  }

  Future<void> acknowledgeLegacyOriginal(
    ProductionMaterialAnalysisView accepted,
  ) async {
    final command = legacyCommand;
    if (command == null) return;
    if (!owner.mounted || owner._sessionScopeKey() != legacyCommandScope) {
      await failLegacyOriginal(StateError('原身份已退休'), received: true);
      return;
    }
    if (accepted.analysisId != command.analysisId) {
      throw const FormatException('原回执对应另一份分析');
    }
    final body = command.toBody();
    final changed =
        accepted.version != body['version'] ||
        accepted.fingerprint != body['fingerprint'];
    owner._mutateAggregateTable(() {
      if (changed) {
        legacyConfirmedRows.addAll(command.rowLabels);
        owner._selectedMaterialGroupKeys.removeAll(command.rowLabels.keys);
        for (final line in command.lineIds) {
          owner._tableUserTypedQty.remove(line);
        }
      }
      legacyCommand = null;
      legacyCommandScope = null;
      _legacyUnknown = false;
      error = null;
    });
    draftPulse.value++;
    try {
      await draftHost?.checkpointFormDraftAfterConfirmedMutation(
        originalReceiptAcknowledged: true,
      );
    } catch (_) {
      if (owner.mounted) owner.context.appWarning('原下单已核对，草稿接续暂未写好，请保留原回执');
    }
  }

  Future<bool>
  retryLegacyOriginal() => owner._withPreparationSubmissionScope(() async {
    final command = legacyCommand;
    final scope = legacyCommandScope;
    if (command == null ||
        saving ||
        !owner.mounted ||
        owner._sessionScopeKey() != legacyCommandScope ||
        owner._analysis?.analysisId != command.analysisId) {
      return false;
    }
    bool current() =>
        owner.mounted &&
        owner._sessionScopeKey() == scope &&
        owner._analysis?.analysisId == command.analysisId;
    var completed = false;
    owner._mutateAggregateTable(() => saving = true);
    try {
      await owner._withOrderProgress(
        rows: math.max(1, command.rowLabels.length),
        body: (progress) async {
          if (progress.stopRequested) return;
          try {
            progress.startSegment(
              '正在按原内容核对下单回执',
              math.max(1, command.rowLabels.length),
            );
            final json = await sendLegacyOriginal(
              () => owner.ref
                  .read(productionPlanRepositoryProvider)
                  .replayMaterialPreparationCommand(command),
            );
            ProductionMaterialAnalysisView accepted;
            List<ProductionGeneratedPlanRef> plans = const [];
            if (command.issuesPlans) {
              final result =
                  await ProductionMaterialGenerateResult.fromJsonResponsive(
                    json,
                  );
              accepted = result.analysis;
              plans = result.plans;
            } else {
              accepted =
                  await ProductionMaterialAnalysisView.fromJsonResponsive(json);
            }
            if (accepted.analysisId != command.analysisId) {
              throw const FormatException('原回执对应另一份分析');
            }
            if (!current()) {
              await failLegacyOriginal(StateError('原身份已退休'), received: true);
              return;
            }
            owner._mutateAggregateTable(() {
              owner._applyAnalysis(accepted);
              for (final plan in plans) {
                owner._preparationPlanResults[plan.planId] = plan;
              }
            });
            await acknowledgeLegacyOriginal(accepted);
            completed = true;
            if (!current()) return;
            if (owner.mounted) {
              if (plans.isNotEmpty) {
                refreshAfterProductionPlanGenerated(owner.ref);
              }
              refreshBadges(owner.ref);
              owner.context.appSuccess('原下单回执已核对；未提交的行仍保留原输入');
            }
            progress.finishSegment();
            completed = true;
          } catch (failure) {
            await failLegacyOriginal(failure);
            if (owner.mounted && current()) {
              owner.context.appWarning(
                '${productionErrorMessage(failure, fallback: '原回执暂未取得')}；原编号和原内容仍保留，只能原样重试核对',
              );
            }
          } finally {
            if (owner.mounted) {
              owner._mutateAggregateTable(() => saving = false);
            }
          }
        },
      );
    } finally {
      if (owner.mounted) owner._mutateAggregateTable(() => saving = false);
    }
    return completed;
  });
}
