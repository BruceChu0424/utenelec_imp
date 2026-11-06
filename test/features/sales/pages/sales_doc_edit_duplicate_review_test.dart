// 销售订货编辑页保存前查重（2026-09-25）：
//  - 同「货品+颜色+单位+换算率」多行 → 保存先弹「发现重复货品」复核弹窗；
//  - 汇总合并：数量相加合并一行后提交（PUT 只剩一条，qty=两行之和）；
//  - 删除重复行：各行完全一致时提供，每组保留第一行提交；
//  - 返回修改：不提交，重复行整行标红（EditableGridRow.flagged 红底）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/platform_table_registry.dart';
import 'package:uten_imp/shared/delivery/order_delivery_window.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';

import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import '../../../shared/drafts/memory_form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';

Map<String, dynamic> _orderDetail({
  required List<Map<String, dynamic>> items,
}) => {
  'id': 'order-dup',
  'status': 0,
  'writable': true,
  'clientId': 'client-1',
  'sellerId': 'seller-1',
  'currencyId': 'cny',
  'settlementMethodId': 'settlement-net30',
  'deliverDate': '2026-09-30',
  'shipmentPolicy': 'ALLOW_PARTIAL',
  'items': items,
};

Future<_DupApi> _pumpEditor(
  WidgetTester tester,
  List<Map<String, dynamic>> items, {
  bool usePlatformCatalog = false,
  bool legacyDeliveryHidden = false,
  String? orderId = 'order-dup',
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _DupApi(_orderDetail(items: items));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'test-user'),
        ),
        sessionSnapshotProvider.overrideWith(_ExistingSnapshot.new),
        apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
        // 本用例断言合并行保留单价：看不到价格的账号会被客户端脱敏、
        // 不随保存提交 price，须显式授予价格查看权限。
        currentPermissionsProvider.overrideWithValue({
          Perm.salesOrderView,
          if (orderId == null) Perm.salesOrderCreate,
          Perm.salesOrderEdit,
          Perm.salesOrderPriceView,
        }),
        if (legacyDeliveryHidden)
          platformTableLayoutProvider(
            'sales.order.items',
          ).overrideWith(_LegacyOrderLayout.new),
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
      ],
      child: MaterialApp.router(
        locale: usePlatformCatalog ? const Locale('zh') : null,
        localizationsDelegates: usePlatformCatalog
            ? const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ]
            : null,
        supportedLocales: usePlatformCatalog
            ? const [Locale('zh')]
            : const [Locale('en', 'US')],
        routerConfig: GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) =>
                  SalesDocEditPage(docType: SalesDocType.order, id: orderId),
            ),
            GoRoute(
              path: '/:rest(.*)',
              builder: (_, _) => const SizedBox.shrink(),
            ),
          ],
        ),
        builder: (context, child) {
          final content = Stack(
            children: [
              Positioned.fill(child: child!),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppNotificationHost(),
              ),
            ],
          );
          return usePlatformCatalog
              ? PlatformTableCatalogScope(
                  resolver: resolvePlatformTable,
                  child: content,
                )
              : content;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Finder _redRowDecorations(Color tint) => find.byWidgetPredicate(
  (w) =>
      w is DecoratedBox &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).color == tint,
);

class _ExistingSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _LegacyOrderLayout extends PlatformTableLayoutNotifier {
  _LegacyOrderLayout() : super('sales.order.items');

  @override
  PlatformTableLayout build() => decode({
    'order': [
      'goods',
      'nameEn',
      'goodsCode',
      'color',
      'qty',
      'price',
      'discount',
      'amount',
      'remark',
      'clientModel',
      'clientGoodsName',
      'machiningPrice',
      'circumference',
      'inboundQty',
      'deliveryPlan',
    ],
    'hidden': [
      'clientModel',
      'clientGoodsName',
      'machiningPrice',
      'circumference',
      'inboundQty',
      'deliveryPlan',
    ],
    'widths': {'goods': 200, 'qty': 160},
  })!;
}

Future<void> _revealOrderCell(
  WidgetTester tester,
  UtenEditableGridController<SalesGridRow> rows,
  SalesGridRow row,
  String key,
) async {
  final revealed = rows.revealCell(row, key, requestFocus: false);
  await tester.pumpAndSettle();
  expect(await revealed, isTrue);
}

