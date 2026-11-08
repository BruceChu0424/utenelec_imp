import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/procurement_review_column_layout.dart';

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
        expect(upgraded.filters, isEmpty);
        expect(upgraded.sortColumn, seed.sortColumn);
        expect(upgraded.sortAscending, isFalse);
        // a2054a2d0 raised the layout version to move currency after the
        // original amount; an upgraded layout is stamped with the current one.
        expect(upgraded.layoutVersion, financeProcurementReviewLayoutVersion);
        final customized = upgraded.copyWith(order: seed.order);
        expect(notifier.decode(customized.toJson())!.order, seed.order);

        // A version-1 layout only moves the former default currency placement
        // once; other preferences stay intact and a later custom order is kept.
        const v1 = PlatformTableLayout(
          order: ['goods', 'price', 'currency', 'amountOriginal', 'remark'],
          widths: {'goods': 220},
          hidden: {'remark'},
          pinned: {'goods'},
          layoutVersion: 1,
        );
        final moved = notifier.decode(v1.toJson())!;
        expect(moved.order, [
          'goods',
          'price',
          'amountOriginal',
          'currency',
          'remark',
        ]);
        expect(moved.widths, v1.widths);
        expect(moved.hidden, v1.hidden);
        expect(moved.pinned, v1.pinned);
        expect(moved.layoutVersion, financeProcurementReviewLayoutVersion);
        final reordered = moved.copyWith(order: v1.order);
        expect(notifier.decode(reordered.toJson())!.order, v1.order);
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
