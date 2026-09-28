// 仓库单据详情页的重量 (ADR-135 §3.6 / §3.9):
//  1. 领料出库「本次重量」紧跟「本次出库」, 「已出库重量」紧跟「已出库」; 出库请求行带
//     weightKg, 总结弹窗列出实称与偏差 (只提醒不拦截); 改了重量换新幂等键;
//  2. 取消出库弹窗只读显示按比例退回的重量, 请求行不带重量;
//  3. 生产退料收仓逐行录实称重量, 核对「登记退 N 个, 称重约 M 个」, 随收仓确认提交;
//     收仓后显示服务端按流水累计的实收重量 (issuedWeightKg, 正数);
//  4. 其它单据明细的重量带单位排在数量之后。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/production_draw_detail_table.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/document_scope_fixture.dart';
import 'outbound_weight_fakes.dart';

const _warehouses = [
  WarehouseDictEntry(id: 'main', name: '主仓', isAccountable: false),
  WarehouseDictEntry(id: 'normal', name: '五金仓', parentId: 'main'),
];

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '螺丝';
  @override
  GoodsDictEntry? goodsInfo(String? id) =>
      const GoodsDictEntry(name: '螺丝', code: 'S01', unitId: 'pcs');
  @override
  String unit(String? id) => '个';
  @override
  String warehouse(String? id) => '五金仓';
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => _warehouses;
}

class _Api extends ApiClient {
  _Api(this.document) : super(Dio());

  Map<String, dynamic> document;
  final posts = <({String path, Map<String, dynamic> body})>[];
  Object? failure;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => document;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path: path, body: Map<String, dynamic>.from(body as Map)));
    final error = failure;
    if (error != null) {
      failure = null;
      throw error;
    }
    return document;
  }
}

Map<String, dynamic> _draw({double issuedQty = 5, double? issuedWeightKg}) => {
  'id': 'draw-1',
  'docType': 'DRAW',
  'billNo': 'SL-001',
  'status': 1,
  'warehouseId': 'normal',
  'issueStatus': 1,
  'productionLinked': true,
  'items': [
    {
      'id': 'i1',
      'lineNo': 1,
      'goodsId': 'screw',
      'unitId': 'pcs',
      'qty': 10,
      'issuedQty': issuedQty,
      'unitRate': 1,
      'issuedWeightKg': ?issuedWeightKg,
      'issuedWeightEstimated': false,
    },
  ],
};

