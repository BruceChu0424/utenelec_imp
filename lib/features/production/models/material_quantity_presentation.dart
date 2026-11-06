import '../../../shared/formatters/exact_decimal.dart';
import 'production_exact_quantity.dart';
import 'production_material_analysis.dart';

// Read-only arithmetic also retains complete products of two 24-place facts.
BigInt? _presentationUnits(String? text) =>
    financeExactDecimalUnits(text, scale: 48);
String _presentationText(BigInt units) =>
    financeExactDecimalFromUnits(units, scale: 48);

/// Read-only original facts. Legacy large JSON numbers cannot prove their text.
String? materialPresentationFact(
  Map<String, String> exact,
  String key,
  num? legacy, {
  int scale = productionQuantityScale,
}) => productionExactQuantityText(exact[key] ?? legacy, scale: scale);

String? materialPresentationSum(Iterable<String?> values) {
  var total = BigInt.zero;
  for (final text in values) {
    final value = _presentationUnits(text);
    if (value == null || value.isNegative) return null;
    total += value;
  }
  return financeExactTrimmed(_presentationText(total));
}

/// The complete adoptable supply shown in the preparation table. This uses
/// authoritative supply identities only; selection and draft reservations do
/// not reduce it. Private supply belongs to one line, public supply to one pool.
String? materialPreparationAvailableTotalText(
  Iterable<ProductionMaterialAnalysisMaterial> candidates,
) {
  final rows = candidates.toList(growable: false);
  if (rows.isEmpty) return null;
  final ownedByLine = <String, (String, BigInt)>{};
  final pools = <String, _PreparationAvailablePool>{};
  final formatsByDimension = <String, bool>{};
  for (final row in rows) {
    final dimension =
        '${row.goodsId ?? row.goodsCode ?? row.materialKey ?? row.materialLineId}|'
        '${row.colorId ?? row.colorName ?? ''}|${row.unitId ?? row.unitName ?? ''}';
    final modern =
        row.preparationPoolKey != null ||
        row.preparationOwnedAvailableQty != null ||
        row.preparationSharedAvailableQty != null;
    final previousFormat = formatsByDimension[dimension];
    // A legacy combined total cannot prove how much overlaps a modern private
    // and public breakdown of the same material.
    if (previousFormat != null && previousFormat != modern) return null;
    formatsByDimension[dimension] = modern;
    final poolKey = row.preparationPoolKey ?? 'legacy:$dimension';
    final pool = pools.putIfAbsent(poolKey, _PreparationAvailablePool.new);
    if (!modern) {
      final total = row.preparationAvailableQty != null
          ? materialPresentationFact(
              row.quantityFactsExact,
              'preparationAvailableQty',
              row.preparationAvailableQty,
            )
          : materialPresentationSum([
              materialPresentationFact(
                row.quantityFactsExact,
                'mainWarehousePublicAvailableQty',
                row.mainWarehousePublicAvailableQty,
              ),
              materialPresentationFact(
                row.quantityFactsExact,
                'sharedFutureClaimableQty',
                row.sharedFutureClaimableQty,
              ),
            ]);
      final quantity = _presentationUnits(total);
      if (quantity == null || quantity.isNegative) return null;
      pool.legacyTotal =
          pool.legacyTotal == null || quantity < pool.legacyTotal!
          ? quantity
          : pool.legacyTotal;
      continue;
    }
    if (row.preparationPoolKey == null ||
        row.preparationPoolKey!.isEmpty ||
        row.preparationOwnedAvailableQty == null ||
        row.preparationSharedAvailableQty == null) {
      return null;
    }
    final owned = _presentationUnits(
      materialPresentationFact(
        row.quantityFactsExact,
        'preparationOwnedAvailableQty',
        row.preparationOwnedAvailableQty,
      ),
    );
    final shared = _presentationUnits(
      materialPresentationFact(
        row.quantityFactsExact,
        'preparationSharedAvailableQty',
        row.preparationSharedAvailableQty,
      ),
    );
    if (owned == null ||
        shared == null ||
        owned.isNegative ||
        shared.isNegative) {
      return null;
    }
    final oldOwned = ownedByLine[row.materialLineId];
    if (oldOwned != null && oldOwned != (poolKey, owned)) return null;
    ownedByLine[row.materialLineId] = (poolKey, owned);
    pool.shared = pool.shared == null || shared < pool.shared!
        ? shared
        : pool.shared;
    final cap = row.preparationAdoptableSharedQty == null
        ? null
        : _presentationUnits(
            materialPresentationFact(
              row.quantityFactsExact,
              'preparationAdoptableSharedQty',
              row.preparationAdoptableSharedQty,
            ),
          );
    if (row.preparationAdoptableSharedQty != null &&
        (cap == null || cap.isNegative)) {
      return null;
    }
    final slices = row.preparationSharedSupplySlices;
    if (slices == null) {
      // Without identities, caps may overlap completely. The largest proven
      // cap is safe for their union; adding per-row caps would invent supply.
      final compatible = cap ?? shared;
      if (compatible > pool.unidentifiedCap) pool.unidentifiedCap = compatible;
      continue;
    }
    var rowEligible = BigInt.zero;
    final rowKeys = <String>{};
    for (final slice in slices) {
      final quantity = _presentationUnits(slice.availableQtyText);
      if (slice.key.isEmpty || quantity == null || quantity.isNegative) {
        return null;
      }
      final old = pool.sliceQuantities[slice.key];
      pool.sliceQuantities[slice.key] = old == null || quantity < old
          ? quantity
          : old;
      if (slice.adoptable) {
        pool.eligibleKeys.add(slice.key);
        if (rowKeys.add(slice.key)) rowEligible += quantity;
      }
    }
    if (cap != null && rowEligible > cap) return null;
  }
  var total = ownedByLine.values.fold<BigInt>(
    BigInt.zero,
    (sum, value) => sum + value.$2,
  );
  for (final pool in pools.values) {
    if (pool.legacyTotal != null) {
      total += pool.legacyTotal!;
      continue;
    }
    final identified = pool.eligibleKeys.fold<BigInt>(
      BigInt.zero,
      (sum, key) => sum + pool.sliceQuantities[key]!,
    );
    final available = identified > pool.unidentifiedCap
        ? identified
        : pool.unidentifiedCap;
    total += available < pool.shared! ? available : pool.shared!;
  }
  return financeExactTrimmed(_presentationText(total));
}

