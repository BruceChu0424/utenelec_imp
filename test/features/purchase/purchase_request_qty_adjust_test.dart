import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

/// V477 分解前数量修正：申请明细行内改量 + 保存走专用修正端点。
void main() {
  testWidgets('request items are qty-editable before decomposition', (
    tester,
  ) async {
    final api = _AdjustApi();
    await _pump(tester, api, permissions: _adjustPerms);

    // 未分解行可编辑；已订货行（orderedQty=4）只读。
    expect(
      find.byKey(const ValueKey('purchase-request-qty-item-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('purchase-request-qty-item-2')),
      findsNothing,
    );
    expect(find.text('已订货的行只读'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('purchase-request-qty-item-1')),
      '12.5',
    );
    // 折叠头+表内滚（UtenCollapsingHeaderScrollView）下，输入聚焦会触发外层
    // ensureVisible 滚动动画；须等动画结束再点按钮（动画中帧的命中几何与绘制不同步）。
    await tester.pumpAndSettle();
    expect(find.text('1 行待保存'), findsOneWidget);

    await tester.tap(find.byKey(const Key('purchase-request-qty-save')));
    await tester.pumpAndSettle();

    expect(api.putCalls, hasLength(1));
    expect(api.putCalls.single.$1, endsWith('/items/item-1/qty'));
    expect(api.putCalls.single.$2, {'qty': 12.5});
    // 保存成功后回填详情并清掉待保存标记。
    expect(find.text('1 行待保存'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('qty edit stays read-only without decompose permission', (
    tester,
  ) async {
    final api = _AdjustApi();
    await _pump(tester, api, permissions: const {Perm.purchaseRequestView});

    expect(
      find.byKey(const ValueKey('purchase-request-qty-item-1')),
      findsNothing,
    );
    expect(find.byKey(const Key('purchase-request-qty-save')), findsNothing);
  });
}

const _adjustPerms = {Perm.purchaseRequestView, Perm.purchaseOrderDecompose};

Future<void> _pump(
  WidgetTester tester,
  ApiClient api, {
  required Set<String> permissions,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        purchaseRepositoryProvider(
          PurchaseDocType.request,
        ).overrideWithValue(PurchaseRepository(api, PurchaseDocType.request)),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      ],
      child: const MaterialApp(
        home: PurchaseDocDetailPage(
          docType: PurchaseDocType.request,
          id: 'r-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _AdjustApi extends ApiClient {
  _AdjustApi() : super(Dio());

  final List<(String, Map<String, dynamic>)> putCalls = [];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/purchase/requests/r-1')) return _detail();
    return <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    putCalls.add((path, (body as Map<String, dynamic>?) ?? const {}));
    return _detail();
  }

  Map<String, dynamic> _detail() => <String, dynamic>{
    'id': 'r-1',
    'makerId': 'maker-1',
    'billNo': 'CS-001',
    'billDate': '2026-09-06',
    'makerName': '计划员',
    'createdAt': '2026-09-06T10:00:00+08:00',
    'warehouseId': 'warehouse-1',
    'status': 1,
    'productionLinked': true,
    'restrictionReason': '该单据由物料分析下达生成。',
    'items': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'item-1',
        'goodsId': 'goods-1',
        'colorId': 'color-1',
        'unitId': 'unit-1',
        'qty': 10,
        'orderedQty': 0,
        'productionPlanNo': 'PLAN-1',
        'salesOrderNo': 'SO-1',
      },
      <String, dynamic>{
        'id': 'item-2',
        'goodsId': 'goods-2',
        'colorId': 'color-1',
        'unitId': 'unit-1',
        'qty': 6,
        'orderedQty': 4,
        'productionPlanNo': 'PLAN-1',
        'salesOrderNo': 'SO-1',
      },
    ],
  };
}
