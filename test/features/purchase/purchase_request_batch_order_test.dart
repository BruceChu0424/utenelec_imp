import '../../support/native_detail_reader_overrides.dart';
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
    'gift-only demand remains selectable while physically fulfilled demand cannot generate again',
    (tester) async {
      final api = _RequestApi(
        customItems: [
          _giftLine(
            'gift-only',
            paidTarget: '10',
            declaredGift: '1',
            orderedPaid: '10',
            orderedGift: '0',
            paidRemaining: '0',
            giftRemaining: '1',
            physicalRemaining: '1',
          ),
          _giftLine(
            'fulfilled-by-gift',
            paidTarget: '10',
            declaredGift: '0',
            orderedPaid: '9',
            orderedGift: '1',
            paidRemaining: '0',
            giftRemaining: '0',
            physicalRemaining: '0',
          ),
        ],
      );
      String? selectedSources;
      await _pump(
        tester,
        api,
        _writePermissions,
        onOrder: (sources) => selectedSources = sources,
      );
      final finder = find.byType(MasterDataTableView<PurchaseDocItem>);
      await tester.tap(
        find.descendant(of: finder, matching: find.byType(Checkbox)).first,
      );
      await tester.pump();
      final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(finder);
      expect(table.selectedIds, {'gift-only'});
      final gift = table.items.first;
      expect(
        table.columns
            .singleWhere((c) => c.key == 'remainingOrderQty')
            .value(gift),
        '0 件',
      );
      expect(
        table.columns
            .singleWhere((c) => c.key == 'remainingGiftOrderQty')
            .value(gift),
        '1 件',
      );
      expect(
        table.columns
            .singleWhere((c) => c.key == 'physicalRemainingOrderQty')
            .value(gift),
        '1 件',
      );
      await tester.tap(
        find.byKey(const Key('purchase-request-generate-order')),
      );
      await tester.pumpAndSettle();
      expect(selectedSources, 'gift-only');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'request remaining table retains fourteen plus four digits and the smallest remaining quantity',
    (tester) async {
      final item = _giftLine(
        'precise',
        paidTarget: '99999999999999.9999',
        declaredGift: '0',
        orderedPaid: '99999999999999.9998',
        orderedGift: '0',
        paidRemaining: '0.0001',
        giftRemaining: '0',
        physicalRemaining: '0.0001',
      );
      await _pump(tester, _RequestApi(customItems: [item]), _writePermissions);
      final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(
        find.byType(MasterDataTableView<PurchaseDocItem>),
      );
      final line = table.items.single;
      expect(
        table.columns
            .singleWhere((c) => c.key == 'approvedOrderQty')
            .value(line),
        '99999999999999.9998 件',
      );
      expect(
        table.columns
            .singleWhere((c) => c.key == 'physicalApprovedOrderQty')
            .value(line),
        '99999999999999.9998 件',
      );
      expect(
        table.columns
            .singleWhere((c) => c.key == 'remainingOrderQty')
            .value(line),
        '0.0001 件',
      );
      expect(
        table.columns
            .singleWhere((c) => c.key == 'physicalRemainingOrderQty')
            .value(line),
        '0.0001 件',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'actual gift commitment blocks request editing and missing V1 physical authority blocks source selection',
    (tester) async {
      final giftCommitted = _giftLine(
        'gift-committed',
        paidTarget: '1',
        declaredGift: '0',
        orderedPaid: '0',
        orderedGift: '1',
        paidRemaining: '0',
        giftRemaining: '0',
        physicalRemaining: '0',
      );
      final missing = _giftLine(
        'missing-physical',
        paidTarget: '10',
        declaredGift: '1',
        orderedPaid: '0',
        orderedGift: '0',
        paidRemaining: '10',
        giftRemaining: '1',
        physicalRemaining: '11',
      )..remove('physicalRemainingQtyExact');
      await _pump(
        tester,
        _RequestApi(customItems: [giftCommitted, missing]),
        _writePermissions,
      );
      expect(
        find.byKey(const ValueKey('purchase-request-qty-gift-committed')),
        findsNothing,
      );
      final finder = find.byType(MasterDataTableView<PurchaseDocItem>);
      await tester.tap(
        find.descendant(of: finder, matching: find.byType(Checkbox)).first,
      );
      await tester.pump();
      final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(finder);
      expect(table.selectedIds, isEmpty);
      expect(find.text('实物剩余未核定'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
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
        ...nativeDetailReaderOverrides(),
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
  _RequestApi({this.customItems}) : super(Dio());
  final List<Map<String, dynamic>>? customItems;
  int detailReads = 0;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/units/dict')) {
      return [
        {'id': 'piece', 'name': '件'},
      ];
    }
    if (path.endsWith('/warehouses/dict')) {
      return [
        {'id': 'main', 'name': '主仓库'},
        {
          'id': 'child',
          'name': '材料区',
          'parentId': 'main',
          'parentName': '主仓库',
          'selectableForNew': true,
        },
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
      'items':
          customItems ??
          [
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

Map<String, dynamic> _giftLine(
  String id, {
  required String paidTarget,
  required String declaredGift,
  required String orderedPaid,
  required String orderedGift,
  required String paidRemaining,
  required String giftRemaining,
  required String physicalRemaining,
}) => {
  'id': id,
  'goodsId': id,
  'unitId': 'piece',
  'unitRate': 1,
  'rowVersion': 7,
  'quantitySemantics': 'CHARGED_PLUS_GIFT_V1',
  'qty': double.parse(paidTarget),
  'qtyExact': paidTarget,
  'giftQty': double.parse(declaredGift),
  'giftQtyExact': declaredGift,
  'orderedQty': double.parse(orderedPaid),
  'orderedQtyExact': orderedPaid,
  'pendingQty': 0,
  'pendingQtyExact': '0',
  'giftOrderedQtyExact': orderedGift,
  'pendingGiftQtyExact': '0',
  'remainingQty': double.parse(paidRemaining),
  'remainingQtyExact': paidRemaining,
  'remainingGiftQtyExact': giftRemaining,
  'physicalOrderedQtyExact': orderedGift == '1'
      ? orderedPaid == '0'
            ? '1'
            : '10'
      : orderedPaid,
  'physicalPendingQtyExact': '0',
  'physicalRemainingQtyExact': physicalRemaining,
};
