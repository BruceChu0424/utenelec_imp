import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/stock_ledger/stock_ledger_models.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/report/shared/report_cell.dart';
import 'package:uten_imp/features/report/shared/report_column.dart';
import 'package:uten_imp/shared/report/report_total.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';

void main() {
  const raw = '123456789012345678901234567890.123456789012345678901234';
  test(
    'stock read aliases prefer full original decimal string while estimates retain numeric compatibility',
    () {
      final row = InstantInventoryRow.fromJson({
        'weight': 1.2,
        'weightExact': raw,
        'unitWeightKg': '0.000000000000000000000001',
      });
      expect(row.weightText, raw);
      expect(row.unitWeightKgText, '0.000000000000000000000001');
      expect(
        BalanceRow.fromJson({
          'id': 'balance-fixture',
          'weight': raw,
        }).weightText,
        raw,
      );
      final line = StockLedgerRow.fromJson({
        'weightKgSigned': '-$raw',
        'balanceWeightKgAfter': raw,
      });
      expect(line.weightKgSignedText, '-$raw');
      expect(line.balanceWeightKgAfterText, raw);
      final summary = StockLedgerSummary.fromJson({
        'openingWeightKg': raw,
        'closingWeightKgExact': raw,
        'residualKg': '0.000000000000000000000001',
      });
      expect(summary.openingWeightKgText, raw);
      expect(summary.closingWeightKgText, raw);
      expect(summary.residualKgText, '0.000000000000000000000001');
    },
  );
  test(
    'report raw weight field and optional alias never round through num, also used by PDF loader',
    () {
      const col = ReportColumn(key: 'weight', label: '重量', type: 'weight');
      const expected =
          '123,456,789,012,345,678,901,234,567,890.123456789012345678901234 kg';
      expect(
        formatReportCell(col, {'weight': raw}, weightDisplay: WeightDisplay.kg),
        expected,
      );
      expect(
        formatReportCell(col, {
          'weight': 1.2,
          'weightExact': raw,
          'weightEstimated': true,
        }, weightDisplay: WeightDisplay.kg),
        '≈$expected',
      );
    },
  );
  test(
    'weight totals retain raw value and invalid fractional count companion is never rounded or hidden',
    () {
      final total = ReportTotal.fromJson({
        'key': 'weight',
        'label': '合计重量',
        'type': 'weight',
        'groups': [
          {'value': raw},
        ],
      });
      expect(
        reportTotalEntry(total, weightDisplay: WeightDisplay.kg).value,
        '123,456,789,012,345,678,901,234,567,890.123456789012345678901234 kg',
      );
      final companion = ReportTotal.fromJson({
        'key': 'weight_unknown_rows',
        'label': '原未称计数',
        'type': 'count',
        'groups': [
          {'value': '0.5'},
        ],
      });
      final entries = reportTotalEntries([
        total,
        companion,
      ], weightDisplay: WeightDisplay.kg);
      expect(entries, hasLength(2));
      expect(entries.last.value, '0.5');
    },
  );
}
