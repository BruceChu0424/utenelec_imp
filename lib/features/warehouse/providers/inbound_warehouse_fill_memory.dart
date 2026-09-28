// 入库登记「上次所选入库仓」记忆(账号级，跨设备经 user_preferences 同步)。
//
// 2026-09-27 用户口径「产成品入库与采购/委外入库 UI、逻辑、记忆都一样」：原来两份
// 逐字相同的记忆类(warehouse_arrival_fill_memory / production_finished_arrival_fill_memory)
// 收成这一个类，按入库来源各占一个偏好键——原材料与成品通常落不同仓，分开记才准。
//
// 预填优先级(两类登记页同一条链，先命中先用)：
//   1. 行内已有值 —— 用户自己选的，任何预填都不覆盖；
//   2. 来源默认仓 —— 货品主档归属仓(采购另有订货单建议仓)；
//   3. 本记忆 —— 上次在登记页显式选择的仓，兜底预填。
// 预填一律黄框提醒核对，用户一动即清标。库位不在这里记：库位按「仓库 × 货品 × 颜色」
// 走服务端库位建议(warehouse_goods_place_preferences → 货品资料通用库位)。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/uten_page_prefs_notifier.dart';

/// 记忆按入库来源分键(偏好键沿用历史键名，已存的记忆不丢)。
enum InboundFillScope {
  /// 采购 / 委外到货登记。
  procurement('warehouse.arrivalFill'),

  /// 产成品登记。
  finished('production.finishedArrivalFill');

  const InboundFillScope(this.prefKey);

  final String prefKey;
}

/// 只记个人上次选仓；旧 JSON 里的 stockPlace 等字段忽略，也不再写回。
class InboundWarehouseFillMemory {
  const InboundWarehouseFillMemory({this.warehouseId});

  final String? warehouseId;

  static const InboundWarehouseFillMemory empty = InboundWarehouseFillMemory();
}

class InboundWarehouseFillMemoryNotifier
    extends UtenPagePrefsNotifier<InboundWarehouseFillMemory> {
  InboundWarehouseFillMemoryNotifier(this.scope);

  final InboundFillScope scope;

  @override
  String get prefKey => scope.prefKey;

  @override
  InboundWarehouseFillMemory get defaultValue =>
      InboundWarehouseFillMemory.empty;

  @override
  InboundWarehouseFillMemory? decode(Object? raw) {
    if (raw is! Map) return null;
    final value = raw['warehouseId'];
    final trimmed = value is String ? value.trim() : '';
    return trimmed.isEmpty
        ? InboundWarehouseFillMemory.empty
        : InboundWarehouseFillMemory(warehouseId: trimmed);
  }

  @override
  Object? encode(InboundWarehouseFillMemory state) => {
    if (state.warehouseId != null) 'warehouseId': state.warehouseId,
  };

  /// 记住本次显式选择的仓(预填回写不算；清空不记)。
  void rememberWarehouse(String? warehouseId) {
    final id = warehouseId?.trim();
    if (id == null || id.isEmpty || id == state.warehouseId) return;
    state = InboundWarehouseFillMemory(warehouseId: id);
    persist();
  }
}

final _procurementFillMemoryProvider =
    NotifierProvider<
      InboundWarehouseFillMemoryNotifier,
      InboundWarehouseFillMemory
    >(() => InboundWarehouseFillMemoryNotifier(InboundFillScope.procurement));

final _finishedFillMemoryProvider =
    NotifierProvider<
      InboundWarehouseFillMemoryNotifier,
      InboundWarehouseFillMemory
    >(() => InboundWarehouseFillMemoryNotifier(InboundFillScope.finished));

/// 按入库来源取对应的选仓记忆。
NotifierProvider<InboundWarehouseFillMemoryNotifier, InboundWarehouseFillMemory>
inboundWarehouseFillMemoryProvider(InboundFillScope scope) => switch (scope) {
  InboundFillScope.procurement => _procurementFillMemoryProvider,
  InboundFillScope.finished => _finishedFillMemoryProvider,
};
