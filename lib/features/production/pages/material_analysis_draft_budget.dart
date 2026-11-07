part of 'production_material_analysis_page.dart';

typedef _PreparationBudgetInput = ({
  String key,
  String requested,
  List<_MaterialGroup> groups,
  bool coverageTotal,
  MaterialPreparationOrderMethod method,
});

/// The editing budget is derived once for the whole analysis, never once per
/// visible page. Actual orders, reservations and claims remain server facts.
final class _MaterialPreparationDraftBudgetController {
  _MaterialPreparationDraftBudgetController(this.owner);
  final _MaterialAnalysisMaterialTableState owner;
  ProductionMaterialAnalysisView? _analysis;
  ProductionMaterialAnalysisView? _preview;
  int _revision = 0, _cachedRevision = -1;
  MaterialPreparationDraftBudget _value = const MaterialPreparationDraftBudget(
    rows: {},
  );
  final Map<String, MaterialPreparationBudgetRow> _summaries = {};

  void invalidate() {
    _revision++;
    _summaries.clear();
  }

  MaterialPreparationDraftBudget get value {
    final analysis = owner._analysis;
    final preview = owner._tableCascadePreview;
    if (identical(analysis, _analysis) &&
        identical(preview, _preview) &&
        _revision == _cachedRevision) {
      return _value;
    }
    _analysis = analysis;
    _preview = preview;
    _cachedRevision = _revision;
    _summaries.clear();
    if (analysis == null) {
      return _value = const MaterialPreparationDraftBudget(rows: {});
    }
    final indexes = owner._analysisIndexes(analysis);
    final presentation = owner._bomPresentation(analysis);
    final representedTargets = {
      for (final material in analysis.materials)
        ...?material.aggregatePreparation?.targetMaterialLineIds,
    };
    final priorities = {
      for (var index = 0; index < analysis.products.length; index++)
        analysis.products[index].analysisLineId:
            analysis.products[index].allocationPriority ?? index,
    };
    final pools = <String, double>{};
    final poolExact = <String, String>{};
    final inputs = <MaterialPreparationBudgetLine>[];
    final aggregateInputs = <String, Map<String, _PreparationBudgetInput>>{};
    final adjustedRequests = <String, String>{};
    _PreparationBudgetInput inputOf(_MaterialGroup group) {
      final aggregate = owner._aggregateTable;
      final draft = aggregate
          .drafts[aggregate._draftByLine[group.representative.materialLineId]];
      if (draft == null) {
        return (
          key: group.key,
          requested: owner._tableSubmitQtyTextOf(group),
          groups: [group],
          coverageTotal: !owner._tableGroupIssued(group),
          method: owner._preparationOrderMethod(group),
        );
      }
      final byGroup = aggregateInputs.putIfAbsent(draft.key, () {
        final parts = aggregate.draftParts(draft);
        final quantities = aggregate.partQuantities(draft, parts);
        return {
          for (var index = 0; index < parts.length; index++)
            for (final source in parts[index].groups)
              source.key: (
                key: quantities[index].sourceRequested == null
                    ? 'AGGREGATE|${parts[index].clientGroupKey}'
                    : source.key,
                requested:
                    quantities[index].sourceRequested?[source
                        .representative
                        .materialLineId] ??
                    quantities[index].qty,
                groups: quantities[index].sourceRequested == null
                    ? parts[index].groups
                    : [source],
                coverageTotal: parts[index].coverageTotal,
                method: parts[index].orderMethod,
              ),
        };
      });
      final input = byGroup[group.key];
      if (input == null) throw const FormatException('备料草稿来源无法对应，请重新读取来源');
      return input;
    }

    String adjustedRequested(_PreparationBudgetInput input) =>
        adjustedRequests.putIfAbsent(input.key, () {
          var covered = BigInt.zero;
          var uncovered = BigInt.zero;
          final seen = <String>{};
          for (final group in input.groups) {
            for (final path in group.paths) {
              if (!seen.add(path.materialLineId)) continue;
              final current = owner._tablePreviewed(path);
              final need = materialPresentationFact(
                current.quantityFactsExact,
                'preparationUncoveredBeforeSharedQty',
                current.preparationUncoveredBeforeSharedQty ??
                    path.preparationUncoveredBeforeSharedQty,
              );
              final required = materialPresentationFact(
                current.quantityFactsExact,
                'requiredQty',
                current.requiredQty,
              );
              if (need == null || required == null) {
                throw const FormatException('备料数量缺少完整原值，请重新读取来源；原输入已保留');
              }
              final needUnits = materialQuantityUnits(need);
              uncovered += needUnits;
              if (input.coverageTotal && input.method.usesAvailableQty) {
                final alreadyCovered =
                    materialQuantityUnits(required) - needUnits;
                if (alreadyCovered > BigInt.zero) covered += alreadyCovered;
              }
            }
          }
          var requested = materialQuantityUnits(input.requested) - covered;
          if (requested < BigInt.zero) requested = BigInt.zero;
          if (input.method == MaterialPreparationOrderMethod.availableOnly &&
              requested > uncovered) {
            requested = uncovered;
          }
          return materialQuantityText(requested);
        });
    for (final material in analysis.materials) {
      if (!presentation.rootIdsByMaterial.containsKey(
        material.materialLineId,
      )) {
        continue;
      }
      if (representedTargets.contains(material.materialLineId) &&
          indexes.productsById[material.analysisLineId]?.sourceType ==
              'AGGREGATE_MAKE') {
        continue;
      }
      final pool = material.preparationPoolKey;
      final shared = material.preparationSharedAvailableQty;
      final owned = material.preparationOwnedAvailableQty;
      final beforeShared = material.preparationUncoveredBeforeSharedQty;
      if (pool == null ||
          pool.isEmpty ||
          shared == null ||
          owned == null ||
          beforeShared == null) {
        continue;
      }
      final group = indexes.groupsByLine[material.materialLineId];
      if (group == null) continue;
      // A pool must have one server-proven free balance. A smaller conflicting
      // observation is conservative; private per-row amounts are never maxed
      // together and relabelled as shared stock.
      final sharedText = materialPresentationFact(
        material.quantityFactsExact,
        'preparationSharedAvailableQty',
        shared,
      );
      if (sharedText == null) {
        return _value = const MaterialPreparationDraftBudget(
          rows: {},
          pendingReason: '共同可用余量缺少完整原值，请重新读取来源',
        );
      }
      final previous = poolExact[pool];
      final selected =
          previous == null ||
              materialQuantityUnits(sharedText) <
                  materialQuantityUnits(previous)
          ? sharedText
          : previous;
      poolExact[pool] = selected;
      pools[pool] = double.parse(selected);
      final previewed = owner._tablePreviewed(material);
      final estimated = owner._tableShownQty(material);
      final baseline = owner._tablePreviewedQty(material);
      // Local double cascades cannot publish rounded capacities. A server
      // preview with equal requirement restores the exact source budget.
      if (estimated.required != baseline.required) {
        return _value = const MaterialPreparationDraftBudget(
          rows: {},
          pendingReason: '当前用量正在核对服务端预览，原输入已保留',
        );
      }
      final ownedText = materialPresentationFact(
        material.quantityFactsExact,
        'preparationOwnedAvailableQty',
        owned,
      );
      final needText = materialPresentationFact(
        previewed.quantityFactsExact,
        'preparationUncoveredBeforeSharedQty',
        previewed.preparationUncoveredBeforeSharedQty ?? beforeShared,
      );
      final capText = materialPresentationFact(
        material.quantityFactsExact,
        'preparationAdoptableSharedQty',
        material.preparationAdoptableSharedQty,
      );
      if (ownedText == null ||
          needText == null ||
          material.preparationAdoptableSharedQty != null && capText == null) {
        return _value = const MaterialPreparationDraftBudget(
          rows: {},
          pendingReason: '备料数量缺少完整原值，请重新读取来源；原输入已保留',
        );
      }
      final isSelected = owner._selectedMaterialGroupKeys.contains(group.key);
      final _PreparationBudgetInput? input;
      final String requestedText;
      try {
        input = isSelected ? inputOf(group) : null;
        // Unselected draft text cannot reserve shared supply. Keep its row in
        // the budget for the authoritative pool and shortage facts.
        requestedText = input == null ? '0' : adjustedRequested(input);
      } on FormatException catch (failure) {
        return _value = MaterialPreparationDraftBudget(
          rows: const {},
          pendingReason: failure.message,
        );
      }
      final requested = double.tryParse(requestedText) ?? double.nan;
      inputs.add(
        MaterialPreparationBudgetLine(
          materialLineId: material.materialLineId,
          poolKey: pool,
          ownedAvailableQty: owned,
          uncoveredBeforeSharedQty: double.parse(needText),
          requestedQty: requested,
          useAvailableQty: input?.method.usesAvailableQty ?? false,
          selected: isSelected,
          inputKey: input?.key,
          priority: priorities[material.analysisLineId] ?? 0,
          adoptableSharedQty: material.preparationAdoptableSharedQty,
          supplySlices: material.preparationSharedSupplySlices,
          quantityFactsExact: {
            'ownedAvailableQty': ownedText,
            'uncoveredBeforeSharedQty': needText,
            'requestedQty': requestedText,
            'adoptableSharedQty': ?capText,
          },
        ),
      );
    }
    return _value = MaterialPreparationDraftBudget.project(
      lines: inputs,
      sharedAvailableByPool: pools,
      sharedAvailableExactByPool: poolExact,
    );
  }

  MaterialPreparationBudgetRow? row(String materialLineId) =>
      value.rows[materialLineId];

  MaterialPreparationBudgetRow? summarize(Iterable<String> materialLineIds) {
    final ids = materialLineIds.toSet();
    final budget = value;
    if (ids.isEmpty || !ids.every(budget.rows.containsKey)) return null;
    if (ids.length == 1) return budget.rows[ids.single];
    final key = (ids.toList()..sort()).join('\u0000');
    return _summaries.putIfAbsent(key, () => budget.summarize(ids));
  }
}
