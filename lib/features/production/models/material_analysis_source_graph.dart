import 'production_material_analysis.dart';

/// Exact source-to-preparation links from one authoritative analysis snapshot.
/// Display consumers share this graph; command identities remain the original
/// source UUIDs, and references/allocations are never copied onto their aliases.
final class MaterialAnalysisSourceGraph {
  MaterialAnalysisSourceGraph(Iterable<ProductionMaterialAnalysisMaterial> rows)
    : _byId = {for (final row in rows) row.materialLineId: row};

  final Map<String, ProductionMaterialAnalysisMaterial> _byId;
  final Map<String, MaterialAnalysisSourceResolution> _cache = {};

  MaterialAnalysisSourceResolution resolve(Iterable<String> sourceIds) {
    final materials = <String, ProductionMaterialAnalysisMaterial>{};
    var complete = true;
    for (final id in sourceIds) {
      final source = _cache.putIfAbsent(id, () => _resolve(id));
      complete = complete && source.complete;
      for (final material in source.materials) {
        materials[material.materialLineId] = material;
      }
    }
    return MaterialAnalysisSourceResolution(
      materials.values.toList(growable: false),
      complete: complete,
    );
  }

  MaterialAnalysisSourceResolution _resolve(String sourceId) {
    final result = <String, ProductionMaterialAnalysisMaterial>{};
    final active = <String>{};
    final pending = <({String id, bool exit})>[(id: sourceId, exit: false)];
    var complete = true;
    while (pending.isNotEmpty) {
      final step = pending.removeLast();
      if (step.exit) {
        active.remove(step.id);
        continue;
      }
      if (active.contains(step.id)) {
        complete = false;
        continue;
      }
      if (result.containsKey(step.id)) continue;
      final row = _byId[step.id];
      if (row == null) {
        complete = false;
        continue;
      }
      result[step.id] = row;
      active.add(step.id);
      pending.add((id: step.id, exit: true));
      for (final target
          in row.aggregatePreparation?.targetMaterialLineIds ??
              const <String>[]) {
        // A canonical row may explicitly name itself.
        if (target != step.id) pending.add((id: target, exit: false));
      }
    }
    return MaterialAnalysisSourceResolution(
      result.values.toList(growable: false),
      complete: complete,
    );
  }
}

final class MaterialAnalysisSourceResolution {
  const MaterialAnalysisSourceResolution(
    this.materials, {
    required this.complete,
  });

  final List<ProductionMaterialAnalysisMaterial> materials;
  final bool complete;

  Set<String> get activeActionIds => {
    for (final material in materials)
      for (final target in material.notifiedTargets)
        if (target.actionId?.isNotEmpty == true &&
            (target.status?.toUpperCase() != 'CANCELLED' ||
                target.notificationReversalPending) &&
            !target.isReversedRootOutput)
          target.actionId!,
  };

  Set<String> get pendingReversalActionIds => {
    for (final material in materials)
      for (final target in material.notifiedTargets)
        if (target.actionId?.isNotEmpty == true &&
            target.notificationReversalPending)
          target.actionId!,
  };

  bool get hasIssuedSupply => materials.any(
    (material) =>
        (material.aggregatePreparation?.orderedQty ?? 0) > 0 ||
        (material.aggregatePreparation?.totalOrderedQty ?? 0) > 0 ||
        material.notifiedTargets.any(
          (target) =>
              target.status?.toUpperCase() != 'CANCELLED' &&
              !target.isReversedRootOutput,
        ),
  );
}
