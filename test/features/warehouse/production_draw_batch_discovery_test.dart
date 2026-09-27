import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/production_draw_discovery_row.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_draw_task.dart';
import 'package:uten_imp/features/warehouse/pages/production_draw_batch_issue_page.dart';
import 'package:uten_imp/features/warehouse/repositories/production_draw_task_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/production_material_discovery_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/production_draw_detail_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/production_material_discovery.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _plastic = <String, dynamic>{
  'goodsId': 'plastic',
  'goodsName': '塑料颗粒',
  'goodsCode': 'P01',
  'colorId': 'white',
  'colorName': '白色',
  'unitId': 'kg',
  'unitName': '千克',
  'spec': 'PC-ABS',
  'stockPlace': 'A-01',
  'qty': null,
};

ProductionMaterialDiscoveryDetail _request(
  String id, {
  List<Map<String, dynamic>>? items,
  String status = 'PENDING',
}) => ProductionMaterialDiscoveryDetail.fromJson({
  'requestId': id,
  'requestNo': 'LQ-$id',
  'segmentId': 'segment-$id',
  'segmentCode': 'ZX-$id',
  'planNo': 'SJ-$id',
  'productCode': 'SHELL',
  'productName': '外壳',
  'plannedQty': 3000,
  'productUnitName': '个',
  'workshopName': '注塑车间',
  'status': status,
  'version': 7,
  'suggestedItems': items ?? [_plastic],
});

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '常规原料';
  @override
  String warehouse(String? id) => '常规仓';
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'w1', name: '原料仓一'),
    WarehouseDictEntry(id: 'w2', name: '原料仓二'),
  ];
}

class _StockRepository extends StockDocRepository {
  _StockRepository() : super(ApiClient(Dio()), StockDocType.draw);
  @override
  Future<StockDocDetail> detail(String id) async => StockDocDetail(
    id: id,
    docType: 'DRAW',
    billNo: 'SL-$id',
    materialRequestNo: 'LQ-normal-source',
    status: 1,
    warehouseId: 'normal-warehouse',
    departmentId: 'workshop',
    planNo: 'SJ-normal',
    items: [
      StockDocItem(
        id: 'item-$id',
        goodsId: 'normal',
        unitId: 'kg',
        qty: 10,
        requestedQty: 8,
        issuedQty: 3,
      ),
    ],
  );
}

class _DiscoveryRepository extends ProductionMaterialDiscoveryRepository {
  _DiscoveryRepository() : super(ApiClient(Dio()));
  final values = <String, ProductionMaterialDiscoveryDetail>{};
  @override
  Future<ProductionMaterialDiscoveryDetail> detail(String id) async =>
      values[id] ?? _request(id);
}

class _Tasks extends ProductionDrawTaskRepository {
  _Tasks() : super(ApiClient(Dio()));
  final submissions = <Map<String, dynamic>>[];
  int ordinaryCalls = 0;
  Object? failure;
  @override
  Future<WarehouseDrawBatchIssueResult> issueDiscoveryBatch({
    required String idempotencyKey,
    required List<String> docIds,
    required List<Map<String, dynamic>> discoveries,
    String? reason,
  }) async {
    submissions.add(
      Map<String, dynamic>.from(
        jsonDecode(
              jsonEncode({
                'key': idempotencyKey,
                'docIds': docIds,
                'discoveries': discoveries,
                'reason': reason,
              }),
            )
            as Map,
      ),
    );
    if (failure != null) throw failure!;
    return WarehouseDrawBatchIssueResult(
      issuedCount: docIds.length + discoveries.length,
      skippedCount: 0,
      replayedCount: 0,
      replayed: false,
      issuedDocNos: const [],
    );
  }

