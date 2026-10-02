import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_predictor.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../models/outbound_weight_entry.dart';
import '../models/warehouse_sales_outbound.dart';

/// 仓库确认出库前的本地核对意图(V631：逐行发出仓 + 逐行实际库位)；真实预留与
/// 可发量由服务端命令在同一事务再次校验，这里只负责预填与就地提示。
///
/// 预填口径(2026-09-20 用户拍板「实际发货仓库不用选，表格里按行选发出仓并提前预填」)：
/// - 发出仓 = 已落定的行仓 > 服务端建议仓(表头仓能发则表头仓，否则首个能发出本行的仓) > 表头仓；
/// - 实际库位 = 已确认的实际库位 > 主档建议库位；无固定库位可清空。
/// - 实称重量(ADR-135 §3.7)：待出库时逐行选填，随确认出库一起提交，只落销售出库流水；
///   偏差只提醒(ALERT 在确认弹窗里请复核拣货)，从不拦截出库。数量是财务放行的既定数量，
///   不按称重改。
class WarehouseSalesPickingDraft {
  WarehouseSalesPickingDraft(
    this.detail, {
    WeightUnit weightUnit = WeightUnit.kg,
  }) {
    for (final line in detail.lines) {
      warehouses[line.id] =
          line.warehouseId ??
          line.suggestedWarehouseId ??
          detail.header.warehouseId;
      places[line.id] = TextEditingController(
        text: line.actualStockPlace ?? line.currentStockPlaceHint ?? '',
      );
      if (selectable) {
        weights[line.id] = OutboundWeightEntry(
          goodsId: line.goodsId,
          colorId: line.colorId,
          warehouseIdOf: () => warehouses[line.id],
          qtyOf: () => double.tryParse(line.quantity ?? ''),
          unitRate: line.unitRate,
          unit: weightUnit,
        );
      }
    }
  }

  final WarehouseSalesOutboundDetail detail;

  /// 逐行发出仓当前选择(行 id → 仓 id)。
  final Map<String, String?> warehouses = {};
  final Map<String, TextEditingController> places = {};

  /// 逐行实称重量(行 id → 录入状态)；只在待确认出库时有。
  final Map<String, OutboundWeightEntry> weights = {};

  /// 随确认出库提交的逐行实称千克(没称的行不带)。
  Map<String, double> get lineWeights => {
    for (final entry in weights.entries) entry.key: ?entry.value.kg,
  };

  /// 实称明显偏离应发数量(ALERT)的行：确认出库前请复核拣货(不拦截)。
  List<({WarehouseSalesOutboundLine line, WeightCheck check})> weightAlerts(
    WeightParamsCache? params,
  ) => [
    for (final line in detail.lines)
      if (weights[line.id]?.check(params) case final check?
          when check.level == WeightAlertLevel.alert)
        (line: line, check: check),
  ];

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
      for (final line in detail.lines) {
        if (weights[line.id]?.weight.hasError == true) {
          final lineNo = line.lineNumber;
          error =
              '${lineNo == null ? '' : '第 $lineNo 行：'}实称重量看不懂，请改成如 12.5 或 850g';
          break;
        }
      }
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
    for (final entry in weights.values) {
      entry.dispose();
    }
  }
}

/// 确认出库软提醒的一行 (如「第 2 行 货品甲：少 4.8%, 请复核拣货」)。
String warehouseSalesWeightAlertText(
  WarehouseSalesOutboundLine line,
  WeightCheck check,
) {
  final pct = check.deviationPct;
  final amount = ((pct.abs() * 10).roundToDouble() / 10).toStringAsFixed(1);
  final lineNo = line.lineNumber == null ? '' : '第 ${line.lineNumber} 行 ';
  return '$lineNo${line.goodsName ?? line.goodsCode ?? ''}：'
      '${pct < 0 ? '少' : '多'} $amount%, 请复核拣货';
}

/// 确认出库弹窗里的称重软提醒 (ALERT 行: 「少 4.8%, 请复核拣货」); 只提醒, 仍可确认出库。
Widget? warehouseSalesWeightAlertNotice(
  BuildContext context,
  List<String> lines,
) {
  if (lines.isEmpty) return null;
  final theme = Theme.of(context);
  return Container(
    key: const Key('warehouse-sales-outbound-weight-alerts'),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
      borderRadius: UtenRadius.mdAll,
    ),
    child: Text(
      '称重与应发数量偏差较大 (不影响出库, 请复核后再确认):\n${lines.join('\n')}',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.error,
        height: 1.45,
      ),
    ),
  );
}
