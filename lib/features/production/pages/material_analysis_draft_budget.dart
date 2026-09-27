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
      pools.update(
        pool,
        (current) => current < shared ? current : shared,
        ifAbsent: () => shared,
      );
      final previewed = owner._tablePreviewed(material);
      final estimated = owner._tableShownQty(material);
      final baseline = owner._tablePreviewedQty(material);
      final need =
          (previewed.preparationUncoveredBeforeSharedQty ?? beforeShared) +
          estimated.required -
          baseline.required;
      final aggregate = owner._aggregateTable;
      final draft =
          aggregate.drafts[aggregate._draftByLine[material.materialLineId]];
      final sourceAmount =
          draft?.sourceRequestedQtyByMaterialLineId?[material.materialLineId];
      final requested = draft == null
          ? owner._tableSubmitQtyOf(group)
          : double.tryParse(sourceAmount ?? draft.totalText) ?? double.nan;
      inputs.add(
        MaterialPreparationBudgetLine(
          materialLineId: material.materialLineId,
          poolKey: pool,
          ownedAvailableQty: owned,
          uncoveredBeforeSharedQty: need.clamp(0.0, double.infinity),
          requestedQty: requested,
          selected: owner._selectedMaterialGroupKeys.contains(group.key),
          inputKey: draft != null && sourceAmount == null
              ? 'AGGREGATE|${draft.key}'
              : group.key,
          priority: priorities[material.analysisLineId] ?? 0,
          adoptableSharedQty: material.preparationAdoptableSharedQty,
          supplySlices: material.preparationSharedSupplySlices,
        ),
      );
    }
    return _value = MaterialPreparationDraftBudget.project(
      lines: inputs,
      sharedAvailableByPool: pools,
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
