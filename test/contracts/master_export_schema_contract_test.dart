@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The page tests assert real published headers against these schemas. Verify
// those expectations against their owning Java declarations as well, so a
// server rename/removal cannot leave a stale client-only allowlist passing.
void main() {
  test('all ten actual page export contracts track their owning server schemas', () {
    const owners = {
      'goods': 'goods/GoodsService',
      'clients': 'client/ClientService',
      'suppliers': 'supplier/SupplierService',
      'accounts': 'account/AccountService',
      'currencies': 'currency/CurrencyService',
      'colors': 'color/ColorService',
      'units': 'unit/UnitService',
      'moulds': 'mould/MouldService',
      'warehouses': 'warehouse/WarehouseService',
      'settlement_methods': 'referencemethod/ReferenceMethodService',
    };
    final pages = File(
      'test/features/basic_data/pages/master_complete_print_consumers_test.dart',
    ).readAsStringSync();
    final start = pages.indexOf('const exportColumns = {');
    final declarations = pages.substring(start, pages.indexOf('};', start));
    final expected = {
      for (final match in RegExp(
        r"'([^']+)'\s*:\s*'([^']*)'",
      ).allMatches(declarations))
        match[1]!: match[2]!.split(' ').toSet(),
    };
    final aliasSource = File(
      'server/src/main/java/com/uten/imp/common/export/ExportTableProjectionService.java',
    ).readAsStringSync();
    final aliases = {
      for (final match in RegExp(
        r'Map.entry\("([^"]+)",List.of\(([^)]+)\)\)',
      ).allMatches(aliasSource))
        match[1]!: RegExp(
          r'"([^"]+)"',
        ).allMatches(match[2]!).map((target) => target[1]!).toList(),
    };
    expect(expected.keys.toSet(), owners.keys.toSet());
    for (final entry in owners.entries) {
      final source = File(
        'server/src/main/java/com/uten/imp/features/master/${entry.value}.java',
      ).readAsStringSync();
      final keys = RegExp(
        r'new ExportColumn\("([^"]+)"',
      ).allMatches(source).map((match) => match[1]!).toSet();
      for (final alias in aliases.entries) {
        if (alias.value.any(keys.contains)) keys.add(alias.key);
      }
      expect(
        expected[entry.key],
        keys,
        reason:
            '${entry.key} page contract drifted from its owning Java export',
      );
    }
  });
}
