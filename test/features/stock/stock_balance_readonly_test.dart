import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/stock/widgets/stock_balance_detail_sheet.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';

class _WeightPrefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();
  @override
  void persist() {}
}

void main() {
  for (final allowed in [false, true]) {
    testWidgets('余额详情只读，${allowed ? '新盘点授权显示送审导航' : '旧调整核重权限不显示编辑按钮'}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      bool? navigate;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue({
              Perm.stockView,
              Perm.stockBalanceAdjust,
              Perm.stockWeightManage,
              if (allowed) Perm.stockCountSubmit,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            warehouseWeightUnitsPrefsProvider.overrideWith(_WeightPrefs.new),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    navigate = await showStockBalanceDetailSheet(
                      context: context,
                      balance: BalanceRow.fromJson({
                        'id': 'b1',
                        'qty': 17.5,
                        'weight': 3.25,
                        'weightEstimated': true,
                      }),
                      goodsName: '颗粒',
                      unitName: 'kg',
                      warehouseName: '原料仓',
                      colorName: '无色',
                      onViewMovements: () {},
                    );
                  },
                  child: const Text('打开详情'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      expect(find.text('库存余额详情'), findsOneWidget);
      expect(find.text('17.5'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('直接调整库存'), findsNothing);
      expect(find.text('核重'), findsNothing);
      if (allowed) {
        await tester.tap(find.byKey(const Key('stock-balance-open-count')));
        await tester.pumpAndSettle();
        expect(navigate, isTrue);
      } else {
        expect(find.byKey(const Key('stock-balance-open-count')), findsNothing);
      }
    });
  }
}
