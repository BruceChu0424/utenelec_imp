// 产品配件清单预览(ADR-129)：14 列，「设计使用数量」与只读「真实使用数量」
// 并列；没有真实数据显示「—」，数字固定 6 位去尾零(无浮点噪声)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_preview.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _PreviewRepo extends Fake implements GoodsBomRepository {
  @override
  Future<List<GoodsBomItem>> list(String goodsId) async => switch (goodsId) {
    'goods-a' => const [
      GoodsBomItem(
        id: 'row-1',
        componentGoodsId: 'plastic',
        componentCode: 'P01',
        componentName: '塑料',
        qty: 0.1,
        actual: BomActualUsage(
          qty: 0.10500000000000001,
          status: BomActualStatus.actual,
          usesActual: true,
        ),
      ),
      GoodsBomItem(
        id: 'row-2',
        componentGoodsId: 'box',
        componentCode: 'B01',
        componentName: '纸箱',
        qty: 1,
        consumptionBasis: BomConsumptionBasis.perPackage,
        basisOutputQty: 50,
        allowPartialPackage: false,
        actual: BomActualUsage(status: BomActualStatus.notLinear),
      ),
    ],
    _ => const [],
  };
}

void main() {
  testWidgets('preview lists design and actual usage side by side', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          goodsBomRepositoryProvider.overrideWithValue(_PreviewRepo()),
          currentPermissionsProvider.overrideWithValue(const {}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showGoodsBomPreview(context: context, goodsId: 'goods-a'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('设计使用数量'), findsOneWidget);
    expect(find.text('真实使用数量'), findsOneWidget);
    expect(find.text('数量'), findsNothing);
    // 表头 14 列。
    final header = tester.widgetList<Table>(find.byType(Table)).last;
    expect(header.children.first.children, hasLength(14));
    // 塑料：真实 0.105(无浮点噪声)；纸箱：整包不适用 → 「—」，尾包「整包」。
    expect(find.text('0.105'), findsOneWidget);
    expect(find.text('0.10500000000000001'), findsNothing);
    expect(find.text('整包'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
