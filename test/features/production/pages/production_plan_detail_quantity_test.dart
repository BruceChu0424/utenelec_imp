import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_plan_detail_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _QuantityNames extends MasterNameService {
  _QuantityNames(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => id ?? '—';
  @override
  String unit(String? id) => id == 'box' ? '箱' : '件';
}

class _QuantityApi extends ApiClient {
  _QuantityApi(this.items, {this.canApprove = false}) : super(Dio());
  final List<Map<String, Object?>> items;
  final bool canApprove;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/production/plans/quantity-plan'
      ? {
          'id': 'quantity-plan',
          'billNo': 'TEST-EXACT-PLAN',
          'billDate': '2026-10-11',
          'status': 0,
          'allowedActions': ['VIEW', if (canApprove) 'APPROVE'],
          'items': items,
        }
      : <String, dynamic>{};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

Future<void> _open(
  WidgetTester tester,
  List<Map<String, Object?>> items, {
  bool canApprove = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _QuantityApi(items, canApprove: canApprove);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(_QuantityNames(api)),
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionPlanView,
          if (canApprove) Perm.productionPlanApprove,
        }),
      ],
      child: const MaterialApp(
        home: ProductionPlanDetailPage(id: 'quantity-plan'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('production-plan-summary-hero')), findsOneWidget);
  final summary = find.byKey(const Key('production-plan-summary-hero'));
  expect(
    find.descendant(of: summary, matching: find.byType(Card)),
    findsOneWidget,
  );
  expect(
    find.byKey(const Key('production-plan-draft-product-summary')),
    findsNothing,
  );
  await tester.tap(find.descendant(of: summary, matching: find.text('查看更多')));
  await tester.pumpAndSettle();
  expect(
    find.descendant(
      of: summary,
      matching: find.byKey(const Key('production-plan-draft-product-summary')),
    ),
    findsOneWidget,
  );
}

void main() {
  testWidgets(
    'plan approval exposes only a decision without document amendment',
    (tester) async {
      await _open(tester, [
        {'id': 'item-1', 'goodsId': 'goods-1', 'unitId': 'piece', 'qty': 1},
      ], canApprove: true);
      expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
      expect(find.text('修改后审核'), findsNothing);
      expect(find.text('保存并审核'), findsNothing);
      expect(find.widgetWithText(UtenButton, '编辑'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final exact in ['12.1256', '0.0001', '99999999999999.9999']) {
    testWidgets('draft plan summary and hero retain exact quantity $exact', (
      tester,
    ) async {
      await _open(tester, [
        {
          'id': 'item-1',
          'goodsId': 'goods-1',
          'unitId': 'piece',
          'qty': double.parse(exact),
          'qtyExact': exact,
        },
      ]);
      expect(
        find.descendant(
          of: find.byKey(const Key('production-plan-draft-product-summary')),
          matching: find.textContaining('计划 $exact'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('production-plan-summary-hero')),
          matching: find.text('$exact 件'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('legacy numeric plan quantity keeps its available four digits', (
    tester,
  ) async {
    await _open(tester, [
      {'id': 'item-1', 'goodsId': 'goods-1', 'unitId': 'piece', 'qty': 1.2345},
    ]);
    expect(find.textContaining('计划 1.2345'), findsOneWidget);
    expect(find.text('1.2345 件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('plan same-unit total stays exact while other unit is separate', (
    tester,
  ) async {
    await _open(tester, [
      {
        'id': 'item-1',
        'goodsId': 'goods-1',
        'unitId': 'piece',
        'qtyExact': '99999999999999.1234',
      },
      {
        'id': 'item-2',
        'goodsId': 'goods-2',
        'unitId': 'piece',
        'qtyExact': '0.0001',
      },
      {
        'id': 'item-3',
        'goodsId': 'goods-3',
        'unitId': 'box',
        'qtyExact': '0.2002',
      },
    ]);
    expect(find.text('0.2002 箱 · 99999999999999.1235 件'), findsOneWidget);
    expect(
      find.textContaining('排产量 0.2002 箱 · 99999999999999.1235 件'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'missing plan quantity stays unknown rather than a fabricated zero',
    (tester) async {
      await _open(tester, [
        {'id': 'item-1', 'goodsId': 'goods-1', 'unitId': 'piece'},
      ]);
      expect(find.text('数量未留存 件'), findsOneWidget);
      expect(find.textContaining('计划 —'), findsOneWidget);
      expect(find.text('0 件'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
