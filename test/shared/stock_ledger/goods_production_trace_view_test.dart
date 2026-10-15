import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/stock_ledger/production_trace_models.dart';
import 'package:uten_imp/shared/stock_ledger/widgets/goods_production_trace_view.dart';

Map<String, dynamic> _page({String kind = 'ORDER'}) => {
  'items': [
    {
      'id': 'demand1',
      'kind': kind,
      'quantityBasis': kind == 'ORDER' ? '实际领退料与核销' : '期间盘点耗用分摊',
      'planNo': 'SC001',
      'workshopName': '注塑车间',
      'product': {
        'goodsId': 'p1',
        'goodsName': '注塑件A',
        'goodsCode': 'P001',
        'unitName': '个',
      },
      'material': {
        'goodsId': 'm1',
        'goodsName': 'ABS塑料',
        'goodsCode': 'M001',
        'unitName': '千克',
      },
      'issuedQty': '8.0000',
      'returnedQty': 2,
      'consumedQty': kind == 'ORDER' ? 3 : null,
      'allocatedQty': kind == 'PERIODIC' ? 3 : null,
      'drawDocuments': <Object>[],
      'reports': [
        {
          'id': 'r1',
          'billNo': 'BG001',
          'billDate': '2026-10-14',
          'productQty': 50,
          'unitName': '个',
          'workers': [
            {'id': 'e1', 'name': '生产员工甲'},
          ],
        },
      ],
      'receiptSources': <Object>[],
    },
  ],
  'page': 1,
  'size': 50,
  'total': 1,
  'totalPages': 1,
};

