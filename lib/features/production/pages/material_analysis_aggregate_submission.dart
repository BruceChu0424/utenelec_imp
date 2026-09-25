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
    for (final key in keys) {
      final draft = table.drafts[key]!;
      if (draft.lineIds.isEmpty ||
          draft.lineIds.length > materialAggregateMaxSources) {
        throw FormatException(
          '「${draft.label}」来源范围为 ${draft.lineIds.length} 条，单物料必须为 1 至 $materialAggregateMaxSources 条；请核对分析范围，系统不会拆成多单',
        );
      }
      sources[key] = draft.lineIds.length;
    }
    return materialAggregateRequestWindow(sources).toSet();
  }

  double? pendingParentRequirement(_MaterialAggregateDraft draft) {
    final parents =
        _dependencies(table.drafts.keys.toSet())[draft.key] ?? const <String>{};
    if (parents.isEmpty) return null;
    final source = table.draftGroups(draft).firstOrNull?.representative;
    if (source == null) return null;
    var known = false, quantity = 0.0;
    for (final parent in parents) {
      for (final batch
          in table.drafts[parent]?.previewGroups ??
              const <MaterialAggregateOrderGroupPreview>[]) {
        for (final child in batch.sharedBomChildren) {
          if (child.goodsId == source.goodsId &&
              child.colorId == source.colorId &&
              child.unitId == source.unitId) {
            known = true;
            quantity += child.requiredQty;
          }
        }
      }
    }
    return known ? quantity : null;
  }

  Future<bool> submit(List<_MaterialGroup> selected) async {
    if (running || table.saving || selected.isEmpty) return false;
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
        table.begin(
          _MaterialAggregate(
            key: key,
            paths: [for (final group in scope) ...group.paths],
          ),
          scope: scope,
        );
      }
      running = true;
    });
    final remaining = {...keys};
    final completed = <String>{};
    final createdChildren = <String>{};
    try {
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
        final sources = [
          for (final key in active) ...table.draftGroups(table.drafts[key]!),
        ];
        final success = await table.submitStage(sources);
        if (!owner.mounted) return false;
        if (!success) {
          if (completed.isNotEmpty) {
            owner.context.appInfo('前面的汇总批次已下达，其余总量和来源仍保留，可继续核对或重试');
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
            );
          }
        });
      }
      if (createdChildren.isNotEmpty) {
        unawaited(_offerRemainingChildren(createdChildren));
      }
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
    final rates = groups
        .map(
          (group) => owner
              ._overproductionPercentController(
                materialLineId: group.representative.materialLineId,
              )
              .text,
        )
        .toSet();
    return _MaterialAggregateRebindSettings(
      workshops.isEmpty
          ? null
          : (id: workshops.first.id, name: workshops.first.name),
      workers.isEmpty ? null : (id: workers.first.id, name: workers.first.name),
      rates.length == 1 ? rates.single : null,
      workshops.map((value) => value.id).toSet().length > 1,
      workers.map((value) => value.id).toSet().length > 1,
    );
  }

  void _rebind(
    _MaterialAggregateDraft draft,
    List<MaterialAggregateIdentityBridge> bridges, {
    required bool includeNew,
    required _MaterialAggregateRebindSettings settings,
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
    final nextIds = <String>{};
    for (final old in oldSnapshots.keys) {
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
      final original = !rewrites.containsKey(id) ? oldSnapshots[id] : null;
      final residual = owner._qty(
        owner._tableGroupResidual(group, authoritative: true),
      );
      final order = owner._tableOrderQtyController(group),
          append = owner._tableAppendQtyController(group);
      order.text = residual;
      append.text = residual;
      owner._tableSeededQtyTexts['ORDER|${group.key}'] = residual;
      owner._tableSeededQtyTexts['APPEND|${group.key}'] = residual;
      draft.paths[id] = original?.typedQty != null
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
              rate: owner
                  ._overproductionPercentController(materialLineId: id)
                  .text,
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
    }
    draft.mixedWorkshop = settings.mixedWorkshop;
    draft.mixedWorker = settings.mixedWorker;
    draft.mixedRate = settings.rate == null;
    if (!draft.userEntered) {
      draft.totalText = owner._qty(
        nextIds.fold<double>(
          0,
          (sum, id) =>
              sum +
              owner._tableGroupResidual(
                indexes.groupsByLine[id]!,
                authoritative: true,
              ),
        ),
      );
      table.editors[draft.key]?.text = draft.totalText;
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
    final groups = [
      for (final id in ids)
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
      content: Text('已生成的汇总生产批次仍有 ${groups.length} 条实际用料责任待办理，是否在汇总表选中继续？'),
      confirmLabel: '选中下层物料',
    );
    if (confirm != true ||
        !owner.mounted ||
        owner._analysis?.analysisId != analysis.analysisId) {
      return;
    }
    owner._mutateAggregateTable(() {
      owner._bomAggregateByMaterial = true;
      for (final group in groups) {
        owner._selectedMaterialGroupKeys.add(group.key);
      }
    });
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
