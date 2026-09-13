// 产成品登记「上次所选成品仓」记忆（账号级，跨设备经 user_preferences 同步）。
//
// 2026-09-12 用户口径（与采购批量登记页 warehouse_arrival_fill_memory 同款）：
// 勾选多行后选任意一个成品仓 = 批量落到全部选中行；且要记住这次选的仓，下次
// 自动带。这里只记仓不记库位——库位建议走服务端 V431 偏好链（该仓默认 → 最近
// 登记 → 货品主档），按「仓 × 货品」逐行匹配，比单一记忆更准，不与它打架。
//
// 预填优先级（与页内既有链一致）：
//   1. 行内已有值 / 同货品最近登记仓 —— 任何预填都不许覆盖；
//   2. 服务端 lastArrivalWarehouse —— 上次**成功登记**所用仓（更权威）；
//   3. 本记忆 —— 上次在本页显式选择的仓（登记未完成也记得），兜底预填。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/uten_page_prefs_notifier.dart';

class ProductionFinishedArrivalFillMemory {
  const ProductionFinishedArrivalFillMemory({this.warehouseId});

  final String? warehouseId;

  static const ProductionFinishedArrivalFillMemory empty =
      ProductionFinishedArrivalFillMemory();

  ProductionFinishedArrivalFillMemory copyWith({String? warehouseId}) =>
      ProductionFinishedArrivalFillMemory(
        warehouseId: warehouseId ?? this.warehouseId,
      );
}

class ProductionFinishedArrivalFillMemoryNotifier
    extends UtenPagePrefsNotifier<ProductionFinishedArrivalFillMemory> {
  @override
  String get prefKey => 'production.finishedArrivalFill';

  @override
  ProductionFinishedArrivalFillMemory get defaultValue =>
      ProductionFinishedArrivalFillMemory.empty;

  @override
  ProductionFinishedArrivalFillMemory? decode(Object? raw) {
    if (raw is! Map) return null;
    final value = raw['warehouseId'];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty
        ? ProductionFinishedArrivalFillMemory.empty
        : ProductionFinishedArrivalFillMemory(warehouseId: trimmed);
  }

  @override
  Object? encode(ProductionFinishedArrivalFillMemory state) =>
      state.warehouseId == null ? const {} : {'warehouseId': state.warehouseId};

  /// 记住本次显式选择的成品仓（预填回写不算；清空不记）。
  void rememberWarehouse(String? warehouseId) {
    final id = warehouseId?.trim();
    if (id == null || id.isEmpty || id == state.warehouseId) return;
    state = state.copyWith(warehouseId: id);
    persist();
  }
}

final productionFinishedArrivalFillMemoryProvider =
    NotifierProvider<
      ProductionFinishedArrivalFillMemoryNotifier,
      ProductionFinishedArrivalFillMemory
    >(ProductionFinishedArrivalFillMemoryNotifier.new);
