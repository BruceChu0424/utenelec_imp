import '../../../shared/formatters/exact_decimal.dart';
import 'production_exact_quantity.dart';
import 'production_material_analysis.dart';

/// Read-only original facts. Legacy large JSON numbers cannot prove their text.
String? materialPresentationFact(
  Map<String, String> exact,
  String key,
  num? legacy, {
  int scale = 4,
}) => productionExactQuantityText(exact[key] ?? legacy, scale: scale);

String? materialPresentationSum(Iterable<String?> values) {
  var total = BigInt.zero;
  for (final text in values) {
    final value = financeExactDecimalUnits(text);
    if (value == null || value.isNegative) return null;
    total += value;
  }
  return financeExactTrimmed(financeExactDecimalFromUnits(total));
}

/// Physical order facts, counted once per action, separate from source demand
/// and from stock that has actually arrived. Transfers/claims do not place orders.
class MaterialIssuedQuantitySummary {
  MaterialIssuedQuantitySummary(
    Iterable<MaterialAnalysisSupplyAction> candidates,
  ) {
    final actions = <String, MaterialAnalysisSupplyAction>{};
    final cancelled = <String>{};
    var conflicting = false;
    for (final action in candidates) {
      if (const {
        'CANCELLED',
        'WITHDRAWN',
        'REVERSED',
      }.contains(action.status)) {
        cancelled.add(action.actionId);
        actions.remove(action.actionId);
        continue;
      }
      if (action.actionId.isEmpty ||
          cancelled.contains(action.actionId) ||
          const {
            'FUTURE_TRANSFER',
            'SHARED_FUTURE_CLAIM',
            'ROOT_OUTPUT',
            'AGGREGATE_CONTINUATION',
          }.contains(action.operationType)) {
        continue;
      }
      final previous = actions[action.actionId];
      if (previous != null) {
        for (final field in [
          'requestedQty',
          'publicSurplusQty',
          'safetyReplenishmentQty',
        ]) {
          num value(MaterialAnalysisSupplyAction item) => switch (field) {
            'requestedQty' => item.requestedQty,
            'publicSurplusQty' => item.publicSurplusQty,
            _ => item.safetyReplenishmentQty,
          };
          if (materialPresentationFact(
                previous.quantityFactsExact,
                field,
                value(previous),
              ) !=
              materialPresentationFact(
                action.quantityFactsExact,
                field,
                value(action),
              )) {
            conflicting = true;
          }
        }
      }
      actions[action.actionId] = action;
    }
    actionIds = Set.unmodifiable(actions.keys);
    demand = materialPresentationSum(
      actions.values.map(
        (action) => materialPresentationFact(
          action.quantityFactsExact,
          'requestedQty',
          action.requestedQty,
        ),
      ),
    );
    public = materialPresentationSum(
      actions.values.map(
        (action) => materialPresentationFact(
          action.quantityFactsExact,
          'publicSurplusQty',
          action.publicSurplusQty,
        ),
      ),
    );
    safety = materialPresentationSum(
      actions.values.map(
        (action) => materialPresentationFact(
          action.quantityFactsExact,
          'safetyReplenishmentQty',
          action.safetyReplenishmentQty,
        ),
      ),
    );
    total = conflicting
        ? null
        : materialPresentationSum([demand, public, safety]);
  }

  late final Set<String> actionIds;
  late final String? demand, public, safety, total;
  bool get known => actionIds.isNotEmpty && total != null;
}

/// Resolve the physical demand represented by visible original paths. A
/// retained positive original and all current targets participate, each once.
/// The demand-supply gap is qualified-stock evidence, never planning/net gap.
class MaterialQualifiedCoverage {
  MaterialQualifiedCoverage(
    Iterable<ProductionMaterialAnalysisMaterial> sources,
    Map<String, ProductionMaterialAnalysisMaterial> materials,
  ) {
    final sourceRows = sources.toList(growable: false);
    final visited = <String>{};
    final selected = <String, ProductionMaterialAnalysisMaterial>{};
    var complete = true;
    void visit(ProductionMaterialAnalysisMaterial row, {bool target = false}) {
      if (!visited.add(row.materialLineId)) return;
      if (target &&
          const {
            MaterialRequirementState.inactive,
            MaterialRequirementState.inactiveReference,
            MaterialRequirementState.inactiveParentCovered,
            MaterialRequirementState.inactiveParentRoute,
          }.contains(row.requirementState)) {
        return;
      }
      final need = materialPresentationFact(
        row.quantityFactsExact,
        'requiredQty',
        row.requiredQty,
      );
      final units = financeExactDecimalUnits(need);
      if (units == null) complete = false;
      final targets =
          row.aggregatePreparation?.targetMaterialLineIds ?? const <String>[];
      if (units != null && units > BigInt.zero) {
        selected[row.materialLineId] = row;
      }
      for (final id in targets) {
        final next = materials[id];
        if (next == null) {
          complete = false;
          continue;
        }
        visit(next, target: true);
      }
      if (!target &&
          targets.isEmpty &&
          (row.aggregatePreparation?.requiredQty ?? 0) > 0 &&
          (units ?? BigInt.zero) == BigInt.zero) {
        complete = false;
      }
    }

    for (final row in sourceRows) {
      visit(row);
    }
    if (selected.isEmpty &&
        sourceRows.any(
          (row) =>
              (financeExactDecimalUnits(
                    materialPresentationFact(
                      row.quantityFactsExact,
                      'sourceRequiredQty',
                      row.sourceRequiredQty,
                    ),
                  ) ??
                  BigInt.zero) >
              BigInt.zero,
        )) {
      complete = false;
    }
    materialLineIds = Set.unmodifiable(selected.keys);
    var required = BigInt.zero, covered = BigInt.zero;
    for (final row in selected.values) {
      final need = financeExactDecimalUnits(
        materialPresentationFact(
          row.quantityFactsExact,
          'requiredQty',
          row.requiredQty,
        ),
      );
      final gap = financeExactDecimalUnits(
        materialPresentationFact(
          row.quantityFactsExact,
          'demandSupplyGapQty',
          row.demandSupplyGapQty,
        ),
      );
      if (need == null || gap == null) {
        complete = false;
        continue;
      }
      required += need;
      covered += need - (gap > need ? need : gap);
    }
    requiredText = complete
        ? financeExactTrimmed(financeExactDecimalFromUnits(required))
        : null;
    coveredText = complete
        ? financeExactTrimmed(financeExactDecimalFromUnits(covered))
        : null;
    gapText = complete
        ? financeExactTrimmed(financeExactDecimalFromUnits(required - covered))
        : null;
    ratio = complete && required > BigInt.zero
        ? covered.toDouble() / required.toDouble()
        : 0;
  }

  late final String? requiredText, coveredText, gapText;
  late final double ratio;
  late final Set<String> materialLineIds;
}
