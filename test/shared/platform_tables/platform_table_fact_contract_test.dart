import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/production/models/workshop_material_report_models.dart';
import 'package:uten_imp/platform_table_registry.dart';

void main() {
  test('typed raw fact keys remain inside the server formula whitelist', () {
    final server = File(
      'server/src/main/java/com/uten/imp/config/PlatformDisplayColumnsConfiguration.java',
    ).readAsStringSync();
    final facts = RegExp(
      r'new FactDefinition\("([^"]+)"\s*,\s*"[^"]*"\s*,\s*(true|false)\)',
    ).allMatches(server).map((match) => match.group(1)!).toSet();
    final typedSources = File(
      'lib/platform_table_display_facts.dart',
    ).readAsStringSync();
    final keys = RegExp(
      r"'([A-Za-z][A-Za-z0-9]*)'\s*:",
    ).allMatches(typedSources).map((match) => match.group(1)!).toSet();
    for (final path in [
      'lib/features/warehouse/widgets/warehouse_insight_tables.dart',
      'lib/features/warehouse/widgets/warehouse_sales_outbound_table_columns.dart',
    ]) {
      // External column factories are not visible from the table call site.
      // Check their actual numeric-source keys against the same server schema.
      for (final column in File(
        path,
      ).readAsStringSync().split('MasterColumnDef(').skip(1)) {
        if (!column.contains('exactValueOf:')) continue;
        final key = RegExp(
          r"key:\s*'([A-Za-z][A-Za-z0-9_]*)'",
        ).firstMatch(column)?.group(1);
        if (key != null) keys.add(key);
      }
    }
    expect(keys.length, greaterThan(100));
    expect(
      keys.difference(facts),
      isEmpty,
      reason:
          'A missing server fact makes the visible formula source unusable.',
    );
  });

  test(
    'account reconciliation uses exact JSON amounts beyond double precision',
    () {
      const exact = '9007199254740993.123456789012345678901234567890';
      final row = ReconciliationItem.fromJson({
        'id': 'statement-entry',
        'inAmount': 9007199254740992.0,
        'inAmountExact': exact,
        'outAmount': 0.1,
        'outAmountExact': '0.100000000000000000000000000001',
      });
      expect(platformDisplayFacts(row)['inAmount'], exact);
      expect(
        platformDisplayFacts(row)['outAmount'],
        '0.100000000000000000000000000001',
      );
      final legacy = ReconciliationItem.fromJson({
        'id': 'legacy',
        'inAmount': 9007199254740992.0,
      });
      expect(legacy.inAmount, isNotNull);
      expect(platformDisplayFacts(legacy)['inAmount'], isNull);
    },
  );

  test(
    'workshop cost calculations require exact authorized JSON companions',
    () {
      const exact = '9007199254740993.123456789012345678901234567890';
      final row = WmProductUsageRow.fromJson({
        'currentValue': 9007199254740992.0,
        'currentValueExact': exact,
        'unitMaterialCost': 0.1,
        'unitMaterialCostExact': '0.100000000000000000000000000001',
      });
      expect(platformDisplayFacts(row)['amount'], exact);
      expect(
        platformDisplayFacts(row)['unitCost'],
        '0.100000000000000000000000000001',
      );
      final legacy = WmProductUsageRow.fromJson({
        'currentValue': 123.45,
        'unitMaterialCost': 1.2,
      });
      expect(legacy.hasCost, isTrue);
      expect(platformDisplayFacts(legacy)['amount'], isNull);
      expect(platformDisplayFacts(legacy)['unitCost'], isNull);
      expect(
        platformDisplayFacts(WmProductUsageRow.fromJson({}))['amount'],
        isNull,
      );
    },
  );
}
