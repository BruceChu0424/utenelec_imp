import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/features/report/shared/report_total.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/stock_ledger/widgets/goods_stock_inventory_overview.dart';

void main() {
  for (final held in [false, true]) {
    testWidgets(
      'goods overview preserves book data and hold on a later color: $held',
      (tester) async {
        final rows = [
          const InstantInventoryRow(
            goodsId: 'g',
            name: '主档',
            unitName: 'kg',
            qty: 5,
            moreQty: 12,
          ),
          InstantInventoryRow(
            goodsId: 'g',
            colorId: 'later-color',
            unitName: 'kg',
            qty: 12,
            measurementPending: held,
            measurementHoldReason: held
                ? 'LEGACY_QUANTITY_BASIS_UNPROVEN'
                : null,
          ),
        ];
        final data = PagedResult<InstantInventoryRow>(
          items: rows,
          page: 1,
          size: 20,
          total: 2,
          totalPages: 1,
          totals: const [
            ReportTotal(
              key: 'qty',
              label: '合计库存数量',
              type: 'number',
              groupKey: 'unit_name',
              groups: [ReportTotalGroup(unit: 'kg', value: 17)],
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GoodsStockInventoryOverview(
                data: data,
                loading: false,
                error: null,
                onRetry: () {},
                weightDisplay: WeightDisplay.auto,
              ),
            ),
          ),
        );
        final bar = tester.widget<UtenTotalsSummaryBar>(
          find.byType(UtenTotalsSummaryBar),
        );
        if (held) {
          expect(find.textContaining('历史计量待核'), findsWidgets);
          expect(find.textContaining('账面数仅核对'), findsWidgets);
          expect(find.text('基本单位：kg'), findsNothing);
          expect(
            bar.entries.where((entry) => entry.label == '合计库存数量'),
            isEmpty,
          );
        } else {
          // Master facts live above this footer. The server's scoped total
          // still proves the stock quantity and its own unit independently.
          expect(find.text('基本单位：kg'), findsNothing);
          expect(find.textContaining('历史计量待核'), findsNothing);
          expect(
            bar.entries.where((entry) => entry.label == '合计库存数量'),
            hasLength(1),
          );
          expect(
            bar.entries.singleWhere((entry) => entry.label == '合计库存数量').value,
            '17 kg',
          );
        }
        expect(find.text('多排数量（全局生产计划·无颜色）：12.0（计划行单位）'), findsOneWidget);
        expect(find.textContaining('12 kg'), findsNothing);
        expect(data.items.first.moreQty, 12);
        expect(data.items.last.qty, 12);
        expect(data.totals.single.groups.single.value, 17);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
