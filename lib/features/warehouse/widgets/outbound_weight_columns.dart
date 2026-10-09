// 出库类明细表的「本次重量」列 (ADR-135 §3.6-§3.9): 领料出库 / 销售出库 / 生产退料收仓。
//
// 这些明细表是 MasterDataTableView (只读表 + 行内输入), 不是 UtenEditableGrid;
// 这里复用共享采集列 [weightGridColumn] (预估预填、黄色偏差文字与称重操作),
// 各出库表的重量格与采集表格同一长相同一口径，说明图标只留在表头:
// - [outboundWeightColumn]: 可编辑「实称重量(kg)」列;
// - [outboundWeightCheckColumn]: 「称重核对」只读列 (偏差标签, 如「比应发多约35个 (+1.5%)」);
// - [weighOutboundEntry]: 出库反推称重计数 (需要 N 个 → 秤上应显示约 Y kg), 只回填重量;
// - [OutboundWeightSummaryBar]: 表尾「明细 N 行 · 实称 X (未称 N 行) · 称重偏差 N 行」。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_predictor.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weigh_count_dialog.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/measurement/widgets/weight_totals.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/outbound_weight_entry.dart';

/// 可编辑「实称重量(单位)」列; [entryOf] 返回 null 的行显示「—」。
MasterColumnDef<R> outboundWeightColumn<R>({
  required OutboundWeightEntry? Function(R row) entryOf,
  required WeightUnit entryUnit,
  WeightParamsCache? params,
  String key = 'weight',
  String label = '实称重量',
  double width = 120,
  WeightCaptureMode mode = WeightCaptureMode.outbound,
  bool Function(R row)? enabledOf,
  String? Function(OutboundWeightEntry entry)? baseUnitNameOf,
  Future<void> Function(BuildContext context, OutboundWeightEntry entry)?
  onWeighCount,
  ValueChanged<OutboundWeightEntry>? onChanged,
}) {
  // 按行开关要落到格子上: 先按行身份记下「这行能不能编辑」。
  final enabledByEntry = Expando<bool>();
  final column = weightGridColumn<OutboundWeightEntry>(
    controllerOf: (entry) => entry.weight,
    entryUnit: entryUnit,
    key: key,
    label: label,
    width: width,
    mode: mode,
    paramsOf: params == null ? null : (entry) => entry.paramsIn(params),
    paramsListenable: params,
    qtyBaseOf: (entry) => entry.qtyBase,
    qtyListenableOf: (entry) => entry.qtyListenable,
    baseUnitNameOf: baseUnitNameOf,
    enabledOf: (entry) => enabledByEntry[entry] ?? true,
    // 可改数量的行 (领料本次出库/材料申请领料数量): 数量空着时按称重推算。
    qtyAutofill: WeightQtyAutofill<OutboundWeightEntry>(
      qtyControllerOf: (entry) => entry.qtyController!,
      unitRateOf: (entry) => entry.unitRate,
      enabledOf: (entry) =>
          entry.qtyController != null &&
          entry.unitRate != null &&
          (enabledByEntry[entry] ?? true),
    ),
    onWeighCount: onWeighCount,
    onChanged: onChanged,
  );
  return MasterColumnDef<R>(
    key: key,
    label: column.label,
    width: column.width + column.chromeWidth,
    type: 'number',
    info: column.headerInfo,
    cellBuilderHandlesSemantics: true,
    value: (row) => entryOf(row)?.weight.text.text ?? '',
    // Delegate canonical kilograms and EXACT quantity-derived weights to the
    // shared capture column; its listeners include quantity and unit metadata.
    exactValueOf: (row) {
      final entry = entryOf(row);
      return entry == null ? null : column.exactValueOf?.call(entry);
    },
    exactListenableOf: (row) {
      final entry = entryOf(row);
      return entry == null ? null : column.exactListenableOf?.call(entry);
    },
    cellBuilder: (context, row) {
      final entry = entryOf(row);
      if (entry == null) return const Text('—');
      enabledByEntry[entry] = enabledOf?.call(row) ?? true;
      return Semantics(
        textField: true,
        label: column.label,
        child: column.cellBuilder(context, entry),
      );
    },
  );
}