class _TraceApi extends ApiClient {
  _TraceApi() : super(Dio());
  Map<String, dynamic> response = _page();
  final queries = <Map<String, dynamic>>[];
  final pending = <String, Completer<Map<String, dynamic>>>{};
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/production-trace')) {
      queries.add(Map.of(query!));
      return pending[query['direction']]?.future ?? response;
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

Future<void> _pump(WidgetTester tester, _TraceApi api) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.stockView,
          Perm.productionPlanView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        home: Scaffold(body: GoodsProductionTraceView(goodsId: 'g1')),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'tiny consumption and large report quantities retain every recorded digit',
    (tester) async {
      final api = _TraceApi();
      api.response = {
        'items': [
          {
            'id': 'exact',
            'kind': 'ORDER',
            'product': {
              'goodsId': 'p1',
              'goodsName': '精确数量产品',
              'unitName': '个',
            },
            'material': {'goodsId': 'm1', 'goodsName': '塑料', 'unitName': '千克'},
            'consumedQty': '0.00001',
            'reports': [
              {
                'id': 'r1',
                'billNo': 'BG001',
                'billDate': '2026-10-14',
                'productQty': '12345678901234.0001',
                'unitName': '个',
                'workers': <Object>[],
              },
            ],
            'receiptSources': [
              {
                'id': 'pr1',
                'billNo': 'CJ001',
                'billDate': '2026-10-13',
                'qty': '0.0000001',
                'sourceDocType': 'PURCHASE_RECEIPT',
              },
            ],
          },
        ],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
      await _pump(tester, api);
      await tester.pumpAndSettle();
      expect(find.text('0.00001 千克'), findsOneWidget);
      await tester.tap(find.text('精确数量产品'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('精确数量产品'));
      await tester.pumpAndSettle();
      expect(find.text('本任务产量：12345678901234.0001 个'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('入库分配量：0.0000001 千克'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('入库分配量：0.0000001 千克'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['account', 'endpoint']) {
    testWidgets(
      '$change change clears old facts and rejects its late response',
      (tester) async {
        final api = _TraceApi();
        final oldResponse = api.pending['usage'] =
            Completer<Map<String, dynamic>>();
        final nextResponse = Completer<Map<String, dynamic>>();
        const identity = AuthenticatedScope(userId: 'one');
        const permissions = {Perm.stockView, Perm.productionPlanView};
        final container = ProviderContainer(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            authenticatedScopeProvider.overrideWithValue(identity),
            currentPermissionsProvider.overrideWithValue(permissions),
            isSuperAdminProvider.overrideWithValue(false),
          ],
        );

        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: Scaffold(body: GoodsProductionTraceView(goodsId: 'g1')),
            ),
          ),
        );
        await tester.pump();
        final nextApi = change == 'endpoint' ? _TraceApi() : api;
        nextApi.pending['usage'] = nextResponse;
        container.updateOverrides([
          apiClientProvider.overrideWithValue(nextApi),
          authenticatedScopeProvider.overrideWithValue(
            change == 'account'
                ? const AuthenticatedScope(userId: 'two')
                : identity,
          ),
          currentPermissionsProvider.overrideWithValue(permissions),
          isSuperAdminProvider.overrideWithValue(false),
        ]);
        await tester.pump();
        nextResponse.complete(_page());
        await tester.pumpAndSettle();
        expect(find.text('注塑件A'), findsOneWidget);
        oldResponse.complete({
          'items': <Object>[],
          'page': 1,
          'total': 0,
          'totalPages': 1,
        });
        await tester.pumpAndSettle();
        expect(find.text('注塑件A'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.pump();
      },
    );
  }

  testWidgets(
    'revoked report permission clears facts and closes an open details panel',
    (tester) async {
      final api = _TraceApi();
      const identity = AuthenticatedScope(userId: 'one');
      const permissions = {
        Perm.stockView,
        Perm.productionPlanView,
        Perm.productionDailyReportView,
        Perm.stockDocView,
      };
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authenticatedScopeProvider.overrideWithValue(identity),
          currentPermissionsProvider.overrideWithValue(permissions),
          isSuperAdminProvider.overrideWithValue(false),
        ],
      );

      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: GoodsProductionTraceView(goodsId: 'g1')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('注塑件A'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('注塑件A'));
      await tester.pumpAndSettle();
      expect(find.text('全单参与人：生产员工甲'), findsOneWidget);
      final recheck = api.pending['usage'] = Completer<Map<String, dynamic>>();
      container.updateOverrides([
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWithValue(identity),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.stockView,
          Perm.productionPlanView,
          Perm.stockDocView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.text('全单参与人：生产员工甲'), findsNothing);
      recheck.complete({
        'items': <Object>[],
        'page': 1,
        'total': 0,
        'totalPages': 1,
      });
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pump();
    },
  );

  test(
    'period allocation and unknown measured consumption remain distinct',
    () {
      final row = GoodsProductionTraceRow.fromJson(
        (_page(kind: 'PERIODIC')['items'] as List).first
            as Map<String, dynamic>,
      );
      expect(row.isPeriodic, isTrue);
      expect(row.consumedQty, isNull);
      expect(row.allocatedQty, '3');
      expect(row.issuedQty, '8.0000');
      expect(row.returnedQty, '2');
      expect(row.receiptSources, isEmpty);
    },
  );

  testWidgets(
    'both directions use one table and expose separate production evidence',
    (tester) async {
      final api = _TraceApi();
      await _pump(tester, api);
      await tester.pumpAndSettle();
      expect(find.text('注塑件A'), findsOneWidget);
      expect(api.queries.single['direction'], 'usage');
      await tester.tap(find.text('注塑件A'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('注塑件A'));
      await tester.pumpAndSettle();
      expect(find.text('本任务产量：50 个'), findsOneWidget);
      expect(find.text('全单参与人：生产员工甲'), findsOneWidget);
      expect(find.textContaining('暂无可查看的入库来源分配'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('用了哪些物料'));
      await tester.pumpAndSettle();
      expect(api.queries.last['direction'], 'materials');
      expect(find.text('ABS塑料'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late usage response cannot replace newly selected material direction',
    (tester) async {
      final api = _TraceApi();
      final usage = api.pending['usage'] = Completer<Map<String, dynamic>>();
      final materials = api.pending['materials'] =
          Completer<Map<String, dynamic>>();
      await _pump(tester, api);
      await tester.tap(find.text('用了哪些物料'));
      await tester.pump();
      materials.complete(_page());
      await tester.pumpAndSettle();
      usage.complete({
        'items': <Object>[],
        'page': 1,
        'total': 0,
        'totalPages': 1,
      });
      await tester.pumpAndSettle();
      expect(find.text('ABS塑料'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
