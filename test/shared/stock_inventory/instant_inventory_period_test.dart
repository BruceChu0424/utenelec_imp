import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/stock_inventory/instant_inventory_period_button.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/core/utils/date_range_defaults.dart';

void main() {
  for (final sample in [
    ('2026-11-03T16:00:00Z', '2026-10-04', '2026-11-04'),
    ('2026-11-03T15:59:59Z', '2026-10-03', '2026-11-03'),
    ('2026-03-31T04:00:00Z', '2026-02-28', '2026-03-31'),
    ('2024-03-31T04:00:00Z', '2024-02-29', '2024-03-31'),
    ('2026-01-05T04:00:00Z', '2025-12-05', '2026-01-05'),
  ]) {
    test('recent business month handles ${sample.$1}', () {
      final range = recentMonthDateRange(
        today: ChinaDateTime.today(utcNow: DateTime.parse(sample.$1)),
      );
      expect(inventoryPeriodDate(range.start), sample.$2);
      expect(inventoryPeriodDate(range.end), sample.$3);
      expect(range.start.isUtc, isTrue);
      expect(range.end.isUtc, isTrue);
    });
  }
}
