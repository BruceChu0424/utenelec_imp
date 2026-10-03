// 仓库单据编辑页的行级仓库口径 (V782, 2026-10-01「仓库不放表头，放表格里」):
//  1. 货品选择多选(与新建销售同款): 第一个填当前行, 其余各自追加一行;
//  2. 出库/入库类单据的仓库在表格行内逐行选(同单可跨仓), 表头不再有仓库字段;
//     未选仓库的行保存时整表一起报;
//  3. 库位号列可编辑, 选品/改仓后按 仓×货品 的记忆建议只预填空格;
//  4. 保存 payload: 明细带 warehouseId/place, 表头仓 = 首条明细行仓;
//  5. 盘点(CHECK)仍按表头仓, 表格没有行内仓库列。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_edit_page.dart';
import 'package:uten_imp/features/warehouse/widgets/stock_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/widgets/warehouse_hierarchy_dropdown.dart';

import 'arrival_weight_test_support.dart';

const _goodsA = 'goods-screw';
const _goodsB = 'goods-nut';
const _whMain = 'wh-main';
const _whSecond = 'wh-second';

const _pickedGoods = [
  GoodsListItem(id: _goodsA, name: '螺丝', code: 'SCR-01', unitId: 'unit-pcs'),
  GoodsListItem(id: _goodsB, name: '螺母', code: 'NUT-01', unitId: 'unit-pcs'),
];

void main() {
  testWidgets('其它出库: 多选逐行追加, 行内选仓跨仓, 库位按仓预填, payload 带行仓', (tester) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('仓库')),
        GoRoute(
          path: '/warehouse/:code/new',
          builder: (_, state) => StockDocEditPage(
            docType: StockDocType.byCode(state.pathParameters['code']!),
          ),
        ),
        GoRoute(
          path: '/warehouse/:code/:id',
          builder: (_, state) => Text('详情 ${state.pathParameters['id']}'),
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
            Perm.stockDocEdit,
          }),
          stockGridGoodsPickerProvider(StockDocType.otherOut).overrideWith(
            (ref) =>
                (context, ref) async => _pickedGoods,
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
    router.push('/warehouse/OTHER_OUT/new');
    await tester.pumpAndSettle();

    // 表头不再有「仓库」字段（V782：仓库挪进表格）。
    final grid = find.byType(UtenEditableGrid<StockGridRow>);
    expect(grid, findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, '仓库'),
      findsNothing,
      reason: '行级仓库类型不在表头放仓库',
    );
    final labels = tester
        .widget<UtenEditableGrid<StockGridRow>>(grid)
        .columns
        .map((column) => column.label)
        .toList();
    expect(labels, contains('发出仓'));
    expect(labels, contains('库位号'));

    // 点货品格：多选两个 → 当前行 + 追加一行。
    await tester.tap(find.text('点击选择'));
    await tester.pumpAndSettle();
    expect(find.text('螺丝'), findsOneWidget);
    expect(find.text('螺母'), findsOneWidget);
    expect(
      tester.widget<UtenEditableGrid<StockGridRow>>(grid).controller.rows,
      hasLength(2),
      reason: '多选第二个货品各自追加一行',
    );

    // 未选仓库先保存：整表拦下并直说哪几行，不发出创建请求。
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未选择仓库'), findsOneWidget);
    expect(api.createdBodies, isEmpty);

    // 两行分别选不同仓（同单跨仓）。
    await _selectRowWarehouse(tester, 0, '主仓库');
    await _selectRowWarehouse(tester, 1, '二号仓');

    // 库位建议按仓查（每次改仓都会按行仓分组重查）：最终两仓都查过，只预填空格。
    await tester.pumpAndSettle();
    expect(
      api.suggestionBodies.map((body) => body['warehouseId']),
      containsAll([_whMain, _whSecond]),
    );
    final placeA = _placeControllerOf(tester, 0);
    final placeB = _placeControllerOf(tester, 1);
    expect(placeA.text, 'A-01-记忆');
    expect(placeB.text, 'B-02');

    // 数量补齐后保存：明细带行仓与库位，表头仓 = 首条明细行仓。
    final qtyFields = find.byKey(const ValueKey('stock-grid-qty'));
    await tester.enterText(qtyFields.at(0), '10');
    await tester.enterText(qtyFields.at(1), '20');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final body = api.createdBodies.single;
    expect(body['warehouseId'], _whMain, reason: '表头仓=首条明细行仓');
    final items = (body['items'] as List).cast<Map<String, dynamic>>();
    expect(items, hasLength(2));
    expect(items[0]['goodsId'], _goodsA);
    expect(items[0]['warehouseId'], _whMain);
    expect(items[0]['place'], 'A-01-记忆');
    expect(items[0]['qty'], 10);
    expect(items[1]['goodsId'], _goodsB);
    expect(items[1]['warehouseId'], _whSecond);
    expect(items[1]['place'], 'B-02');
    expect(items[1]['qty'], 20);
  });

  testWidgets('盘点: 仓库仍在表头, 表格没有行内仓库列', (tester) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api();
    final router = GoRouter(
      initialLocation: '/warehouse/CHECK/new',
      routes: [
        GoRoute(
          path: '/warehouse/:code/new',
          builder: (_, state) => StockDocEditPage(
            docType: StockDocType.byCode(state.pathParameters['code']!),
          ),
        ),
        GoRoute(
          path: '/warehouse/:code/:id',
          builder: (_, state) => Text('详情 ${state.pathParameters['id']}'),
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
            Perm.stockDocEdit,
          }),
          ...warehouseWeightTestOverrides(api),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final labels = tester
        .widget<UtenEditableGrid<StockGridRow>>(
          find.byType(UtenEditableGrid<StockGridRow>),
        )
        .columns
        .map((column) => column.label)
        .toList();
    expect(labels, isNot(contains('发出仓')));
    expect(labels, isNot(contains('入库仓')));
    // 表头仓库字段仍在（盘点按表头仓读账面；行内没有仓库下拉）。
    expect(find.byType(WarehouseHierarchyDropdown), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is UtenDropdownField && widget.label == '仓库',
      ),
      findsOneWidget,
    );
  });
}

