import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/uten_page_prefs_notifier.dart';

class MaterialAnalysisWarehousePrefs {
  const MaterialAnalysisWarehousePrefs({
    this.primaryWarehouseId,
    this.warehouseIds = const [],
  });

  final String? primaryWarehouseId;
  final List<String> warehouseIds;

  MaterialAnalysisWarehousePrefs normalized() {
    final primary = primaryWarehouseId?.trim();
    final unique = <String>{
      if (primary?.isNotEmpty == true) primary!,
      for (final id in warehouseIds)
        if (id.trim().isNotEmpty) id.trim(),
    };
    final values = unique.toList()..sort();
    if (primary?.isNotEmpty == true) {
      values
        ..remove(primary)
        ..insert(0, primary!);
    }
    return MaterialAnalysisWarehousePrefs(
      primaryWarehouseId: primary?.isEmpty == true ? null : primary,
      warehouseIds: List.unmodifiable(values),
    );
  }
}

class MaterialAnalysisWarehousePrefsNotifier
    extends UtenPagePrefsNotifier<MaterialAnalysisWarehousePrefs> {
  @override
  String get prefKey => 'production.materialAnalysis.warehouses';

  @override
  MaterialAnalysisWarehousePrefs get defaultValue =>
      const MaterialAnalysisWarehousePrefs();

  @override
  MaterialAnalysisWarehousePrefs? decode(Object? raw) {
    if (raw is! Map) return null;
    final primary = raw['primaryWarehouseId']?.toString();
    final ids = raw['warehouseIds'];
    return MaterialAnalysisWarehousePrefs(
      primaryWarehouseId: primary,
      warehouseIds: ids is List
          ? ids.map((value) => value.toString()).toList(growable: false)
          : const [],
    ).normalized();
  }

  @override
  Object encode(MaterialAnalysisWarehousePrefs state) {
    final value = state.normalized();
    return {
      'primaryWarehouseId': value.primaryWarehouseId,
      'warehouseIds': value.warehouseIds,
    };
  }
}

final materialAnalysisWarehousePrefsProvider =
    NotifierProvider<
      MaterialAnalysisWarehousePrefsNotifier,
      MaterialAnalysisWarehousePrefs
    >(MaterialAnalysisWarehousePrefsNotifier.new);
