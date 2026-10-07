part of 'production_material_analysis_page.dart';

/// One material stays one operation even when its source nodes occur at
/// different depths. Only independent groups can share a submission round.
final class _MaterialAggregateSubmission {
  _MaterialAggregateSubmission(this.table);
  final _MaterialAggregateTableController table;
  _MaterialAnalysisMaterialTableState get owner => table.owner;
  bool running = false;
  int? _dependencyRevision;
  Object? _dependencyAnalysis;
  String? _dependencyScope;
  Map<String, Set<String>>? _dependencyCache;

  Set<String> previewRoots() {
    final keys = table.drafts.keys.toSet();
    final dependencies = _dependencies(keys);
    return _window(
      keys.where((key) => dependencies[key]?.isEmpty ?? true).toSet(),
    );
  }

  Set<String> _window(Set<String> keys) {
    final sources = <String, int>{};
    final requestGroups = <String, int>{};
    for (final key in keys) {
      final draft = table.drafts[key]!;
      if (draft.lineIds.isEmpty ||
          draft.lineIds.length > materialAggregateMaxSources) {
        throw FormatException(
          '「${draft.label}」来源范围为 ${draft.lineIds.length} 条，单物料必须为 1 至 $materialAggregateMaxSources 条；请核对分析范围，系统不会拆成多单',
        );
      }
      sources[key] = draft.lineIds.length;
      // 车间 / 负责人 / 比例不同的草稿会分成几组提交(ADR-120 §8)，按组计数。
      requestGroups[key] = table.requestGroupCount(draft);
    }
    return materialAggregateRequestWindow(
      sources,
      requestGroupsByKey: requestGroups,
    ).toSet();
  }

  Future<bool> submit(
    List<_MaterialGroup> selected, {
    bool confirmed = false,
    bool? skipAutoClaim,
  }) => owner._withPreparationSubmissionScope(
    () => _submit(selected, confirmed: confirmed, skipAutoClaim: skipAutoClaim),
  );