/// 「称重核对」只读列: 默认只在 WARN/ALERT 时出标签; [textOf] 给出时总显示 (如退料
/// 「登记退 N 个, 称重约 M 个」)。
MasterColumnDef<R> outboundWeightCheckColumn<R>({
  required OutboundWeightEntry? Function(R row) entryOf,
  WeightParamsCache? params,
  String key = 'weightCheck',
  String label = '称重核对',
  double width = 200,
  WeightCaptureMode mode = WeightCaptureMode.outbound,
  String? Function(OutboundWeightEntry entry)? unitNameOf,
  String Function(WeightCheck check, OutboundWeightEntry entry)? textOf,
}) {
  String? text(OutboundWeightEntry entry) {
    if (mode == WeightCaptureMode.outbound &&
        entry.paramsIn(params)?.stockBalance?.expectedKgFor(entry.qtyBase) !=
            null) {
      if (!entry.hasWeightDeviation(params, mode: mode)) return null;
      final expected = entry.suggestion(params, mode: mode)!;
      return '数值可能有问题，预计约 ${formatWeight(expected.kg)}';
    }
    final check = entry.check(params, mode: mode);
    if (check == null) return null;
    if (textOf != null) return textOf(check, entry);
    if (check.level == WeightAlertLevel.none) return null;
    return weightCheckShortText(
      check,
      mode: mode,
      unitName: unitNameOf?.call(entry),
    );
  }

  return MasterColumnDef<R>(
    key: key,
    label: label,
    width: width,
    info: '出库优先按对应仓库、货品、颜色的库存均重核对，否则参考可靠历史单重。偏差变黄提醒，不拦截出入库。',
    value: (row) {
      final entry = entryOf(row);
      return entry == null ? '' : (text(entry) ?? '');
    },
    // 2026-09-27 用户口径「格内胶囊改单元格背景色」：偏差档位色铺整格
    // （偏差统一琥珀 / 无偏差不铺色；textOf 常显文本时无偏差铺中性灰）。
    // 底色依赖行内重量/数量输入，经 cellColorListenableOf 让整格实时重算。
    cellColor: (context, row) {
      final entry = entryOf(row);
      if (entry == null) return null;
      if (entry.hasWeightDeviation(params, mode: mode)) {
        return utenStatusBadgeCellColor(UtenStatusBadgeType.warning);
      }
      final check = entry.check(params, mode: mode);
      final resolved = entry.paramsIn(params);
      // 单重没学准 (或非学习/人工单重) 不核对, 不铺色 (防假阳性)。
      if (check == null || resolved == null || !resolved.alertsEnabled) {
        return null;
      }
      return switch (check.level) {
        WeightAlertLevel.alert => utenStatusBadgeCellColor(
          UtenStatusBadgeType.warning,
        ),
        WeightAlertLevel.warn => utenStatusBadgeCellColor(
          UtenStatusBadgeType.warning,
        ),
        WeightAlertLevel.none =>
          textOf == null
              ? null
              : utenStatusBadgeCellColor(UtenStatusBadgeType.neutral),
      };
    },
    cellColorListenableOf: (row) {
      final entry = entryOf(row);
      if (entry == null) return null;
      return Listenable.merge([entry.weight, ?params, ?entry.qtyListenable]);
    },
    cellBuilder: (context, row) {
      final entry = entryOf(row);
      if (entry == null) return const SizedBox.shrink();
      return ListenableBuilder(
        listenable: Listenable.merge([
          entry.weight,
          ?params,
          ?entry.qtyListenable,
        ]),
        builder: (context, _) {
          final check = entry.check(params, mode: mode);
          final resolved = entry.paramsIn(params);
          final body = text(entry) ?? '';
          if (mode == WeightCaptureMode.outbound &&
              resolved?.stockBalance?.expectedKgFor(entry.qtyBase) != null) {
            if (body.isEmpty) return const SizedBox.shrink();
            return Tooltip(
              message:
                  '$body；实称 ${formatWeight(entry.kg!)}。请核对数量、重量单位和包装；确认无误仍可出库。',
              child: Text(body),
            );
          }
          // 单重没学准 (或非学习/人工单重) 不核对, 不出文本 (防假阳性)。
          if (check == null || resolved == null || !resolved.alertsEnabled) {
            return const SizedBox.shrink();
          }
          final unitName = unitNameOf?.call(entry);
          if (body.isEmpty) return const SizedBox.shrink();
          return Tooltip(
            message: weightCheckTooltip(
              check,
              resolved,
              mode: mode,
              unitName: unitName,
            ),
            child: Text(body),
          );
        },
      );
    },
  );
}

/// 出库反推称重计数: 「需要 N 个 → 净重约 X kg (区间) + 皮重 → 秤上应显示约 Y kg」,
/// 称完只回填重量 (出库数量是应发数量, 不按称重改)。本批抽样保存后刷新该货品单重参数。
Future<void> weighOutboundEntry(
  BuildContext context, {
  required OutboundWeightEntry entry,
  required String goodsTitle,
  WeightParamsCache? cache,
  String? baseUnitName,
  String? lineUnitName,
  String? warehouseId,
  String? sampleRemark,
}) async {
  final goodsId = entry.goodsId;
  if (goodsId == null || goodsId.isEmpty) return;
  final result = await showWeighCountDialog(
    context,
    request: WeighCountRequest(
      mode: WeighCountContext.outbound,
      goodsId: goodsId,
      goodsTitle: goodsTitle,
      params: entry.paramsIn(cache),
      supplierId: entry.supplierId,
      warehouseId: warehouseId ?? entry.currentWarehouseId,
      colorId: entry.colorId,
      expectedWeightKg: entry
          .paramsIn(cache)
          ?.suggestionFor(entry.qtyBase, mode: WeightCaptureMode.outbound)
          ?.kg,
      baseUnitName: baseUnitName,
      lineUnitName: lineUnitName,
      unitRate: entry.unitRate ?? 1,
      currentQty: entry.unitRate == null ? null : entry.qty,
      initialNetKg: entry.kg,
      sampleRemark: sampleRemark,
    ),
  );
  if (result == null) return;
  applyWeighCountResult(result, weight: entry.weight);
  if (result.sample?.saved == true && cache != null) {
    cache.invalidateGoods(goodsId);
    final line = entry.paramsLine;
    if (line != null) await cache.ensure([line]);
  }
}

/// 表尾「明细 N 行 · 实称 X (未称 N 行) · 称重偏差 N 行」: 随重量/数量/参数变化就地重算
/// (编辑中的采集表格合计在客户端算)。
class OutboundWeightSummaryBar extends StatelessWidget {
  const OutboundWeightSummaryBar({
    super.key,
    required this.entries,
    this.params,
    this.mode = WeightCaptureMode.outbound,
  });

  final List<OutboundWeightEntry> entries;
  final WeightParamsCache? params;
  final WeightCaptureMode mode;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      for (final entry in entries) ...[entry.weight, ?entry.qtyListenable],
      ?params,
    ]),
    builder: (context, _) {
      final summary = outboundWeightTotals(entries, params: params, mode: mode);
      return UtenTotalsSummaryBar(
        key: const Key('outbound-weight-summary'),
        rowCount: entries.length,
        entries: [...weightTotalEntries(summary)],
      );
    },
  );
}
