import '../formatters/exact_decimal.dart';
// 按重量计的单位与精确重量 (ADR-135 §1): 业务单位登记了「等于哪种重量单位」时,
// 这类行的重量由数量精确换算 (EXACT), 采集表格只读显示「=25 kg」, 提交不带重量
// (服务端按数量算)。仓库各采集页 (到货/产成品登记、仓库单据、领料/销售/委外出库) 共用。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_endpoints.dart';
import '../providers/master_dictionary_repository.dart';
import 'weight_params.dart';
import 'weight_unit.dart';

/// 单位 -> 它等于哪种重量单位 (基础资料-单位「等于哪种重量单位」); 不是重量单位的不在表里。
///
/// 行单位本身是重量单位 (如按千克买、按个记账的螺丝) 时, 这一行的重量由数量精确换算,
/// 格子只读「=25 kg」, 提交不带重量 (服务端按数量算 EXACT)。取数走会话级单位字典。
final warehouseUnitMassUnitsProvider = FutureProvider<Map<String, WeightUnit>>((
  ref,
) async {
  final rows = await ref
      .watch(masterDictionaryRepositoryProvider)
      .load(ApiEndpoints.unitsDict);
  return {
    for (final row in rows)
      if (row['id'] case final String id)
        id: ?WeightUnit.parse(row['massUnitCode']?.toString()),
  };
});

/// 行的精确重量 (千克完整有限乘积，不固定取位); 需要实称时返回 null。
///
/// - 行单位是重量单位: 行数量 x 该单位千克数;
/// - 货品按重量计 ([WeightParams.isExact]): 基本数量 (行数量 x [unitRate]) x 系数。
String? warehouseExactLineKg({
  required Object? lineQty,
  WeightUnit? lineMassUnit,
  Object unitRate = 1,
  WeightParams? params,
}) {
  final qty = financeExactTrimmed(financeExactDecimal(lineQty));
  if (qty == null || qty == '0' || qty.startsWith('-')) return null;
  if (lineMassUnit != null) return lineMassUnit.toKgText(qty);
  if (params != null && params.isExact) {
    final rawRate = financeExactTrimmed(financeExactDecimal(unitRate));
    if (rawRate == null || rawRate == '0' || rawRate.startsWith('-')) {
      return null;
    }
    final rate = rawRate;
    return financeExactTrimmed(
      financeExactMultiplyTexts([qty, rate, params.massFactorKgText]),
    );
  }
  return null;
}