  Future<bool> _submit(
    List<_MaterialGroup> selected, {
    required bool confirmed,
    bool? skipAutoClaim,
  }) async {
    if (running || table.saving || selected.isEmpty) return false;
    // 2026-09-29 用户口径：编排入口(main 表全选下单)已问过并把标志传进来(非 null)；
    // 汇总视图直接下单在这里问一次「是否扣可用数量」，整轮所有段共用同一选择。
    final bool skipClaims;
    if (skipAutoClaim != null) {
      skipClaims = skipAutoClaim;
    } else {
      final claimUsage = await owner._askClaimableSupplyUsage(selected, null);
      if (claimUsage == null) return false;
      skipClaims = !claimUsage;
    }
    if (!owner.mounted) return false;
    final keys = selected
        .map((group) => owner._aggregateKeyOf(group.representative))
        .toSet();
    owner._mutateAggregateTable(() {
      for (final key in keys) {
        final scope = selected
            .where(
              (group) => owner._aggregateKeyOf(group.representative) == key,
            )
            .toList();
        final draft = table.begin(
          _MaterialAggregate(
            key: key,
            paths: [for (final group in scope) ...group.paths],
          ),
          scope: scope,
        );
        draft.productFlow = draft.productFlow || confirmed;
      }
      running = true;
    });
    final remaining = {...keys};
    final completed = <String>{};
    final createdChildren = <String>{};
    try {
      // ADR-120 §2.4「统一依赖编排先父后子，同一层合批；只确认一次」：汇总视图
      // 直接下单在开跑前一次性确认全部所选物料，之后各依赖轮次按身份桥重绑静默
      // 提交（先父后子），失败即停并保留输入与回执。产品视图入口已确认过
      // (confirmed=true)不再重复问；uncertain 续做是已确认意图的原样重试，也不问。
      // 2026-10-07 用户口径：不再逐轮弹确认框。
      if (!confirmed && !table.uncertain) {
        // 先走同一套请求构建校验(总量下限、来源已变、路线未统一等)，无效整单
        // 直接警告、不进确认框——确认框只对真正会下达的整单出现。
        table.requestFor([for (final key in keys) table.drafts[key]!]);
        double total = 0;
        double overTotal = 0;
        var appendKinds = 0;
        for (final key in keys) {
          final draft = table.drafts[key]!;
          final typed = double.tryParse(draft.totalText) ?? 0;
          total += typed;
          final groups = table.draftGroups(draft);
          final floor = groups.fold<double>(
            0,
            (sum, group) =>
                sum + owner._tableGroupResidual(group, authoritative: true),
          );
          if (typed - floor > 0.0001) overTotal += typed - floor;
          if (groups.isNotEmpty && groups.every(owner._tableGroupIssued)) {
            appendKinds++;
          }
        }
        final confirmedOnce = await UtenDialog.show(
          owner.context,
          title: '确认下单 ${keys.length} 种物料？',
          content: Text(
            [
              '共 ${keys.length} 种物料，合计 ${owner._qty(total)}。',
              if (appendKinds > 0) '$appendKinds 种为追加原单，只办理本次净增量。',
              if (overTotal > 0.0001)
                '含超出当前还缺的 ${owner._qty(overTotal)}（作为公共备货下达）。',
            ].join('\n'),
            key: const Key('aggregate-submit-confirm-body'),
          ),
          confirmLabel: '确认下单',
        );
        if (confirmedOnce != true || !owner.mounted) return false;
      }
      final dependencies = _dependencies(keys);
      while (remaining.isNotEmpty) {
        final ready = remaining
            .where(
              (key) => (dependencies[key] ?? const <String>{})
                  .difference(completed)
                  .isEmpty,
            )
            .toSet();
        if (ready.isEmpty) {
          owner.context.appWarning('所选物料之间的层级责任无法确定先后，请刷新并核对来源');
          return false;
        }
        final positive = ready
            .where(
              (key) =>
                  (double.tryParse(table.drafts[key]?.totalText ?? '') ?? 0) >
                      0 ||
                  !table.validText(table.drafts[key]?.totalText ?? ''),
            )
            .toSet();
        final skipped = ready.difference(positive);
        owner._mutateAggregateTable(() {
          for (final key in skipped) {
            _releaseZero(key);
          }
        });
        remaining.removeAll(skipped);
        completed.addAll(skipped);
        if (positive.isEmpty) continue;
        final active = _window(positive);
        final settings = <String, _MaterialAggregateRebindSettings>{
          for (final key in remaining.difference(active))
            if (table.drafts[key] case final draft?) key: _settings(draft),
        };
        // 逐行的车间 / 负责人 / 比例也在本轮前拍下：下层来源被身份桥换到新
        // 共享行后，靠它把各自的做法带过去，分单才不会被默认值抹平。
        final lineParams = <String, _MaterialAggregateMakeParams>{
          for (final key in remaining.difference(active))
            if (table.drafts[key] case final draft?)
              for (final source in table.draftSources(draft))
                source.line: table.makeParams(source.group),
        };
        final sources = [
          for (final key in active) ...table.draftGroups(table.drafts[key]!),
        ];
        final success = await table.submitStage(
          sources,
          skipAutoClaim: skipClaims,
        );
        if (!owner.mounted) return false;
        if (!success) {
          if (completed.isNotEmpty) {
            owner.context.appInfo('前面的物料已下达，其余数量和来源仍保留，可继续核对或重试');
          }
          return false;
        }
        completed.addAll(active);
        remaining.removeAll(active);
        final result = table.lastStageResult!;
        createdChildren.addAll(
          result.materialIdentityBridges.map(
            (bridge) => bridge.toMaterialLineId,
          ),
        );
        owner._mutateAggregateTable(() {
          for (final key in remaining) {
            final draft = table.drafts[key];
            if (draft == null) continue;
            _rebind(
              draft,
              result.materialIdentityBridges,
              includeNew: (dependencies[key] ?? const <String>{})
                  .intersection(active)
                  .isNotEmpty,
              settings: settings[key]!,
              lineParams: lineParams,
            );
          }
        });
      }
      if (createdChildren.isNotEmpty) {
        unawaited(_offerRemainingChildren(createdChildren));
      }
      // 成功一轮整单即重置扣量选择（与产品视图入口同口径），下次提交重新询问。
      owner._setPreparationSupplyUsage(null);
      return true;
    } on FormatException catch (failure) {
      if (owner.mounted) owner.context.appWarning(failure.message);
      return false;
    } finally {
      if (owner.mounted) owner._mutateAggregateTable(() => running = false);
    }
  }

