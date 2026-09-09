import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

const _writePermissions = {
  Perm.purchaseRequestView,
  Perm.purchaseOrderCreate,
  Perm.purchaseOrderDecompose,
};

void main() {
  testWidgets(
    'names and warehouse path are readable; only selected available lines enter the order',
    (tester) async {
      final api = _RequestApi();
      String? orderSources;
      final router = await _pump(
        tester,
        api,
        _writePermissions,
        onOrder: (value) => orderSources = value,
      );
      expect(find.text('张计划'), findsOneWidget);
      expect(find.text('6654bc8f-8b1c-476a-b828-08c3c2c4697b'), findsNothing);
      expect(find.text('主仓库 - 材料区'), findsOneWidget);

      final table = find.byType(MasterDataTableView<PurchaseDocItem>);
      await tester.tap(
        find.descendant(of: table, matching: find.byType(Checkbox)).first,
      );
      await tester.pump();
      expect(
        tester.widget<MasterDataTableView<PurchaseDocItem>>(table).selectedIds,
        {'available', 'partly-approved'},
      );
      // Fully approved and financially occupied lines cannot be selected or have their request quantity edited.
      expect(
        find.byKey(const ValueKey('purchase-request-qty-finance-pending')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('purchase-request-qty-complete')),
        findsNothing,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(
            const ValueKey('purchase-request-row-partly-approved'),
          ),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pump();
      final action = find.byKey(const Key('purchase-request-generate-order'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(orderSources, 'available');
      expect(find.text('新订货单'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(api.detailReads, 2);
      expect(
        tester.widget<MasterDataTableView<PurchaseDocItem>>(table).selectedIds,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a read-only request has no selection or generation action', (
    tester,
  ) async {
    await _pump(tester, _RequestApi(), {Perm.purchaseRequestView});
    final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(
      find.byType(MasterDataTableView<PurchaseDocItem>),
    );
    expect(table.selectable, isFalse);
    expect(
      find.byKey(const Key('purchase-request-generate-order')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'warehouse names keep exact parent identity, including repeated child names',
    () {
      final names = MasterDictionaryService.warehouseDisplayNames(const [
        WarehouseDictEntry(id: 'north', name: '北仓'),
        WarehouseDictEntry(id: 'south', name: '南仓'),
        WarehouseDictEntry(id: 'n-material', name: '材料区', parentId: 'north'),
        WarehouseDictEntry(id: 's-material', name: '材料区', parentId: 'south'),
        WarehouseDictEntry(
          id: 'history',
          name: '旧区',
          parentId: 'hidden',
          parentName: '历史主仓',
        ),
      ]);
      expect(names['n-material'], '北仓 - 材料区');
      expect(names['s-material'], '南仓 - 材料区');
      expect(names['history'], '历史主仓 - 旧区');
    },
  );
}

Future<GoRouter> _pump(
  WidgetTester tester,
  _RequestApi api,
  Set<String> permissions, {
  ValueChanged<String?>? onOrder,
}) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/request',
    routes: [
      GoRoute(
        path: '/request',
        builder: (_, _) => const PurchaseDocDetailPage(
          docType: PurchaseDocType.request,
          id: 'request',
        ),
      ),
      GoRoute(
        path: '/purchase/orders/new',
        builder: (_, state) {
          onOrder?.call(state.uri.queryParameters['requestItemIds']);
          return const Scaffold(body: Text('新订货单'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        purchaseRepositoryProvider(
          PurchaseDocType.request,
        ).overrideWithValue(PurchaseRepository(api, PurchaseDocType.request)),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return router;
}

class _RequestApi extends ApiClient {
  _RequestApi() : super(Dio());
  int detailReads = 0;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/warehouses/dict')) {
      return [
        {'id': 'main', 'name': '主仓库'},
        {'id': 'child', 'name': '材料区', 'parentId': 'main', 'parentName': '主仓库'},
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.endsWith('/purchase/requests/request')) return {};
    detailReads++;
    return {
      'id': 'request',
      'billNo': 'CS20260908000001',
      'billDate': '2026-09-08',
      'status': 1,
      'closed': false,
      'productionLinked': true,
      'makerId': '00000000-0000-0000-0000-000000000001',
      'makerName': '制单员',
      'applicantId': '6654bc8f-8b1c-476a-b828-08c3c2c4697b',
      'applicantName': '张计划',
      'warehouseId': 'child',
      'items': [
        _line('available', 10.0001, 0, 0),
        _line('partly-approved', 10, 6, 0),
        _line('finance-pending', 10, 0, 10),
        _line('complete', 10, 10, 0),
      ],
    };
  }

  Map<String, dynamic> _line(
    String id,
    double qty,
    double ordered,
    double pending,
  ) => {
    'id': id,
    'goodsId': id,
    'qty': qty,
    'orderedQty': ordered,
    'pendingQty': pending,
    'remainingQty': qty - ordered - pending,
  };
}
