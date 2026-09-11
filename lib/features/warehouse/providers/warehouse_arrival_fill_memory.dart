// 到货登记「上次落仓 / 上次库位」记忆（账号级，跨设备经 user_preferences 同步）。
//
// 用户 2026-09-11：批量登记实际到货页「多选后在任意一行选入库仓库，就把所有选中行
// 都填上；而且要有记忆，记住这次选的，下次自动填」。
//
// 优先级（自上而下，先命中先用）：
//   1. 行内已有值           —— 用户自己填的，任何预填都不许覆盖；
//   2. 来源建议仓           —— 这张订货单在分析/预定时就定好的落点，比「上次」更准；
//   3. 本记忆               —— 上次在本页落的仓 / 写的库位，作兜底预填。
// 预填一律打「自动带入」黄标（warehouseAutofilled / UtenAutofillTextController），
// 提示用户核对；用户一动就清标。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/uten_page_prefs_notifier.dart';

/// 上次落仓与库位。两项各自独立记忆（有人固定仓不同库位，有人反过来）。
class WarehouseArrivalFillMemory {
  const WarehouseArrivalFillMemory({this.warehouseId, this.stockPlace});

  final String? warehouseId;
  final String? stockPlace;

  static const WarehouseArrivalFillMemory empty = WarehouseArrivalFillMemory();

  WarehouseArrivalFillMemory copyWith({
    String? warehouseId,
    String? stockPlace,
  }) => WarehouseArrivalFillMemory(
    warehouseId: warehouseId ?? this.warehouseId,
    stockPlace: stockPlace ?? this.stockPlace,
  );
}

class WarehouseArrivalFillMemoryNotifier
    extends UtenPagePrefsNotifier<WarehouseArrivalFillMemory> {
  @override
  String get prefKey => 'warehouse.arrivalFill';

  @override
  WarehouseArrivalFillMemory get defaultValue =>
      WarehouseArrivalFillMemory.empty;

  @override
  WarehouseArrivalFillMemory? decode(Object? raw) {
    if (raw is! Map) return null;
    String? read(String key) {
      final value = raw[key];
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return WarehouseArrivalFillMemory(
      warehouseId: read('warehouseId'),
      stockPlace: read('stockPlace'),
    );
  }

  @override
  Object? encode(WarehouseArrivalFillMemory state) => {
    if (state.warehouseId != null) 'warehouseId': state.warehouseId,
    if (state.stockPlace != null) 'stockPlace': state.stockPlace,
  };

  /// 记住本次所落的仓（用户显式选择才调用；预填回写不算）。
  void rememberWarehouse(String? warehouseId) {
    final id = warehouseId?.trim();
    if (id == null || id.isEmpty || id == state.warehouseId) return;
    state = state.copyWith(warehouseId: id);
    persist();
  }

  /// 记住本次所写的库位号；清空库位不记（空值不是一个「选择」）。
  void rememberStockPlace(String? place) {
    final value = place?.trim();
    if (value == null || value.isEmpty || value == state.stockPlace) return;
    state = state.copyWith(stockPlace: value);
    persist();
  }
}

final warehouseArrivalFillMemoryProvider =
    NotifierProvider<
      WarehouseArrivalFillMemoryNotifier,
      WarehouseArrivalFillMemory
    >(WarehouseArrivalFillMemoryNotifier.new);
