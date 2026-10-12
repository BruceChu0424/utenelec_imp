import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/stock_check_prefill.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_edit_page.dart';
import 'package:uten_imp/features/warehouse/widgets/stock_grid_columns.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'arrival_weight_test_support.dart';

const maximum = '99999999999999.1234';

void main() {
  testWidgets(
    'approve-only shared reader edits the same creation columns with exact old value redline',
    (tester) async {
      final api = await _open(tester, StockDocType.otherOut);
      final grid = _grid(tester);
      final row = grid.controller.rows.first;
      expect(row.qty.text, maximum);
      expect(grid.columns.map((column) => column.key), contains('qty'));
      expect(grid.showAddRow, isFalse);
      expect(grid.showRowDelete, isFalse);
      row.qty.text = '99999999999999.1233';
      await tester.pump();
      final before = tester.widget<Text>(
        find.byKey(ValueKey('stock-review-before-qty-${row.hashCode}')),
      );
      expect(before.data, maximum);
      expect(before.style?.decoration, TextDecoration.lineThrough);
      await tester.tap(find.text('保存并审核'));
      await tester.pumpAndSettle();
      expect(api.savedPath, '${ApiEndpoints.stockDocsBase}/doc-1/review');
      expect(api.saved!['expectedSnapshot'], 'a' * 64);
      expect(api.saved!['approveNow'], isTrue);
      final doc = (api.saved!['document'] as Map).cast<String, dynamic>();
      final items = (doc['items'] as List).cast<Map<String, dynamic>>();
      expect(items.first['sourceItemId'], 'line-1');
      expect(items.first['qty'], '99999999999999.1233');
      expect(items.first['unitRate'], '1');
      expect(items[1]['qty'], '0.0001');
      expect(doc['warehouseId'], 'wh-1');
      expect(doc['billDate'], '2026-10-11');
      expect(api.ordinaryWrites, 0);
    },
  );

  testWidgets(
    'count reviewer keeps exact book and displays exact changed count before dedicated approval',
    (tester) async {
      final api = await _open(tester, StockDocType.check);
      final row = _grid(tester).controller.rows.single;
      expect(row.bookQty.text, maximum);
      expect(row.checkQty.text, '99999999999999.1233');
      row.checkQty.text = '99999999999999.1232';
      await tester.pump();
      final before = tester.widget<Text>(
        find.byKey(ValueKey('stock-review-before-checkQty-${row.hashCode}')),
      );
      expect(before.data, '99999999999999.1233');
      expect(before.style?.decoration, TextDecoration.lineThrough);
      expect(row.surplusQtyText, '-0.0002');
      await tester.tap(find.text('保存并审核'));
      await tester.pumpAndSettle();
      final doc = (api.saved!['document'] as Map).cast<String, dynamic>();
      final item = (doc['items'] as List).cast<Map<String, dynamic>>().single;
      expect(item['sourceItemId'], 'line-1');
      expect(item['qty'], maximum);
      expect(item['countQty'], '99999999999999.1232');
      expect(item['surplusQty'], '-0.0002');
      expect(api.ordinaryWrites, 0);
    },
  );

  testWidgets(
    'server stale review refuses approval and retains the edited page without ordinary fallback',
    (tester) async {
      final api = await _open(tester, StockDocType.otherOut);
      api.rejectSave = true;
      _grid(tester).controller.rows.first.qty.text = '1.0001';
      await tester.pump();
      await tester.tap(find.text('保存并审核'));
      await tester.pumpAndSettle();
      expect(find.byType(StockDocEditPage), findsOneWidget);
      expect(api.ordinaryWrites, 0);
      expect(_grid(tester).controller.rows.first.qty.text, '1.0001');
      expect(find.textContaining('草稿已变化'), findsOneWidget);
    },
  );
}

UtenEditableGrid<StockGridRow> _grid(WidgetTester tester) =>
    tester.widget(find.byType(UtenEditableGrid<StockGridRow>));

