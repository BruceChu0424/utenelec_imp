import '../../report/shared/report_total.dart';
import '../../../shared/measurement/weight_unit.dart';

/// 只消费服务端的全筛选范围合计，绝不从分页行推算全仓指标。
class InstantInventorySummary {
  InstantInventorySummary({required this.totals, required this.totalRows});

  final List<ReportTotal> totals;
  final int totalRows;

  ReportTotal? total(String key) {
    for (final value in totals) {
      if (value.key == key) return value;
    }
    return null;
  }

  /// 旧服务端未提供时保留未知，不能显示成零风险。
  int? count(String key) {
    final item = total(key);
    if (item == null || item.groups.isEmpty) return null;
    final value = item.groups.first.value;
    return value.isFinite && value >= 0 ? value.round() : null;
  }

  bool get hasAnalysis => count('inventory_rows') != null;

  String weightText(WeightDisplay display) {
    final weight = total('weight');
    // SUM 全 NULL 时服务端会省略 weight 项，但未称计数仍然有效。
    if (weight == null) {
      final unknown = count('weight_unknown_rows') ?? 0;
      return unknown > 0 ? '$unknown 项未称' : '统计暂不可用';
    }
    final text = reportTotalEntry(
      weight,
      weightDisplay: display,
      weightUnknownRows: count('weight_unknown_rows') ?? 0,
      weightEstimated: (count('weight_estimated_rows') ?? 0) > 0,
    ).value;
    return text.isEmpty ? '暂无重量数据' : text;
  }

  double? get weightCoverage {
    final known = count('stocked_weight_known_rows');
    final unknown = count('stocked_weight_unknown_rows');
    if (known == null || unknown == null || known + unknown == 0) return null;
    return known / (known + unknown);
  }

  /// 同一单位横向比较三个阶段；不跨单位求和，不把待检/待入库计入库存。
  List<InventoryUnitSummary> get units {
    const keys = ['qty', 'pending_qty', 'pending_stock_in_qty'];
    final values = <String?, Map<String, double>>{};
    for (final key in keys) {
      for (final group in total(key)?.groups ?? <ReportTotalGroup>[]) {
        // 未维护单位不能认作同一物理单位。保留 null/空串/空白的服务端分组，
        // 既不覆盖丢量，也不擅自跨未知单位求和。
        values.putIfAbsent(group.unit, () => {})[key] = group.value;
      }
    }
    return [
      for (final entry in values.entries)
        if (entry.value.values.any((v) => v != 0))
          InventoryUnitSummary(
            unit: (entry.key?.trim().isEmpty ?? true) ? '单位未维护' : entry.key!,
            missingUnit: entry.key?.trim().isEmpty ?? true,
            quantity: total('qty') == null ? null : entry.value['qty'] ?? 0,
            pending: total('pending_qty') == null
                ? null
                : entry.value['pending_qty'] ?? 0,
            pendingStockIn: total('pending_stock_in_qty') == null
                ? null
                : entry.value['pending_stock_in_qty'] ?? 0,
          ),
    ];
  }

  List<InventoryAdvice> get advice {
    final result = <InventoryAdvice>[];
    void add(String key, String title, String message, {bool urgent = false}) {
      final value = count(key);
      if (value != null && value > 0) {
        final attention = switch (key) {
          'negative_balance_rows' ||
          'negative_stock_rows' => 'NEGATIVE_BALANCE',
          'nonpositive_pending_stock_in_rows' => 'AWAITING_STOCK_IN',
          'nonpositive_pending_inspection_rows' => 'AWAITING_INSPECTION',
          'stocked_weight_unknown_rows' => 'UNKNOWN_WEIGHT',
          'missing_unit_rows' => 'MISSING_UNIT',
          _ => null,
        };
        result.add(
          InventoryAdvice(
            title,
            '$value$message',
            urgent: urgent,
            attention: attention,
          ),
        );
      }
    }

    add(
      'negative_balance_rows',
      '优先核查负库存',
      ' 处仓库余额为负。核对出入库流水、补录时序与盘点差异；跨仓汇总可能掩盖这些异常。',
      urgent: true,
    );
    if (count('negative_balance_rows') == null) {
      add(
        'negative_stock_rows',
        '优先核查负库存',
        ' 项汇总库存为负，请核查对应货品的各仓余额与出入库流水。',
        urgent: true,
      );
    }
    add(
      'nonpositive_pending_stock_in_rows',
      '优先确认合格待入库',
      ' 项库存不大于零，同时有合格待入库货物。核实实物与入库任务，完成确认后再参与库存供应。',
    );
    add(
      'nonpositive_pending_inspection_rows',
      '关注待检进度',
      ' 项库存不大于零，同时有待检货物。核实生产需求后协调检验；检验放行前不能作为可用库存。',
    );
    add(
      'stocked_weight_unknown_rows',
      '补全库存重量',
      ' 项非零库存的重量未知，当前合计只覆盖已知重量。建议结合盘点补称。',
    );
    add('missing_unit_rows', '补全计量单位', ' 项货品未维护单位。先核实基本单位，再比较数量和补货需求。');
    return result;
  }

  String get headline {
    if (totalRows == 0) return '当前筛选范围暂无货品';
    if (!hasAnalysis) return '当前可查看汇总，分析指标暂未提供';
    if (advice.isNotEmpty) return advice.first.title;
    return '当前规则未发现优先处理事项';
  }
}

class InventoryUnitSummary {
  const InventoryUnitSummary({
    required this.unit,
    required this.missingUnit,
    required this.quantity,
    required this.pending,
    required this.pendingStockIn,
  });

  final String unit;
  final bool missingUnit;
  final double? quantity;
  final double? pending;
  final double? pendingStockIn;
}

class InventoryAdvice {
  const InventoryAdvice(
    this.title,
    this.message, {
    this.urgent = false,
    this.attention,
  });
  final String title;
  final String message;
  final bool urgent;
  final String? attention;
}