final class _PreparationAvailablePool {
  BigInt? shared, legacyTotal;
  BigInt unidentifiedCap = BigInt.zero;
  final sliceQuantities = <String, BigInt>{};
  final eligibleKeys = <String>{};
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
    // 合并身份（2026-10-09 用户口径「合并下单的显示要合并」）：参与合计的
    // 真实单据号去重保序，供已下单格悬浮指认「N 行合并 → 哪张单」。
    documents = List.unmodifiable(
      actions.values
          .map((action) => action.documentNo)
          .whereType<String>()
          .where((value) => value.isNotEmpty)
          .toSet(),
    );
  }

  late final Set<String> actionIds;
  late final String? demand, public, safety, total;
  late final List<String> documents;
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
      final units = _presentationUnits(need);
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
              (_presentationUnits(
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
      final need = _presentationUnits(
        materialPresentationFact(
          row.quantityFactsExact,
          'requiredQty',
          row.requiredQty,
        ),
      );
      final gap = _presentationUnits(
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
        ? financeExactTrimmed(_presentationText(required))
        : null;
    coveredText = complete
        ? financeExactTrimmed(_presentationText(covered))
        : null;
    gapText = complete
        ? financeExactTrimmed(_presentationText(required - covered))
        : null;
    ratio = complete && required > BigInt.zero
        ? covered.toDouble() / required.toDouble()
        : 0;
  }

  late final String? requiredText, coveredText, gapText;
  late final double ratio;
  late final Set<String> materialLineIds;
}
