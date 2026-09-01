import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_edit_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_page.dart';

void main() {
  testWidgets('shared task table uses single selection and double-click open', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _OutboundTaskApi();
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(api: api, router: router));
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.selectable, isFalse);
    expect(table.batchActionsBuilder, isNull);
    expect(
      table.columns.map((column) => column.label),
      containsAll(<String>['任务状态', '委外订货单', '委外商', '交货日期', '目标件行数', '出仓草稿单']),
    );
    final labels = table.columns.map((column) => column.label);
    for (final mixedUnitTotal in const ['目标件总量', '当前可出仓', '目标件已出仓', '订单未出仓']) {
      expect(
        labels,
        isNot(contains(mixedUnitTotal)),
        reason: 'mixed goods units must not be summed at task level',
      );
    }
    final menu = table.rowMenuBuilder!(table.items.first);
    expect(menu, hasLength(1));
    expect((menu.single as UtenMenuItem).label, '进入目标件拣货出仓');
    expect(find.text('共 3 项 · 单击选中，双击详情'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);

    await tester.tap(find.text('WW202608300001'));
    await tester.pump();
    expect(
      router.routeInformationProvider.value.uri.path,
      RouteName.warehouseSubcontractOutbound,
    );

    await tester.pump(const Duration(milliseconds: 400));
    await _doubleTapRow(tester, find.text('WW202608300001'));
    await tester.pumpAndSettle();
    expect(find.text('detail-plan-1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('complete-outbound-task')));
    await tester.pumpAndSettle();
    expect(api.taskRequests, 2);
    expect(find.text('委外出仓任务中心'), findsOneWidget);
  });

  testWidgets(
    'compact layout stays a table and keeps search pager error states',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _OutboundTaskApi();
      final router = _router();
      addTearDown(router.dispose);

      await tester.pumpWidget(_app(api: api, router: router));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('subcontract-outbound-task-table')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      final searchField = find.descendant(
        of: find.byKey(const Key('subcontract-outbound-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(searchField, 'missing');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(api.taskQueries.last['keyword'], 'missing');
      expect(find.text('没有匹配「missing」的出仓任务'), findsOneWidget);

      await tester.enterText(searchField, '');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      _table(tester).onPageChange!(2);
      await tester.pumpAndSettle();
      expect(api.taskQueries.last['page'], 2);
      expect(find.text('WW202608300003'), findsOneWidget);

      api.failNext = true;
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      expect(find.text('委外出仓任务加载失败，请检查网络后重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('two pending drafts load only the selected draft lines', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _MultiDraftOutboundApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: const MaterialApp(
          home: Scaffold(
            body: WarehouseSubcontractOutboundEditPage(planId: 'plan-multi'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.loadedDraftIds, ['draft-b']);
    expect(find.text('ITEM-B 当前草稿目标件'), findsOneWidget);
    expect(find.text('ITEM-A 其它仓草稿目标件'), findsNothing);
    final qty = tester.widget<TextField>(
      find.widgetWithText(TextField, '本次出仓'),
    );
    expect(qty.controller?.text, '3');
    expect(tester.takeException(), isNull);
  });
}

Widget _app({required _OutboundTaskApi api, required GoRouter router}) {
  return ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(api)],
    child: MaterialApp.router(routerConfig: router),
  );
}

GoRouter _router() {
  return GoRouter(
    initialLocation: RouteName.warehouseSubcontractOutbound,
    routes: [
      GoRoute(
        path: RouteName.warehouseSubcontractOutbound,
        builder: (_, _) => const WarehouseSubcontractOutboundPage(),
      ),
      GoRoute(
        path: '/warehouse/subcontract-outbound/:planId',
        builder: (context, state) => Scaffold(
          body: Column(
            children: [
              Text('detail-${state.pathParameters['planId']}'),
              FilledButton(
                key: const Key('complete-outbound-task'),
                onPressed: () => context.pop(true),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

MasterDataTableView<OutboundTask> _table(WidgetTester tester) {
  return tester.widget<MasterDataTableView<OutboundTask>>(
    find.byWidgetPredicate(
      (widget) => widget is MasterDataTableView<OutboundTask>,
    ),
  );
}

Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tap(finder);
}

class _OutboundTaskApi extends ApiClient {
  _OutboundTaskApi() : super(Dio());

  final List<Map<String, dynamic>> taskQueries = [];
  int taskRequests = 0;
  bool failNext = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.warehouseSubcontractOutboundTasks) {
      throw StateError('Unexpected GET $path');
    }
    taskRequests++;
    taskQueries.add(Map<String, dynamic>.from(query ?? const {}));
    if (failNext) {
      failNext = false;
      throw StateError('offline');
    }

    final page = (query?['page'] as num?)?.toInt() ?? 1;
    final keyword = query?['keyword']?.toString();
    if (keyword == 'missing') {
      return const {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 1,
      };
    }
    final items = page == 1
        ? <Map<String, dynamic>>[_task(1, hasDraft: true), _task(2)]
        : <Map<String, dynamic>>[_task(3, hasDraft: true)];
    return {
      'items': items,
      'page': page,
      'size': 20,
      'total': 3,
      'totalPages': 2,
    };
  }
}

class _MultiDraftOutboundApi extends ApiClient {
  _MultiDraftOutboundApi() : super(Dio());

  final List<String> loadedDraftIds = [];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehouseSubcontractOutboundTask('plan-multi')) {
      return {
        'planId': 'plan-multi',
        'orderId': 'order-multi',
        'orderBillNo': 'WW-MULTI',
        'status': 'OPEN',
        'supplierId': 'supplier-1',
        'supplierName': '委外商',
        'deliverDate': '2026-09-01',
        'lines': [
          _outboundLine(
            planItemId: 'plan-item-a',
            orderItemId: 'order-item-a',
            goodsId: 'goods-a',
            goodsCode: 'ITEM-A',
            goodsName: '其它仓草稿目标件',
            draftReservedQty: 5,
          ),
          _outboundLine(
            planItemId: 'plan-item-b',
            orderItemId: 'order-item-b',
            goodsId: 'goods-b',
            goodsCode: 'ITEM-B',
            goodsName: '当前草稿目标件',
            draftReservedQty: 3,
          ),
        ],
        'drafts': const [
          {
            'issueId': 'draft-a',
            'billNo': 'EC-A',
            'status': 0,
            'warehouseName': 'A 仓',
            'totalQty': 5,
          },
          {
            'issueId': 'draft-b',
            'billNo': 'EC-B',
            'status': 0,
            'warehouseName': 'B 仓',
            'totalQty': 3,
          },
        ],
      };
    }
    if (path == '/subcontract/material-issues/draft-b') {
      loadedDraftIds.add('draft-b');
      return const {
        'id': 'draft-b',
        'billNo': 'EC-B',
        'billDate': '2026-08-30',
        'warehouseId': 'warehouse-b',
        'status': 0,
        'items': [
          {
            'id': 'draft-item-b',
            'planItemId': 'plan-item-b',
            'orderItemId': 'order-item-b',
            'goodsId': 'goods-b',
            'qty': 3,
            'weight': 1.5,
          },
        ],
      };
    }
    throw StateError('Unexpected GET $path');
  }
}

Map<String, dynamic> _outboundLine({
  required String planItemId,
  required String orderItemId,
  required String goodsId,
  required String goodsCode,
  required String goodsName,
  required num draftReservedQty,
}) => {
  'planItemId': planItemId,
  'orderItemId': orderItemId,
  'goodsId': goodsId,
  'goodsCode': goodsCode,
  'goodsName': goodsName,
  'plannedQty': 10,
  'issuedQty': 0,
  'draftReservedQty': draftReservedQty,
  'flowMode': 'DIRECT_OUTBOUND',
  'preparationStatus': 'READY_OUTBOUND',
  'preparedQty': 10,
  'readyOutboundQty': 0,
  'remainingQty': 10,
  'allowedActions': const ['HANDLE_OUTBOUND'],
};

Map<String, dynamic> _task(int index, {bool hasDraft = false}) => {
  'planId': 'plan-$index',
  'orderId': 'order-$index',
  'orderBillNo': 'WW20260830000$index',
  'supplierName': '委外商$index',
  'deliverDate': '2026-09-0$index',
  'lineCount': index + 1,
  'plannedQty': 100 * index,
  'issuedQty': 20 * index,
  'remainingQty': 80 * index,
  'draftId': hasDraft ? 'draft-$index' : null,
  'draftBillNo': hasDraft ? 'WCF20260830000$index' : null,
};
