import 'package:flutter/material.dart';

import '../models/warehouse_sales_outbound.dart';

/// 仓库确认出库前的本地核对意图(V631：逐行发出仓 + 逐行实际库位)；真实预留与
/// 可发量由服务端命令在同一事务再次校验，这里只负责预填与就地提示。
///
/// 预填口径(2026-09-20 用户拍板「实际发货仓库不用选，表格里按行选发出仓并提前预填」)：
/// - 发出仓 = 已落定的行仓 > 服务端建议仓(表头仓能发则表头仓，否则首个能发出本行的仓) > 表头仓；
/// - 实际库位 = 已确认的实际库位 > 主档建议库位；无固定库位可清空。
class WarehouseSalesPickingDraft {
  WarehouseSalesPickingDraft(this.detail) {
    for (final line in detail.lines) {
      warehouses[line.id] =
          line.warehouseId ??
          line.suggestedWarehouseId ??
          detail.header.warehouseId;
      places[line.id] = TextEditingController(
        text: line.actualStockPlace ?? line.currentStockPlaceHint ?? '',
      );
    }
  }

  final WarehouseSalesOutboundDetail detail;

  /// 逐行发出仓当前选择(行 id → 仓 id)。
  final Map<String, String?> warehouses = {};
  final Map<String, TextEditingController> places = {};

  /// 逐行校验错误(行 id → 文案)，由 [validate] 填充、改选后清除。
  final Map<String, String> lineErrors = {};
  String? error;

  Map<String, String> get stockPlaces => {
    for (final entry in places.entries) entry.key: entry.value.text.trim(),
  };

  Map<String, String?> get lineWarehouses => Map.unmodifiable(warehouses);

  /// 本单是否处于「待确认出库」——只有这时发出仓才可选。
  bool get selectable =>
      detail.header.allows(WarehouseSalesOutboundAction.confirmShipment);

  WarehouseSalesOutboundLine? lineOf(String lineId) {
    for (final line in detail.lines) {
      if (line.id == lineId) return line;
    }
    return null;
  }

  WarehouseSalesWarehouseChoice? choiceOf(String lineId) =>
      lineOf(lineId)?.choice(warehouses[lineId]);

  /// 当前所选发出仓的名称：候选仓 > 已落定的行仓 > 表头仓；选空返回 null。
  String? warehouseNameOf(String lineId) {
    final selected = warehouses[lineId];
    if (selected == null) return null;
    final choice = choiceOf(lineId);
    if (choice != null) return choice.warehouseName;
    final line = lineOf(lineId);
    if (line?.warehouseId == selected) return line?.warehouseName;
    if (detail.header.warehouseId == selected) {
      return detail.header.warehouseName;
    }
    return null;
  }

  void changeWarehouse(String lineId, String? value) {
    warehouses[lineId] = value;
    lineErrors.remove(lineId);
    error = null;
  }

  bool validate() {
    lineErrors.clear();
    if (selectable) {
      for (final line in detail.lines) {
        final selected = warehouses[line.id];
        if (selected == null) {
          lineErrors[line.id] = '请选择本行的实际发出仓';
          continue;
        }
        final choice = line.choice(selected);
        if (choice == null && line.warehouseChoices.isNotEmpty) {
          lineErrors[line.id] = '所选仓库没有本行货品的可发库存，请重新选择';
          continue;
        }
        if (choice != null && !choice.canFulfill) {
          lineErrors[line.id] =
              '该仓可发 ${choice.availableQty ?? '0'}，不足本行 ${choice.requiredQty ?? line.quantity ?? '0'}';
        }
      }
    }
    if (lineErrors.isEmpty) {
      error = null;
    } else {
      final first = lineErrors.entries.first;
      final lineNo = lineOf(first.key)?.lineNumber;
      error = '${lineNo == null ? '' : '第 $lineNo 行：'}${first.value}';
    }
    return error == null;
  }

  void dispose() {
    for (final controller in places.values) {
      controller.dispose();
    }
  }
}