  @override
  Future<WarehouseDrawBatchIssueResult> issueFullBatch({
    required String idempotencyKey,
    required List<String> docIds,
    String? reason,
  }) async {
    ordinaryCalls++;
    return WarehouseDrawBatchIssueResult(
      issuedCount: docIds.length,
      skippedCount: 0,
      replayedCount: 0,
      replayed: false,
      issuedDocNos: const [],
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Tasks tasks, {
  List<String> docs = const ['normal'],
  List<String> requests = const ['request'],
  _DiscoveryRepository? discoveryRepository,
  bool approve = true,
  bool issue = true,
  Size size = const Size(1900, 1000),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () => context.push('/batch'),
            child: const Text('打开批量'),
          ),
        ),
      ),
      GoRoute(
        path: '/batch',
        builder: (_, _) => ProductionDrawBatchIssuePage(
          documentIds: docs,
          discoveryRequestIds: requests,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.stockDocView,
          if (approve) Perm.stockDocApprove,
          if (issue) Perm.stockDocIssue,
        }),
        masterNameServiceProvider.overrideWithValue(_Names()),
        productionDrawTaskRepositoryProvider.overrideWithValue(tasks),
        productionMaterialDiscoveryRepositoryProvider.overrideWithValue(
          discoveryRepository ?? _DiscoveryRepository(),
        ),
        stockDocRepositoryProvider(
          StockDocType.draw,
        ).overrideWithValue(_StockRepository()),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: Stack(
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
    ),
  );
  await tester.tap(find.text('打开批量'));
  await tester.pumpAndSettle();
}

