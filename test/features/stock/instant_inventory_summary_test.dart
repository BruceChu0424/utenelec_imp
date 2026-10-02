import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/report/shared/report_total.dart';
import 'package:uten_imp/features/stock/models/instant_inventory_summary.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';

void main() {
  test('按单位横向统计三个阶段，隐藏全零单位并保留负数和缺失单位', () {
    final summary = InstantInventorySummary(
      totalRows: 137,
      totals: [
        _quantities('qty', {'个': 900, '箱': 20, '米': 0, '卷': -3, null: 4}),
        _quantities('pending_qty', {'个': 0, '箱': 5, '米': 0, '件': 8}),
        _quantities('pending_stock_in_qty', {'个': 2, '箱': 0, '米': 0}),
      ],
    );

    final units = {for (final row in summary.units) row.unit: row};
    expect(units.keys, unorderedEquals(['个', '箱', '卷', '单位未维护', '件']));
    expect(units['个']!.quantity, 900);
    expect(units['个']!.pending, 0);
    expect(units['个']!.pendingStockIn, 2);
    expect(units['箱']!.quantity, 20);
    expect(units['箱']!.pending, 5);
    expect(units['卷']!.quantity, -3);
    expect(units['件']!.quantity, 0);
    expect(units['件']!.pending, 8);
    expect(units['单位未维护']!.missingUnit, isTrue);
    expect(units['单位未维护']!.quantity, 4);
  });

  test('服务端没有提供的阶段保持未知，不能伪造成零待检', () {
    final summary = InstantInventorySummary(
      totalRows: 137,
      totals: [
        _quantities('qty', {'个': 900}),
      ],
    );

    expect(summary.units.single.quantity, 900);
    expect(summary.units.single.pending, isNull);
    expect(summary.units.single.pendingStockIn, isNull);
    expect(summary.hasAnalysis, isFalse);
    expect(summary.headline, '当前可查看汇总，分析指标暂未提供');
    expect(summary.weightCoverage, isNull);
  });

  test('缺单位的不同原始分组分别保留，不能覆盖丢量或擅自合并', () {
    final summary = InstantInventorySummary(
      totalRows: 2,
      totals: [
        _quantities('qty', {null: 4, '': 7}),
      ],
    );

    expect(summary.units, hasLength(2));
    expect(summary.units.every((row) => row.missingUnit), isTrue);
    expect(summary.units.map((row) => row.quantity), unorderedEquals([4, 7]));
    expect(summary.units.map((row) => row.unit), everyElement('单位未维护'));
  });

  test('重量覆盖只统计非零余额，零库存和估算项不重复进入分母', () {
    final summary = InstantInventorySummary(
      totalRows: 137,
      totals: [
        _count('inventory_rows', 137),
        _count('zero_stock_rows', 35),
        _count('stocked_weight_known_rows', 82),
        _count('stocked_weight_unknown_rows', 20),
        _count('stocked_weight_estimated_rows', 5),
      ],
    );

    expect(summary.weightCoverage, closeTo(82 / 102, 0.000001));
  });

  test('全未称覆盖率为零；无余额或统计缺失时没有可计算的覆盖率', () {
    final unknown = InstantInventorySummary(
      totalRows: 12,
      totals: [
        _count('stocked_weight_known_rows', 0),
        _count('stocked_weight_unknown_rows', 12),
        _count('weight_unknown_rows', 12),
        // 服务端 SUM 全 NULL 时省略 weight 项，仍下发未称计数。
      ],
    );
    final empty = InstantInventorySummary(
      totalRows: 137,
      totals: [
        _count('stocked_weight_known_rows', 0),
        _count('stocked_weight_unknown_rows', 0),
      ],
    );

    expect(unknown.weightCoverage, 0);
    expect(unknown.weightText(WeightDisplay.auto), '12 项未称');
    expect(empty.weightCoverage, isNull);
    expect(empty.weightText(WeightDisplay.auto), '统计暂不可用');
  });

  test('跨仓合计为正仍优先提示仓库负余额，零库存本身不生成缺货结论', () {
    final summary = InstantInventorySummary(
      totalRows: 137,
      totals: [
        _count('inventory_rows', 137),
        _count('zero_stock_rows', 35),
        _count('negative_stock_rows', 0),
        _count('negative_balance_rows', 2),
        _count('nonpositive_pending_stock_in_rows', 3),
        _count('stocked_weight_unknown_rows', 20),
      ],
    );

    expect(summary.advice.first.title, '优先核查负库存');
    expect(summary.advice.first.urgent, isTrue);
    expect(summary.advice.first.message, contains('2 处仓库余额为负'));
    expect(summary.headline, '优先核查负库存');
    expect(summary.advice.any((a) => a.title.contains('缺货')), isFalse);
    expect(summary.advice.map((a) => a.title), contains('优先确认合格待入库'));
  });
}

ReportTotal _count(String key, double value) => ReportTotal(
  key: key,
  label: key,
  type: 'count',
  groupKey: null,
  groups: [ReportTotalGroup(unit: null, value: value)],
);

ReportTotal _quantities(String key, Map<String?, double> values) => ReportTotal(
  key: key,
  label: key,
  type: key == 'weight' ? 'weight' : 'number',
  groupKey: key == 'weight' ? null : 'unit_name',
  groups: [
    for (final entry in values.entries)
      ReportTotalGroup(unit: entry.key, value: entry.value),
  ],
);