  Map<String, Set<String>> _dependencies(Set<String> keys) {
    final analysis = owner._analysis!;
    final sorted = keys.toList()..sort();
    final scope = sorted.join('|');
    if (_dependencyRevision == table._revision &&
        identical(_dependencyAnalysis, analysis) &&
        _dependencyScope == scope &&
        _dependencyCache != null) {
      return _dependencyCache!;
    }
    final indexes = owner._analysisIndexes(analysis);
    final presentation = owner._bomPresentation(analysis);
    final result = {for (final key in keys) key: <String>{}};
    final sourceKeysByAnchor = <String, Set<String>>{};
    for (final material in analysis.materials) {
      final anchor = material.planAnchorAnalysisLineId;
      final key = owner._aggregateKeyOf(material);
      if (anchor != null && keys.contains(key)) {
        sourceKeysByAnchor.putIfAbsent(anchor, () => {}).add(key);
      }
    }
    for (final key in keys) {
      final draft = table.drafts[key]!;
      for (final line in draft.lineIds) {
        final seen = <String>{};
        var parent = presentation.parentIdsByMaterial[line];
        while (parent != null && seen.add(parent)) {
          final group = indexes.groupsByLine[parent];
          if (group != null) {
            final parentKey = owner._aggregateKeyOf(group.representative);
            if (parentKey != key && keys.contains(parentKey)) {
              result[key]!.add(parentKey);
            }
          }
          parent = presentation.parentIdsByMaterial[parent];
        }
        final root = presentation.rootIdsByMaterial[line];
        for (final parentKey in sourceKeysByAnchor[root] ?? const <String>{}) {
          if (parentKey != key) result[key]!.add(parentKey);
        }
      }
    }
    _dependencyRevision = table._revision;
    _dependencyAnalysis = analysis;
    _dependencyScope = scope;
    _dependencyCache = result;
    return result;
  }

  _MaterialAggregateRebindSettings _settings(_MaterialAggregateDraft draft) {
    final groups = table.draftGroups(draft);
    final workshops = groups.map(owner._tableWorkshopFor).toList();
    final workers = groups.map(owner._tableWorkerFor).toList();
    return _MaterialAggregateRebindSettings(
      workshops.isEmpty
          ? null
          : (id: workshops.first.id, name: workshops.first.name),
      workers.isEmpty ? null : (id: workers.first.id, name: workers.first.name),
      table.uniformRateText(groups),
      workshops.map((value) => value.id).toSet().length > 1,
      workers.map((value) => value.id).toSet().length > 1,
    );
  }

