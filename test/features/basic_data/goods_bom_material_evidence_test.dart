import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _Repo extends Fake implements GoodsBomRepository {
  final requested = <String>[];
  final reads = <String, Completer<List<GoodsBomItem>>>{};
  bool controlled = false;
  int learningReads = 0;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    requested.add(goodsId);
    if (controlled) return (reads[goodsId] ??= Completer()).future;
    return const [];
  }

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async {
    learningReads++;
    return const GoodsBomLearningSummary(
      materialEvidence: [
        GoodsBomMaterialEvidence(
          source: 'PERIODIC_CHOICE',
          status: 'CONFIRMED',
          componentGoodsId: 'plastic',
          componentName: 'PC颗粒',
          colorName: '白色',
          unitName: '千克',
          sourceCount: 1,
        ),
      ],
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Repo repo,
  ValueNotifier<String> product,
) async {
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsBomRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue(const {}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: product,
            builder: (_, goodsId, child) => GoodsBomTab(
              goodsId: goodsId,
              canCreate: false,
              canEdit: false,
              canDelete: false,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets(
    'empty BOM automatically exposes recognized raw material and refreshes',
    (tester) async {
      final repo = _Repo();
      final product = ValueNotifier('A');
      addTearDown(product.dispose);
      await _pump(tester, repo, product);
      await tester.pumpAndSettle();
      expect(find.textContaining('已记录车间选料：PC颗粒 (白色)'), findsOneWidget);
      final prior = repo.learningReads;
      await tester.tap(find.byKey(const Key('goods-bom-refresh')));
      await tester.pumpAndSettle();
      expect(repo.learningReads, greaterThan(prior));
      await tester.tap(find.text('查看选料与结构'));
      await tester.pumpAndSettle();
      expect(find.text('PC颗粒'), findsOneWidget);
      expect(find.text('尚未加入 BOM'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late load for a previous product cannot replace the current BOM',
    (tester) async {
      final repo = _Repo()..controlled = true;
      final product = ValueNotifier('A');
      addTearDown(product.dispose);
      await _pump(tester, repo, product);
      product.value = 'B';
      await tester.pump();
      repo.reads['B']!.complete(const [
        GoodsBomItem(
          id: 'B-1',
          componentGoodsId: 'B-material',
          componentName: 'B的材料',
          qty: 2,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('B的材料'), findsOneWidget);
      repo.reads['A']!.complete(const [
        GoodsBomItem(
          id: 'A-1',
          componentGoodsId: 'A-material',
          componentName: 'A的材料',
          qty: 1,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('B的材料'), findsOneWidget);
      expect(find.text('A的材料'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
