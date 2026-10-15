import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';

void main() {
  for (final type in ['purchase', 'subcontract']) {
    test(
      '$type review upgrades column groups once and preserves preferences',
      () {
        final notifier = PlatformTableLayoutNotifier(
          'finance.procurement.review.$type.items',
        );
        const seed = PlatformTableLayout(
          order: [
            'goods',
            'remark',
            'taxRate',
            'exchangeRate',
            'amountLocal',
            'qty',
            'amountOriginal',
            'custom',
          ],
          widths: {'goods': 220, 'taxRate': 115},
          hidden: {'remark'},
          pinned: {'goods'},
          filters: {'goods': '铜'},
          sortColumn: 'qty',
          sortAscending: false,
          hasQueryPreferences: true,
        );
        final upgraded = notifier.decode(seed.toJson())!;
        expect(upgraded.order, [
          'goods',
          'qty',
          'amountOriginal',
          'exchangeRate',
          'amountLocal',
          'taxRate',
          'remark',
          'custom',
        ]);
        expect(upgraded.widths, seed.widths);
        expect(upgraded.hidden, seed.hidden);
        expect(upgraded.pinned, seed.pinned);
        expect(upgraded.filters, seed.filters);
        expect(upgraded.sortColumn, seed.sortColumn);
        expect(upgraded.sortAscending, isFalse);
        expect(upgraded.layoutVersion, 1);
        final customized = upgraded.copyWith(order: seed.order);
        expect(notifier.decode(customized.toJson())!.order, seed.order);
      },
    );
  }

  test('material handling only retires the previous oversized default width', () {
    final notifier = PlatformTableLayoutNotifier(
      'features.production.pages.material_analysis_material_table.MaterialAnalysisMaterialTableState._materialAnalysisTable.2',
    );
    const seed = PlatformTableLayout(
      order: ['goods', 'handle'],
      widths: {'goods': 340, 'handle': 250},
      hidden: {'goods'},
      pinned: {'handle'},
    );
    final upgraded = notifier.decode(seed.toJson())!;
    expect(upgraded.widths, {'goods': 340});
    expect(upgraded.order, seed.order);
    expect(upgraded.hidden, seed.hidden);
    expect(upgraded.pinned, seed.pinned);
    expect(upgraded.layoutVersion, 1);
    final customized = upgraded.copyWith(widths: {'handle': 180});
    expect(notifier.decode(customized.toJson())!.widths, {'handle': 180});
  });
}