void main() {
  for (final scenario in [
    (name: '编辑旧单默认表头', orderId: 'order-dup', legacy: false),
    (name: '编辑旧单恢复v0错误隐藏', orderId: 'order-dup', legacy: true),
    (name: '新建订单默认表头', orderId: null, legacy: false),
  ]) {
    testWidgets('${scenario.name}通过真实平台表格打开交付浮窗且保留未保存输入', (tester) async {
      final api = await _pumpEditor(
        tester,
        [
          {
            'id': 'it-1',
            'goodsId': 'goods-1',
            'unitId': 'unit-box',
            'unitRate': 1,
            'qty': 10,
            'price': 10,
          },
        ],
        usePlatformCatalog: true,
        legacyDeliveryHidden: scenario.legacy,
        orderId: scenario.orderId,
      );
      final grid = tester.widget<UtenEditableGrid<SalesGridRow>>(
        find.byType(UtenEditableGrid<SalesGridRow>),
      );
      final row = grid.controller.rows.single;
      if (scenario.orderId == null) {
        row
          ..goods = const GoodsOption(
            id: 'goods-1',
            code: 'DEMO-001',
            name: '演示产品',
          )
          ..unitId = 'unit-box'
          ..unitRate = 1;
        row.qty.text = '10';
        grid.controller.notifyListeners();
        await tester.pumpAndSettle();
      }

      // Inspect mounted headers and click the page's real cell, including the
      // registry defaults that the isolated delivery-window test cannot cover.
      Finder grip(String label) => find.byWidgetPredicate(
        (widget) => widget is UtenColumnResizeHandle && widget.label == label,
      );
      expect(grip('交付方式'), findsOneWidget);
      expect(
        tester.getCenter(grip('数量')).dx,
        lessThan(tester.getCenter(grip('交付方式')).dx),
      );
      expect(
        tester.getCenter(grip('交付方式')).dx,
        lessThan(tester.getCenter(grip('单价')).dx),
      );
      await _revealOrderCell(tester, grid.controller, row, 'remark');
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && identical(widget.controller, row.remark),
        ),
        '尚未保存的演示备注',
      );
      await _revealOrderCell(tester, grid.controller, row, 'deliveryPlan');
      final deliveryCell = find.byType(OrderDeliveryPlanCell).hitTestable();
      expect(deliveryCell, findsOneWidget);
      await tester.tap(deliveryCell);
      await tester.pumpAndSettle();

      final window = find.byType(UtenFloatingWindow);
      expect(window, findsOneWidget);
      expect(find.text('设置交付方式'), findsOneWidget);
      expect(api.deliveryBomReads, 1);
      await tester.tap(
        find.descendant(
          of: window,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is UtenWindowControlButton &&
                widget.control == UtenWindowControl.close,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(UtenFloatingWindow), findsNothing);
      expect(grid.controller.rows.single, same(row));
      expect(row.goods?.id, 'goods-1');
      expect(row.qty.text, '10');
      expect(row.remark.text, '尚未保存的演示备注');
      expect(row.deliveryPlan, isNull);
      expect(api.lastPutBody, isNull);
      expect(api.postPaths, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('同货品不同交付配置分别保留并透传保存', (tester) async {
    final plan = <String, dynamic>{
      'version': 1,
      'mode': 'BOM',
      'packaging': 'BULK',
      'nodeModes': [
        {
          'path': ['edge-a'],
          'mode': 'CHILDREN',
        },
      ],
      'processes': [
        {
          'path': ['edge-a', 'edge-part'],
          'operation': 'LASER',
          'required': true,
        },
      ],
      'bomFingerprint': 'server-fingerprint',
    };
    final api = await _pumpEditor(tester, [
      {
        'id': 'it-1',
        'goodsId': 'goods-1',
        'unitId': 'unit-box',
        'unitRate': 1,
        'qty': 10,
        'price': 10,
      },
      {
        'id': 'it-2',
        'goodsId': 'goods-1',
        'unitId': 'unit-box',
        'unitRate': 1,
        'qty': 10,
        'price': 10,
        'deliveryPlan': plan,
      },
    ]);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('发现重复货品'), findsNothing);
    final items = (api.lastPutBody!['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items, hasLength(2));
    expect(items[0]['deliveryPlan'], isNull);
    expect(items[1]['deliveryPlan'], plan);
    expect(tester.takeException(), isNull);
  });

  testWidgets('1000行保存校验定位离屏数量错误且不提交', (tester) async {
    final api = await _pumpEditor(tester, [
      for (var index = 0; index < 1000; index++)
        {
          'id': 'it-$index',
          'goodsId': 'goods-1',
          'unitId': 'unit-box',
          'unitRate': 1,
          'qty': index == 999 ? 0 : 1,
          'price': 10,
        },
    ]);
    final grid = tester.widget<UtenEditableGrid<SalesGridRow>>(
      find.byType(UtenEditableGrid<SalesGridRow>),
    );
    final last = grid.controller.rows.last;
    Finder lastQuantity() => find.byWidgetPredicate(
      (widget) => widget is TextField && identical(widget.controller, last.qty),
    );
    expect(lastQuantity(), findsNothing);
    expect(grid.controller.mountedRowCount, lessThan(100));
    await tester.tap(find.text('保存'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(api.lastPutBody, isNull);
    expect(lastQuantity().hitTestable(), findsOneWidget);
    final editable = tester.widget<EditableText>(
      find.descendant(of: lastQuantity(), matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    expect(grid.controller.rows, hasLength(1000));
    expect(grid.controller.mountedRowCount, lessThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('数量不同的重复行：汇总合并后提交单行数量之和', (tester) async {
    final api = await _pumpEditor(tester, [
      {
        'id': 'it-1',
        'goodsId': 'goods-1',
        'unitId': 'unit-box',
        'unitRate': 1,
        'qty': 10,
        'price': 10,
      },
      {
        'id': 'it-2',
        'goodsId': 'goods-1',
        'unitId': 'unit-box',
        'unitRate': 1,
        'qty': 5,
        'price': 10,
      },
    ]);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('发现重复货品'), findsOneWidget);
    // 数量不同 → 不提供删除重复行（删行=丢数据）。
    expect(find.text('删除重复行'), findsNothing);

    await tester.tap(find.text('汇总合并'));
    await tester.pumpAndSettle();

    expect(api.lastPutBody, isNotNull);
    final items = (api.lastPutBody!['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items, hasLength(1));
    expect(items.single['goodsId'], 'goods-1');
    expect(items.single['qty'], '15');
    expect(items.single['price'], '10');
    expect(tester.takeException(), isNull);
  });

  testWidgets('完全一致的重复行：删除重复行只提交一行', (tester) async {
    final api = await _pumpEditor(tester, [
      {
        'id': 'it-1',
        'goodsId': 'goods-1',
        'unitId': 'unit-box',
        'unitRate': 1,
        'qty': 5,
        'price': 10,
      },
      {
        'id': 'it-2',
        'goodsId': 'goods-1',
        'unitId': 'unit-box',
        'unitRate': 1,
        'qty': 5,
        'price': 10,
      },
    ]);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('各行内容完全一致'), findsOneWidget);
    await tester.tap(find.text('删除重复行'));
    await tester.pumpAndSettle();

    final items = (api.lastPutBody!['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items, hasLength(1));
    expect(items.single['qty'], '5');
    expect(tester.takeException(), isNull);
  });

  testWidgets('返回修改：不提交，重复行整行标红', (tester) async {
    final api = await _pumpEditor(tester, [
      {
        'id': 'it-1',
        'goodsId': 'goods-1',
        'unitId': 'unit-box',
        'unitRate': 1,
        'qty': 10,
        'price': 10,
      },
      {
        'id': 'it-2',
        'goodsId': 'goods-1',
        'unitId': 'unit-box',
        'unitRate': 1,
        'qty': 5,
        'price': 10,
      },
    ]);

    final ctx = tester.element(find.text('保存'));
    final tint = Theme.of(
      ctx,
    ).colorScheme.errorContainer.withValues(alpha: 0.42);
    expect(_redRowDecorations(tint), findsNothing);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();

    expect(api.lastPutBody, isNull);
    // 两行重复行都标红，供用户回表格检查。
    expect(_redRowDecorations(tint), findsNWidgets(2));
    expect(find.text('发现重复货品'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无重复行：保存不弹复核弹窗', (tester) async {
    final api = await _pumpEditor(tester, [
      {
        'id': 'it-1',
        'goodsId': 'goods-1',
        'unitId': 'unit-box',
        'unitRate': 1,
        'qty': 10,
        'price': 10,
      },
      {
        'id': 'it-2',
        'goodsId': 'goods-2',
        'unitId': 'unit-box',
        'unitRate': 1,
        'qty': 5,
        'price': 8,
      },
    ]);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('发现重复货品'), findsNothing);
    expect(api.lastPutBody, isNotNull);
    expect((api.lastPutBody!['items'] as List), hasLength(2));
    expect(tester.takeException(), isNull);
  });
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _DupApi extends ApiClient {
  _DupApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;
  Map<String, dynamic>? lastPutBody;
  int deliveryBomReads = 0;
  final postPaths = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders/delivery-bom') {
      deliveryBomReads++;
      return {
        'bomFingerprint': 'synthetic-delivery-v1',
        'root': {
          'path': <String>[],
          'goodsId': query!['goodsId'],
          'name': '演示产品',
          'childrenState': 'LOADED',
          'children': [
            {
              'path': ['demo-module-edge'],
              'goodsId': 'demo-module',
              'code': 'DEMO-M',
              'name': '演示功能组件',
              'qtyExact': '2',
              'childrenState': 'LOADED',
              'children': [
                {
                  'path': ['demo-module-edge', 'demo-part-edge'],
                  'goodsId': 'demo-part',
                  'code': 'DEMO-P',
                  'name': '演示加工底板',
                  'qtyExact': '3',
                  'childrenState': 'NONE',
                  'requiredOperations': ['LASER'],
                  'children': <Map<String, dynamic>>[],
                },
              ],
            },
          ],
        },
      };
    }
    if (path.endsWith('/${detail['id']}')) return detail;
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    postPaths.add(path);
    throw StateError('此测试不允许提交写入：$path');
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return detail;
  }
}