  void _rebind(
    _MaterialAggregateDraft draft,
    List<MaterialAggregateIdentityBridge> bridges, {
    required bool includeNew,
    required _MaterialAggregateRebindSettings settings,
    Map<String, _MaterialAggregateMakeParams> lineParams = const {},
  }) {
    final indexes = owner._analysisIndexes(owner._analysis!);
    final rewrites = <String, Set<String>>{};
    for (final bridge in bridges) {
      for (final old in bridge.fromMaterialLineIds) {
        rewrites.putIfAbsent(old, () => {}).add(bridge.toMaterialLineId);
      }
    }
    final oldSnapshots = Map<String, _MaterialAggregatePathSnapshot>.from(
      draft.paths,
    );
    // 新共享行 ← 本草稿里经精确身份桥换过去的旧来源行。父件分成几张工单时，
    // 各张的下层各有自己的桥，下层来源只跟着自己那座桥走，不按货品猜。
    final bridgedFrom = <String, List<String>>{};
    for (final bridge in bridges) {
      final origins = [
        for (final old in bridge.fromMaterialLineIds)
          if (oldSnapshots.containsKey(old)) old,
      ];
      if (origins.isNotEmpty) {
        bridgedFrom
            .putIfAbsent(bridge.toMaterialLineId, () => [])
            .addAll(origins);
      }
    }
    final nextIds = <String>{};
    for (final old in oldSnapshots.keys) {
      final originalGroup = indexes.groupsByLine[old];
      final original = originalGroup?.representative;
      if (original?.aggregatePreparation?.actionable == true) {
        // 用户原行继续持有输入和来源身份；目标只由服务端在事务内精确解析。
        nextIds.add(old);
        continue;
      }
      if (originalGroup != null &&
          !rewrites.containsKey(old) &&
          table.inactiveSourceContext(originalGroup) &&
          owner._tableGroupResidual(originalGroup, authoritative: true) <=
              0.0001) {
        if (oldSnapshots[old]!.hasExplicitQty) {
          throw FormatException('「${draft.label}」的来源已无需新增备料，手填数量已保留，请重新核对');
        }
        // Full adoption of a parent can remove its automatic child demand.
        // This is a proven zero, not a lost identity bridge or failed order.
        continue;
      }
      if (rewrites[old] case final replacements?) {
        final oldMaterial = indexes.groupsByLine[old]?.representative;
        if (oldMaterial != null && oldMaterial.requiredQty > 0) {
          throw const FormatException('旧来源仍有制造责任，不能按整体替换桥重绑');
        }
        nextIds.addAll(replacements);
      } else {
        final group = indexes.groupsByLine[old];
        if (group == null || table.inactiveSourceContext(group)) {
          throw FormatException('「${draft.label}」来源已变化但缺少精确身份桥，已保留总量，请重新核对');
        }
        nextIds.add(old);
      }
    }
    if (includeNew) {
      for (final bridge in bridges.where(
        (bridge) => bridge.fromMaterialLineIds.isEmpty,
      )) {
        final material =
            indexes.groupsByLine[bridge.toMaterialLineId]?.representative;
        if (material != null && owner._aggregateKeyOf(material) == draft.key) {
          nextIds.add(bridge.toMaterialLineId);
        }
      }
    }
    for (final id in nextIds) {
      final material = indexes.groupsByLine[id]?.representative;
      if (material == null || owner._aggregateKeyOf(material) != draft.key) {
        throw const FormatException('身份桥改变了物料、颜色或单位，未自动套用原数量');
      }
    }
    for (final entry in oldSnapshots.entries) {
      table._draftByLine.remove(entry.key);
      owner._tableUserTypedQty.remove(entry.key);
      owner._selectedMaterialGroupKeys.remove(entry.value.groupKey);
    }
    draft.paths.clear();
    for (final id in nextIds) {
      final group = indexes.groupsByLine[id]!;
      final original = oldSnapshots[id];
      final residual = owner._qty(
        owner._tableDefaultSubmitQty(group, authoritative: true),
      );
      final explicit = original?.hasExplicitQty == true;
      final order = owner._tableOrderQtyController(group),
          append = owner._tableAppendQtyController(group),
          rate = owner._overproductionPercentController(materialLineId: id);
      order.text = explicit ? original!.orderText : residual;
      append.text = explicit ? original!.appendText : residual;
      owner._tableSeededQtyTexts['ORDER|${group.key}'] = explicit
          ? original!.orderSeed ?? residual
          : residual;
      owner._tableSeededQtyTexts['APPEND|${group.key}'] = explicit
          ? original!.appendSeed ?? residual
          : residual;
      if (explicit && original!.typedQty != null) {
        owner._tableUserTypedQty[id] = original.typedQty!;
      }
      draft.paths[id] = explicit
          ? original!
          : _MaterialAggregatePathSnapshot(
              groupKey: group.key,
              orderText: residual,
              appendText: residual,
              orderSeed: residual,
              appendSeed: residual,
              typedQty: null,
              selected: false,
              autoSelected: false,
              deselected: false,
              workshop: owner._tableWorkshopDraft[group.key],
              worker: owner._tableWorkerDraft[group.key],
              rate: rate.text,
              rateExplicit: owner._prefilledOverproductionRates.isExplicit(
                rate,
              ),
            );
      table._draftByLine[id] = draft.key;
      owner._selectedMaterialGroupKeys.add(group.key);
      if (!settings.mixedWorkshop && settings.workshop != null) {
        owner._tableWorkshopDraft[group.key] = settings.workshop!;
      }
      if (!settings.mixedWorker && settings.worker != null) {
        owner._tableWorkerDraft[group.key] = settings.worker!;
      }
      if (settings.rate != null) {
        owner._overproductionPercentController(materialLineId: id).text =
            settings.rate!;
      }
      // 各来源做法不同(会分成几张工单，ADR-120 §8)时，新行继承桥上旧来源行的
      // 车间 / 负责人 / 比例；桥上几条旧行做法不一致就无从继承，留默认值，
      // 汇总行会照实显示分单。
      final carried = {
        for (final old in bridgedFrom[id] ?? const <String>[])
          lineParams[old]?.key,
      };
      final params = carried.length == 1 && carried.single != null
          ? lineParams[bridgedFrom[id]!.first]!
          : null;
      if (params != null) {
        if (params.workshop.id != null) {
          owner._tableWorkshopDraft[group.key] = params.workshop;
        }
        if (params.worker.id != null) {
          owner._tableWorkerDraft[group.key] = params.worker;
        }
        owner._overproductionPercentController(materialLineId: id).text =
            params.rateText;
      }
    }
    final currentSettings = _settings(draft);
    draft.mixedWorkshop = currentSettings.mixedWorkshop;
    draft.mixedWorker = currentSettings.mixedWorker;
    draft.mixedRate = currentSettings.rate == null;
    final sourceQuantities = draft.sourceRequestedQtyByMaterialLineId;
    final lostExplicitSource =
        sourceQuantities?.keys.any(
          (id) =>
              !nextIds.contains(id) && oldSnapshots[id]?.hasExplicitQty == true,
        ) ??
        false;
    if (sourceQuantities != null && !lostExplicitSource) {
      // 父件采用已有供给后，系统预填子件按真正需要新增制造的量重算。
      // 同料另一来源被手工修改，不能把本来源的旧系统默认量一起冻结。
      draft.sourceRequestedQtyByMaterialLineId = {
        for (final id in nextIds)
          id:
              oldSnapshots[id]?.hasExplicitQty == true &&
                  sourceQuantities.containsKey(id)
              ? sourceQuantities[id]!
              : owner._qty(
                  owner._tableDefaultSubmitQty(
                    indexes.groupsByLine[id]!,
                    authoritative: true,
                  ),
                ),
      };
      draft.totalText = owner._qty(
        draft.sourceRequestedQtyByMaterialLineId!.values.fold<double>(
          0,
          (total, value) => total + double.parse(value),
        ),
      );
      table.editors[draft.key]?.text = draft.totalText;
    } else if (!draft.userEntered) {
      draft.totalText = owner._qty(
        nextIds.fold<double>(
          0,
          (sum, id) =>
              sum +
              owner._tableDefaultSubmitQty(
                indexes.groupsByLine[id]!,
                authoritative: true,
              ),
        ),
      );
      table.editors[draft.key]?.text = draft.totalText;
    } else if (lostExplicitSource) {
      // 旧快照只有替换桥时只能证明整组总量，不能伪造已丢失的逐行发出量。
      draft.sourceRequestedQtyByMaterialLineId = null;
    }
    draft.previewGroups = const [];
    table._revision++;
  }