ProductionDrawDetailTable _table(WidgetTester tester) => tester
    .widget<ProductionDrawDetailTable>(find.byType(ProductionDrawDetailTable));
Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('warehouse-draw-batch-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'stock detail keeps the material request number separate from the formal document and legacy source',
    () {
      final detail = StockDocDetail.fromJson({
        'id': 'draw',
        'docType': 'DRAW',
        'billNo': 'SL000001',
        'materialRequestNo': 'LQ000001',
        'sourceDocNo': 'ZX000001',
      });
      expect(detail.billNo, 'SL000001');
      expect(detail.materialRequestNo, 'LQ000001');
      expect(detail.sourceDocNo, 'ZX000001');
      expect(
        StockDocDetail.fromJson({'id': 'legacy'}).materialRequestNo,
        isNull,
      );
    },
  );
  test(
    'discovery rows require exact positive quantities and a physical warehouse',
    () {
      final row = ProductionDrawDiscoveryRow(
        request: _request('r'),
        index: 0,
        initial: _plastic,
      );
      addTearDown(row.dispose);
      for (final input in ['', '0', '-1', 'NaN', '1.00001', '1e3']) {
        row.quantity.text = input;
        expect(row.quantityError, isNotNull, reason: input);
      }
      row.quantity.text = '12.7500';
      expect(row.quantityError, isNull);
      row.values['warehouseId'] = '  ';
      expect(row.warehouseError, isNotNull);
      row.values['warehouseId'] = 'w1';
      expect(row.validationError, isNull);
      expect(row.toJson()['qty'], '12.7500');
    },
  );
  test(
    'normal DRAW quantity guard still uses remaining requested quantity',
    () {
      const item = StockDocItem(
        id: 'line',
        qty: 10,
        requestedQty: 8,
        issuedQty: 3,
      );
      const row = ProductionDrawDetailRow(StockDocDetail(id: 'normal'), item);
      expect(drawIssueQtyError(row, '5'), isNull);
      expect(drawIssueQtyError(row, '5.1'), '不能超过待出库 5.0');
      expect(drawIssueQtyError(row, '0'), '出库数量需大于 0');
    },
  );
  testWidgets(
    'mixed batch reads one shared table without inventing quantity from the parent production plan',
    (tester) async {
      final tasks = _Tasks();
      await _pump(tester, tasks);
      final shared = _table(tester);
      expect(shared.documents.single.items.single.remainingQty, 5);
      expect(shared.discoveryRows.single.quantity.text, isEmpty);
      final table = tester.widget<MasterDataTableView<ProductionDrawDetailRow>>(
        find.byKey(const Key('production-draw-detail-table')),
      );
      expect(table.items, hasLength(2));
      expect(table.items.last.document, isNull);
      final billNo = table.columns.firstWhere(
        (column) => column.key == 'billNo',
      );
      final requestNo = table.columns.firstWhere(
        (column) => column.key == 'materialRequestNo',
      );
      expect(billNo.value(table.items.first), 'SL-normal');
      expect(requestNo.value(table.items.first), 'LQ-normal-source');
      expect(billNo.value(table.items.last), '—');
      expect(requestNo.value(table.items.last), 'LQ-request');
      expect(find.text('待生成领料单'), findsNothing);
      final qty = tester.widget<TextField>(
        find.byKey(
          ValueKey('draw-discovery-qty-${shared.discoveryRows.single.id}'),
        ),
      );
      expect(qty.decoration!.enabledBorder, isA<OutlineInputBorder>());
      expect(shared.discoveryRows.single.values['warehouseId'], isNull);
      expect(tasks.submissions, isEmpty);
      expect(tasks.ordinaryCalls, 0);
      await _submit(tester);
      expect(tasks.submissions, isEmpty);
      expect(find.textContaining('请填写本次领料数量'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'warehouse fills missing quantity and actual leaf warehouse then submits a single atomic mixed payload',
    (tester) async {
      final tasks = _Tasks();
      await _pump(tester, tasks);
      final row = _table(tester).discoveryRows.single;
      await tester.enterText(
        find.byKey(ValueKey('draw-discovery-qty-${row.id}')),
        '12.7500',
      );
      await tester.tap(
        find.byKey(ValueKey('draw-discovery-warehouse-${row.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('原料仓二'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('warehouse-draw-batch-remark')),
        '夜班发料',
      );
      await _submit(tester);
      expect(tasks.ordinaryCalls, 0);
      expect(tasks.submissions.single['docIds'], ['normal']);
      expect(tasks.submissions.single['reason'], '夜班发料');
      expect(tasks.submissions.single['discoveries'], [
        {
          'requestId': 'request',
          'expectedVersion': 7,
          'items': [
            {
              'goodsId': 'plastic',
              'colorId': 'white',
              'unitId': 'kg',
              'warehouseId': 'w2',
              'qty': '12.7500',
            },
          ],
        },
      ]);
      expect(find.text('打开批量'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'known requests can issue without any existing DRAW and can split a material across physical warehouses',
    (tester) async {
      final tasks = _Tasks();
      await _pump(tester, tasks, docs: []);
      final first = _table(tester).discoveryRows.single;
      first.quantity.text = '10';
      first.values.addAll({'warehouseId': 'w1', 'warehouseName': '原料仓一'});
      _table(tester).onSplitDiscoveryRow!(first);
      await tester.pumpAndSettle();
      final second = _table(tester).discoveryRows.last;
      expect(second.quantity.text, isEmpty);
      expect(second.values['warehouseId'], isNull);
      expect(second.values['colorId'], 'white');
      second.quantity.text = '2.5';
      second.values.addAll({'warehouseId': 'w2', 'warehouseName': '原料仓二'});
      await _submit(tester);
      final items =
          ((tasks.submissions.single['discoveries'] as List).single
                  as Map)['items']
              as List;
      expect(items.map((item) => (item as Map)['warehouseId']), ['w1', 'w2']);
      expect(tasks.submissions.single['docIds'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'duplicate physical source is blocked and each original material retains at least one row',
    (tester) async {
      final tasks = _Tasks();
      await _pump(tester, tasks);
      final first = _table(tester).discoveryRows.single;
      expect(_table(tester).canRemoveDiscoveryRow!(first), isFalse);
      _table(tester).onSplitDiscoveryRow!(first);
      await tester.pumpAndSettle();
      for (final row in _table(tester).discoveryRows) {
        row.quantity.text = '2';
        row.values['warehouseId'] = 'w1';
      }
      await _submit(tester);
      expect(tasks.submissions, isEmpty);
      expect(find.textContaining('同材料同仓重复'), findsOneWidget);
      _table(tester).onRemoveDiscoveryRow!(_table(tester).discoveryRows.last);
      await tester.pumpAndSettle();
      expect(_table(tester).discoveryRows, hasLength(1));
      expect(first.quantity.text, '2');
      expect(_table(tester).canRemoveDiscoveryRow!(first), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ambiguous mixed response freezes edits and retries the exact original batch',
    (tester) async {
      final tasks = _Tasks()..failure = NetworkTimeoutException();
      await _pump(tester, tasks);
      final row = _table(tester).discoveryRows.single;
      row.quantity.text = '12.5';
      row.values['warehouseId'] = 'w1';
      await _submit(tester);
      expect(_table(tester).issueSaving, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('warehouse-draw-batch-remark')),
            )
            .readOnly,
        isTrue,
      );
      final first = jsonEncode(tasks.submissions.single);
      row.quantity.text = '99';
      row.values['warehouseId'] = 'w2';
      tasks.failure = null;
      await _submit(tester);
      expect(tasks.submissions, hasLength(2));
      expect(jsonEncode(tasks.submissions.last), first);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit mixed rejection preserves values and corrected intent receives a new key',
    (tester) async {
      final tasks = _Tasks()
        ..failure = ApiException('SHORTAGE', '库存不足', httpStatus: 409);
      await _pump(tester, tasks);
      final row = _table(tester).discoveryRows.single;
      row.quantity.text = '12.5';
      row.values['warehouseId'] = 'w1';
      await _submit(tester);
      expect(_table(tester).issueSaving, isFalse);
      expect(row.quantity.text, '12.5');
      row.quantity.text = '11';
      tasks.failure = null;
      await _submit(tester);
      expect(tasks.submissions[0]['key'], isNot(tasks.submissions[1]['key']));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown or completed material requests cannot be issued through the known-material batch',
    (tester) async {
      final tasks = _Tasks();
      final requests = _DiscoveryRepository()
        ..values['request'] = _request('request', items: []);
      await _pump(tester, tasks, discoveryRepository: requests);
      expect(find.textContaining('尚未确定材料'), findsOneWidget);
      expect(
        find.byKey(const Key('warehouse-draw-batch-confirm')),
        findsNothing,
      );
      expect(tasks.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mixed requests require approve permission while existing approved DRAW remains unchanged',
    (tester) async {
      final tasks = _Tasks();
      await _pump(tester, tasks, approve: false);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('warehouse-draw-batch-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(_table(tester).issueSaving, isTrue);
      expect(tasks.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 844), const Size(760, 900)]) {
    testWidgets('mixed table remains usable with large text at $size', (
      tester,
    ) async {
      await _pump(tester, _Tasks(), size: size, scale: 1.4);
      expect(find.byType(ProductionDrawDetailTable), findsOneWidget);
      expect(
        find.byKey(const Key('warehouse-draw-batch-confirm')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'mixed repository preserves independent request versions, warehouses and exact decimal input',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: {
                    'issuedCount': 2,
                    'skippedCount': 0,
                    'replayedCount': 0,
                    'replayed': false,
                    'issuedDocNos': ['LL-1', 'LL-2'],
                  },
                ),
              );
            },
          ),
        );
      const discoveries = [
        {
          'requestId': 'r',
          'expectedVersion': 7,
          'items': [
            {
              'goodsId': 'plastic',
              'colorId': 'white',
              'unitId': 'kg',
              'warehouseId': 'w1',
              'qty': '12.7500',
            },
          ],
        },
      ];
      final result = await ProductionDrawTaskRepository(ApiClient(dio))
          .issueDiscoveryBatch(
            idempotencyKey: 'key',
            docIds: ['normal'],
            discoveries: discoveries,
            reason: '发料',
          );
      expect(requests.single.path, '/stock/docs/issue-discovery-batch');
      expect(requests.single.data, {
        'idempotencyKey': 'key',
        'docIds': ['normal'],
        'discoveries': discoveries,
        'reason': '发料',
      });
      expect(result.issuedCount, 2);
    },
  );
}