/// 行内仓库下拉：点开第 [index] 行的发出仓格并选 [label] 对应的仓。
Future<void> _selectRowWarehouse(
  WidgetTester tester,
  int index,
  String label,
) async {
  final dropdowns = find.byType(WarehouseHierarchyDropdown);
  expect(dropdowns, findsNWidgets(2));
  await tester.tap(dropdowns.at(index));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

TextEditingController _placeControllerOf(WidgetTester tester, int index) {
  // 库位格的 key 随行对象走，改按列特征（占位文案）取第 N 个库位输入框。
  final placeFields = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == '按本次实际填写',
  );
  final widget = tester.widgetList<TextField>(placeFields).elementAt(index);
  return widget.controller!;
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  final List<Map<String, dynamic>> createdBodies = [];
  final List<Map<String, dynamic>> suggestionBodies = [];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehousesDict) {
      return const [
        {'id': _whMain, 'name': '主仓库', 'accountable': true, 'status': '使用'},
        {'id': _whSecond, 'name': '二号仓', 'accountable': true, 'status': '使用'},
      ];
    }
    if (path == ApiEndpoints.unitsDict) {
      return const [
        {'id': 'unit-pcs', 'name': '个'},
      ];
    }
    if (path == ApiEndpoints.goodsLookup) {
      return const [
        {'id': _goodsA, 'name': '螺丝', 'code': 'SCR-01', 'stockPlace': 'A-01'},
        {'id': _goodsB, 'name': '螺母', 'code': 'NUT-01', 'stockPlace': null},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.stockDocsBase) {
      // 「本类型最近一张单的仓库」预填：无历史单 → 不预填。
      return const {'items': <Object>[], 'page': 1, 'size': 1, 'total': 0};
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.stockDocsBase) {
      createdBodies.add(Map<String, dynamic>.from(body! as Map));
      return const {
        'id': 'doc-new',
        'docType': 'OTHER_OUT',
        'items': <Object>[],
      };
    }
    if (path == ApiEndpoints.warehousePlaceSuggestions) {
      final map = Map<String, dynamic>.from(body! as Map);
      suggestionBodies.add(map);
      final warehouseId = map['warehouseId'] as String?;
      return {
        'items': [
          if (warehouseId == _whMain)
            {
              'goodsId': _goodsA,
              'colorId': null,
              'place': 'A-01-记忆',
              'source': 'WAREHOUSE_PREFERENCE',
            }
          else if (warehouseId == _whSecond)
            {
              'goodsId': _goodsB,
              'colorId': null,
              'place': 'B-02',
              'source': 'GOODS_MASTER',
            },
        ],
      };
    }
    return const {};
  }
}