Future<_Api> _open(
  WidgetTester tester,
  StockDocType type, {
  bool create = false,
  bool missingBalance = false,
}) async {
  tester.view.physicalSize = const Size(2000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _Api(type, missingBalance: missingBalance);
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Text('仓库')),
      GoRoute(
        path: '/edit',
        builder: (_, _) => StockDocEditPage(
          docType: type,
          id: create ? null : 'doc-1',
          reviewMode: true,
        ),
      ),
      GoRoute(
        path: '/warehouse/:code/:id',
        builder: (_, _) => const Text('已保存详情'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.stockDocView,
          Perm.stockDocApprove,
          Perm.stockCountFinanceReview,
        }),
        documentScopeCapabilityProvider.overrideWith(
          (ref, scope) async => DocumentScopeCapability(
            scope: scope.apiValue,
            writeAll: false,
            writableOwnerIds: const {},
          ),
        ),
        ...warehouseWeightTestOverrides(api),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => Stack(
          children: [
            child!,
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppNotificationHost(useSafeArea: false),
            ),
          ],
        ),
      ),
    ),
  );
  router.push(
    '/edit',
    extra: create
        ? const StockCheckPrefill(
            warehouseId: 'wh-1',
            lines: [StockCheckPrefillLine(goodsId: 'goods-1')],
          )
        : null,
  );
  await tester.pumpAndSettle();
  return api;
}

class _Api extends ApiClient {
  _Api(this.type, {this.missingBalance = false}) : super(Dio());
  final StockDocType type;
  final bool missingBalance;
  Map<String, dynamic>? saved;
  String? savedPath;
  int ordinaryWrites = 0;
  bool rejectSave = false;
  Map<String, dynamic> get detail => {
    'id': 'doc-1',
    'docType': type.code,
    'billDate': '2026-10-11',
    'warehouseId': 'wh-1',
    'makerId': 'maker-1',
    'status': 0,
    'canEdit': true,
    'items': [
      {
        'id': 'line-1',
        'goodsId': 'goods-1',
        'unitId': 'piece',
        'unitRate': 1,
        'warehouseId': 'wh-1',
        'qty': double.parse(maximum),
        'qtyExact': maximum,
        if (type == StockDocType.check) ...{
          'countQty': double.parse('99999999999999.1233'),
          'countQtyExact': '99999999999999.1233',
        },
      },
      if (type != StockDocType.check)
        {
          'id': 'line-2',
          'goodsId': 'goods-2',
          'unitId': 'piece',
          'unitRate': 1,
          'warehouseId': 'wh-1',
          'qty': 0.0001,
          'qtyExact': '0.0001',
        },
    ],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '${ApiEndpoints.stockDocsBase}/doc-1/review') {
      return {'snapshot': 'a' * 64, 'detail': detail};
    }
    if (path == '${ApiEndpoints.stockDocsBase}/doc-1') return detail;
    if (path == ApiEndpoints.stockBalances) {
      return {
        'items': [
          {
            'id': 'balance-1',
            'warehouseId': 'wh-1',
            'goodsId': 'goods-1',
            'qty': missingBalance ? null : double.parse(maximum),
            'qtyExact': missingBalance ? null : maximum,
          },
        ],
        'page': 1,
        'size': 100,
        'total': 1,
      };
    }
    return const {'items': <Object>[], 'page': 1, 'size': 1, 'total': 0};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehousesDict) {
      return const [
        {'id': 'wh-1', 'name': '实际仓', 'selectableForNew': true},
      ];
    }
    if (path == ApiEndpoints.unitsDict) {
      return const [
        {'id': 'piece', 'name': '件'},
      ];
    }
    if (path == ApiEndpoints.goodsLookup) {
      return const [
        {'id': 'goods-1', 'name': '物料一', 'code': 'M1', 'unitId': 'piece'},
        {'id': 'goods-2', 'name': '物料二', 'code': 'M2', 'unitId': 'piece'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    savedPath = path;
    if (!path.endsWith('/review')) ordinaryWrites++;
    saved = Map<String, dynamic>.from(body! as Map);
    if (rejectSave) {
      throw ApiException(
        'CONFLICT',
        '草稿已变化，请重新读取',
        httpStatus: 409,
        hasResponseCode: true,
      );
    }
    return detail;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.stockDocsBase) {
      saved = Map<String, dynamic>.from(body! as Map);
      return detail;
    }
    return const {};
  }
}