Future<_Api> _pump(
  WidgetTester tester, {
  required StockDocType type,
  required Map<String, dynamic> document,
  required Set<String> permissions,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = _Api(document);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        masterNameServiceProvider.overrideWithValue(_Names()),
        stockDocRepositoryProvider(
          type,
        ).overrideWithValue(StockDocRepository(api, type)),
        documentScopeOverride(writeAll: true),
        businessAttachmentsProvider.overrideWith(
          (ref, owner) async => const <Attachment>[],
        ),
        fakeWeightRepositoryOverride(
          FakeWeightRepository(
            byGoods: {'screw': learnedWeightParams('screw')},
          ),
        ),
      ],
      child: MaterialApp(
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
        home: StockDocDetailPage(docType: type, id: document['id'] as String),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return api;
}

const _issuer = {Perm.stockDocView, Perm.stockDocIssue};

void main() {
  testWidgets(
    'draw issue sends the weighed kg with the line, lists deviations and re-keys when weight changes',
    (tester) async {
      final api = await _pump(
        tester,
        type: StockDocType.draw,
        document: _draw(issuedWeightKg: 0.01),
        permissions: _issuer,
      );
      final table = tester.widget<MasterDataTableView<ProductionDrawDetailRow>>(
        find.byKey(const Key('production-draw-detail-table')),
      );
      final keys = table.columns.map((column) => column.key).toList();
      expect(keys.indexOf('issueWeight'), keys.indexOf('issueQty') + 1);
      expect(keys.indexOf('issuedWeight'), keys.indexOf('issuedQty') + 1);
      expect(keys, isNot(contains('weight')), reason: '旧「实际重量」列已下线');
      // 已出库重量 = 服务端按出库流水累计的正数 (发出减取消出库), 原样显示。
      expect(find.text('10 g'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('weight-cell-input')),
        '25g',
      );
      await tester.pump();
      api.failure = ApiException('SHORTAGE', '库存不足', httpStatus: 409);
      await tester.tap(find.widgetWithText(UtenButton, '出库'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本次实称 25 g'), findsOneWidget);
      // 5 个应重约 10 g, 实称 25 g: 列入偏差提醒, 但仍可确认出库。
      expect(
        find.byKey(const Key('draw-issue-weight-deviations')),
        findsOneWidget,
      );
      await tester.tap(find.text('确认出库'));
      await tester.pumpAndSettle();
      final first = api.posts.single;
      expect(first.path, endsWith('/issue'));
      expect(first.body['lines'], [
        {'itemId': 'i1', 'qty': 5.0, 'weightKg': 0.025},
      ]);

      await tester.enterText(
        find.byKey(const ValueKey('weight-cell-input')),
        '10g',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(UtenButton, '出库'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('draw-issue-weight-deviations')),
        findsNothing,
      );
      await tester.tap(find.text('确认出库'));
      await tester.pumpAndSettle();
      expect(api.posts, hasLength(2));
      expect(
        ((api.posts.last.body['lines'] as List).single as Map)['weightKg'],
        0.01,
      );
      expect(
        api.posts.last.body['idempotencyKey'],
        isNot(first.body['idempotencyKey']),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unweighed draw lines send no weight and keep the old line shape',
    (tester) async {
      final api = await _pump(
        tester,
        type: StockDocType.draw,
        document: _draw(),
        permissions: _issuer,
      );
      await tester.tap(find.widgetWithText(UtenButton, '出库'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本次实称'), findsNothing);
      await tester.tap(find.text('确认出库'));
      await tester.pumpAndSettle();
      expect(api.posts.single.body['lines'], [
        {'itemId': 'i1', 'qty': 5.0},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancel issue shows the mirrored weight read-only and sends quantities only',
    (tester) async {
      final api = await _pump(
        tester,
        type: StockDocType.draw,
        document: _draw(issuedWeightKg: 0.01),
        permissions: {..._issuer, Perm.stockDocReverseIssue},
      );
      await tester.tap(find.widgetWithText(UtenButton, '取消出库'));
      await tester.pumpAndSettle();
      final hint = find.byKey(const ValueKey('cancel-issue-weight-i1'));
      expect(tester.widget<Text>(hint).data, '退回重量 10 g');
      final dialog = find.byType(AlertDialog);
      await tester.enterText(
        find.descendant(of: dialog, matching: find.byType(TextField)).first,
        '2',
      );
      await tester.pump();
      expect(tester.widget<Text>(hint).data, '退回重量 4 g (按比例)');
      await tester.enterText(
        find.descendant(of: dialog, matching: find.byType(TextField)).last,
        '领多了',
      );
      await tester.tap(find.text('确认取消出库'));
      await tester.pumpAndSettle();
      expect(api.posts.single.path, endsWith('/issue/reverse'));
      expect(api.posts.single.body['lines'], [
        {'itemId': 'i1', 'qty': 2.0},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'material return receiving weighs each line against the declared quantity and sends the weights',
    (tester) async {
      final api = await _pump(
        tester,
        type: StockDocType.wdraw,
        document: {
          'id': 'return-1',
          'docType': 'WDRAW',
          'billNo': 'TL-001',
          'status': 0,
          'productionLinked': true,
          'productionMaterialReturn': true,
          'materialReturnSourceWarehouseId': 'line-side',
          'materialReturnMainWarehouseId': 'main',
          'items': [
            {
              'id': 'r1',
              'goodsId': 'screw',
              'unitId': 'pcs',
              'qty': 100,
              'unitRate': 1,
            },
          ],
        },
        permissions: {Perm.stockDocView, Perm.stockDocApprove},
      );
      final table = tester.widget<MasterDataTableView<StockDocItem>>(
        find.byType(MasterDataTableView<StockDocItem>),
      );
      final keys = table.columns.map((column) => column.key).toList();
      expect(keys.indexOf('weight'), keys.indexOf('qty') + 1);
      await tester.enterText(
        find.byKey(const ValueKey('weight-cell-input')),
        '200g',
      );
      await tester.pump();
      expect(find.text('登记退 100个, 称重约 100个'), findsOneWidget);

      await tester.tap(find.widgetWithText(UtenButton, '确认实收并入库'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('material-return-weight-summary')),
        findsOneWidget,
      );
      expect(find.textContaining('随收仓提交实称 200 g'), findsOneWidget);
      await tester.tap(find.byType(UtenDropdownField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('五金仓').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认收料'));
      await tester.pumpAndSettle();
      final body = api.posts.single.body;
      expect(body['warehouseId'], 'normal');
      expect(body['lines'], [
        {'itemId': 'r1', 'weightKg': 0.2},
      ]);
      expect(body['idempotencyKey'], isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'received material return shows the server received weight (issuedWeightKg) after qty',
    (tester) async {
      await _pump(
        tester,
        type: StockDocType.wdraw,
        document: {
          'id': 'return-2',
          'docType': 'WDRAW',
          'billNo': 'TL-002',
          'status': 1,
          'warehouseId': 'normal',
          'productionLinked': true,
          'productionMaterialReturn': true,
          'items': [
            {
              'id': 'r1',
              'goodsId': 'screw',
              'unitId': 'pcs',
              'qty': 100,
              'unitRate': 1,
              // 服务端: 退料行 = 收仓流水实收减红冲 (正数), 含估算时带「≈」。
              'issuedWeightKg': 0.2,
              'issuedWeightEstimated': true,
            },
            {
              'id': 'r2',
              'goodsId': 'screw',
              'unitId': 'pcs',
              'qty': 5,
              'unitRate': 1,
            },
          ],
        },
        permissions: {Perm.stockDocView},
      );
      final table = tester.widget<MasterDataTableView<StockDocItem>>(
        find.byType(MasterDataTableView<StockDocItem>),
      );
      final keys = table.columns.map((column) => column.key).toList();
      expect(keys.indexOf('receivedWeight'), keys.indexOf('qty') + 1);
      expect(keys, isNot(contains('weight')), reason: '退料明细行不落重量, 只看收仓流水');
      expect(find.text('≈200 g'), findsOneWidget);
      expect(find.text('未称'), findsOneWidget, reason: '重量未知不显示成 0');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('other documents show the line weight with its unit after qty', (
    tester,
  ) async {
    await _pump(
      tester,
      type: StockDocType.otherIn,
      document: {
        'id': 'in-1',
        'docType': 'OTHER_IN',
        'billNo': 'QR-001',
        'status': 1,
        'warehouseId': 'normal',
        'items': [
          {
            'id': 'l1',
            'goodsId': 'screw',
            'unitId': 'pcs',
            'qty': 3,
            'weight': 12.5,
          },
          {'id': 'l2', 'goodsId': 'screw', 'unitId': 'pcs', 'qty': 4},
        ],
      },
      permissions: {Perm.stockDocView},
    );
    final table = tester.widget<MasterDataTableView<StockDocItem>>(
      find.byType(MasterDataTableView<StockDocItem>),
    );
    final keys = table.columns.map((column) => column.key).toList();
    expect(keys.indexOf('weight'), keys.indexOf('qty') + 1);
    expect(find.text('12.5 kg'), findsOneWidget);
    expect(find.text('未称'), findsOneWidget, reason: '没称不显示成 0');
    expect(tester.takeException(), isNull);
  });
}
