part of 'production_material_analysis_page.dart';

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
      final aggregate = owner._aggregateTable;
      final draft =
          aggregate.drafts[aggregate._draftByLine[material.materialLineId]];
      final sourceAmount =
          draft?.sourceRequestedQtyByMaterialLineId?[material.materialLineId];
      final requestedText = draft == null
          ? owner._tableSubmitQtyTextOf(group)
          : sourceAmount ?? draft.totalText;
      final requested = double.tryParse(requestedText) ?? double.nan;
      inputs.add(
        MaterialPreparationBudgetLine(
          materialLineId: material.materialLineId,
          poolKey: pool,
          ownedAvailableQty: owned,
          uncoveredBeforeSharedQty: double.parse(needText),
          requestedQty: requested,
          useAvailableQty: owner._preparationUseAvailableQty != false,
          selected: owner._selectedMaterialGroupKeys.contains(group.key),
          inputKey: draft != null && sourceAmount == null
              ? 'AGGREGATE|${draft.key}'
              : group.key,
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