  void _releaseZero(String key) {
    final draft = table.drafts.remove(key);
    if (draft == null) return;
    for (final entry in draft.paths.entries) {
      table._draftByLine.remove(entry.key);
      owner._tableUserTypedQty.remove(entry.key);
      owner._selectedMaterialGroupKeys.remove(entry.value.groupKey);
    }
  }

  Future<void> _offerRemainingChildren(Set<String> ids) async {
    final analysis = owner._analysis;
    if (!owner.mounted || analysis == null || table.hasDrafts) return;
    final indexes = owner._analysisIndexes(analysis);
    final originalIds = {
      for (final material in analysis.materials)
        if (material.aggregatePreparation?.targetMaterialLineIds.any(
              ids.contains,
            ) ==
            true)
          material.materialLineId,
    };
    final groups = [
      for (final id in originalIds.isEmpty ? ids : originalIds)
        if (indexes.groupsByLine[id] case final group?)
          if (table.selectableForOrder(group) &&
              owner._tableGroupResidual(group, authoritative: true) >
                  0.000000001)
            group,
    ];
    if (groups.isEmpty) return;
    final confirm = await UtenDialog.show(
      owner.context,
      title: '下层还有物料待下达',
      content: Text('还有 ${groups.length} 条下层物料需要补充，是否继续核对下单？'),
      confirmLabel: '核对下层物料',
    );
    if (confirm != true ||
        !owner.mounted ||
        owner._analysis?.analysisId != analysis.analysisId) {
      return;
    }
    await owner._submitPreparationGroups(groups, append: false);
  }
}

final class _MaterialAggregateRebindSettings {
  const _MaterialAggregateRebindSettings(
    this.workshop,
    this.worker,
    this.rate,
    this.mixedWorkshop,
    this.mixedWorker,
  );
  final ({String? id, String? name})? workshop, worker;
  final String? rate;
  final bool mixedWorkshop, mixedWorker;
}
