// 到货登记的个人选仓上下文；库位由仓库×货品×颜色主档关系决定。
//
// 用户 2026-09-11：批量登记实际到货页「多选后在任意一行选入库仓库，就把所有选中行
// 都填上；而且要有记忆，记住这次选的，下次自动填」。
//
// 优先级（自上而下，先命中先用）：
//   1. 行内已有值           —— 用户自己填的，任何预填都不许覆盖；
//   2. 来源建议仓           —— 这张订货单在分析/预定时就定好的落点，比「上次」更准；
//   3. 本记忆               —— 上次在本页显式选择的仓，作个人上下文兜底。
// 预填一律打「自动带入」黄标（warehouseAutofilled / UtenAutofillTextController），
// 提示用户核对；用户一动就清标。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/uten_page_prefs_notifier.dart';

/// 只记个人上次选仓；旧 JSON 中的 stockPlace 忽略，不跨货品/颜色复用。
class WarehouseArrivalFillMemory {
  const WarehouseArrivalFillMemory({this.warehouseId});

  final String? warehouseId;

  static const WarehouseArrivalFillMemory empty = WarehouseArrivalFillMemory();

  WarehouseArrivalFillMemory copyWith({String? warehouseId}) =>
      WarehouseArrivalFillMemory(warehouseId: warehouseId ?? this.warehouseId);
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

    return WarehouseArrivalFillMemory(warehouseId: read('warehouseId'));
  }

  @override
  Object? encode(WarehouseArrivalFillMemory state) => {
    if (state.warehouseId != null) 'warehouseId': state.warehouseId,
  };

  /// 记住本次所落的仓（用户显式选择才调用；预填回写不算）。
  void rememberWarehouse(String? warehouseId) {
    final id = warehouseId?.trim();
    if (id == null || id.isEmpty || id == state.warehouseId) return;
    state = state.copyWith(warehouseId: id);
    persist();
  }
}

final warehouseArrivalFillMemoryProvider =
    NotifierProvider<
      WarehouseArrivalFillMemoryNotifier,
      WarehouseArrivalFillMemory
    >(WarehouseArrivalFillMemoryNotifier.new);
