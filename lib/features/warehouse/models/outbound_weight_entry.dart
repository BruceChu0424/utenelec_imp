// 出库类明细一行的「本次重量」录入状态 (ADR-135 §3.6-§3.9): 领料出库 / 销售出库 /
// 生产退料收仓 / 批量领料的材料申请行共用。
//
// 页面持有、随页面释放; 表格列由 widgets/outbound_weight_columns.dart 生成
// (借共享采集列 weightGridColumn 的格子, 占位/偏差框/⚖ 称重计数与采集表格同一口径)。
// 重量从不阻断数量过账: 取不到单重参数时格子退回「可选」, 偏差只提示不拦截。
import 'package:flutter/foundation.dart';

import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_predictor.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../../shared/measurement/widgets/weight_totals.dart';

/// 一行出库明细的重量录入状态。
///
/// 做成 [EditableGridRow] 只为复用共享重量格; [qtyOf] 取本行当前数量 (行单位),
/// [unitRate] 把它换成基本单位 (单重参数按基本单位给)。
/// 给了 [qtyController] (可改的本次数量) 时: 数量空着填重量会按称重推算数量 (黄框预填,
/// 行打上 qtyFromWeight); 不给 (销售出库/退料收仓的数量是既定的) 只核对偏差。
class OutboundWeightEntry extends EditableGridRow {
  OutboundWeightEntry({
    required this.goodsId,
    required this._qtyOf,
    this.qtyController,
    Listenable? qtyListenable,
    this.unitRate,
    this.supplierId,
    this.colorId,
    this.warehouseId,
    this.warehouseIdOf,
    double? kg,
    bool qtyFromWeight = false,
    WeightUnit unit = WeightUnit.kg,
  }) : qtyListenable = qtyListenable ?? qtyController,
       weight = WeightEntryController(
         kg: kg,
         unit: unit,
         qtyFromWeight: qtyFromWeight,
       );

  final String? goodsId;

  /// 单重参数按供应商取时用 (出库一律 null = 全货品单重)。
  final String? supplierId;
  final String? colorId;
  String? warehouseId;
  final String? Function()? warehouseIdOf;
  String? get currentWarehouseId => warehouseIdOf?.call() ?? warehouseId;

  /// 1 个行单位 = 多少基本单位; null = 不知道换算 (不核对偏差, 只记重量)。
  final double? unitRate;

  /// 可改的本次数量 (称重推算数量时黄框预填); null = 数量既定。
  final UtenAutofillTextController? qtyController;

  /// 数量变化源 (占位「应称」与偏差跟着数量重算)。
  final Listenable? qtyListenable;
  final double? Function() _qtyOf;
  final WeightEntryController weight;

  /// 本行数量 (行单位); 空/非法为 null。
  double? get qty => _qtyOf();

  /// 本行数量 (基本单位); 数量为空或换算未知时为 null。
  double? get qtyBase {
    final q = qty;
    final rate = unitRate;
    if (q == null || q <= 0 || rate == null || rate <= 0) return null;
    return q * rate;
  }

  /// 千克 (HALF_UP 4 位); 没称为 null。
  double? get kg => weight.kg;
  bool get qtyFromWeight => weight.qtyFromWeight;

  /// 幂等键/指纹片段: `千克|是否按称重改数量`。
  String get keyPart => weight.canonicalKeyPart;

  WeightParams? paramsIn(WeightParamsCache? cache) => cache?.of(
    goodsId,
    supplierId: supplierId,
    warehouseId: currentWarehouseId,
    colorId: colorId,
  );

  /// 数量 vs 实称核对 (按称重改过数量的行不核对)。
  WeightCheck? check(
    WeightParamsCache? cache, {
    WeightCaptureMode mode = WeightCaptureMode.outbound,
  }) {
    if (weight.qtyFromWeight) return null;
    final params = paramsIn(cache);
    // Exact inventory reference takes precedence; don't also warn against a
    // different historical mean for the same outbound row.
    if (suggestion(cache, mode: mode)?.inventoryBased == true) return null;
    return params?.check(qtyBase: qtyBase, weightKg: weight.kg, mode: mode);
  }

  WeightSuggestion? suggestion(
    WeightParamsCache? cache, {
    WeightCaptureMode mode = WeightCaptureMode.outbound,
  }) => paramsIn(cache)?.suggestionFor(qtyBase, mode: mode);

  bool hasWeightDeviation(
    WeightParamsCache? cache, {
    WeightCaptureMode mode = WeightCaptureMode.outbound,
  }) {
    if (weight.qtyFromWeight || kg == null) return false;
    final p = paramsIn(cache);
    if (suggestion(cache, mode: mode)?.inventoryBased == true) {
      return suggestion(cache, mode: mode)?.differsFrom(kg) ?? false;
    }
    return p?.alertsEnabled == true &&
        (check(cache, mode: mode)?.level ?? WeightAlertLevel.none) !=
            WeightAlertLevel.none;
  }

  /// 取参请求行 (没有货品时为 null)。
  WeightParamsLine? get paramsLine {
    final id = goodsId;
    if (id == null || id.isEmpty) return null;
    return WeightParamsLine(
      goodsId: id,
      supplierId: supplierId,
      warehouseId: currentWarehouseId,
      colorId: colorId,
    );
  }

  @override
  void dispose() {
    weight.dispose();
    super.dispose();
  }
}

/// 页面取参: 所有有货品的行一次批量取 (已有/在途的不重复取)。
Future<void> ensureOutboundWeightParams(
  WeightParamsCache? cache,
  Iterable<OutboundWeightEntry> entries,
) async {
  if (cache == null) return;
  await cache.ensure(entries.map((e) => e.paramsLine).whereType());
}

/// 表尾重量汇总 (「实称 X (未称 N 行)」与「称重偏差 N 行」两项的输入)。
WeightTotalsSummary outboundWeightTotals(
  Iterable<OutboundWeightEntry> entries, {
  WeightParamsCache? params,
  WeightCaptureMode mode = WeightCaptureMode.outbound,
}) {
  final list = entries.toList(growable: false);
  var deviation = 0;
  for (final entry in list) {
    if (entry.kg == null) continue;
    if (entry.hasWeightDeviation(params, mode: mode)) deviation++;
  }
  return WeightTotalsSummary.of([
    for (final e in list) e.kg,
  ], deviationRows: deviation);
}
