// 销售订货编辑页保存前查重（2026-09-25）：
//  - 同「货品+颜色+单位+换算率」多行 → 保存先弹「发现重复货品」复核弹窗；
//  - 汇总合并：数量相加合并一行后提交（PUT 只剩一条，qty=两行之和）；
//  - 删除重复行：各行完全一致时提供，每组保留第一行提交；
//  - 返回修改：不提交，重复行整行标红（EditableGridRow.flagged 红底）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

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
  List<Map<String, dynamic>> items,
) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _DupApi(_orderDetail(items: items));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) => const SalesDocEditPage(
                docType: SalesDocType.order,
                id: 'order-dup',
              ),
            ),
            GoRoute(
              path: '/:rest(.*)',
              builder: (_, _) => const SizedBox.shrink(),
            ),
          ],
        ),
        builder: (context, child) => Stack(
          children: [
            Positioned.fill(child: child!),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppNotificationHost(),
            ),
          ],
        ),
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

void main() {
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

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
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
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return detail;
  }
}
