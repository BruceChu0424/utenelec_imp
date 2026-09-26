// 采购订货编辑页保存前查重（2026-09-25，与销售同款）：
//  - 同「供应商+条款+货品+颜色+单位+换算率」多行 → 保存先弹复核弹窗；
//  - 汇总合并：数量相加合并一行后提交（PUT 只剩一条）；
//  - 返回修改：不提交，重复行整行标红；
//  - 不同供应商的同货品行不算重复（保存按供应商拆单，各成一张订货单）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

Map<String, dynamic> _orderDetail({required List<Map<String, dynamic>> items}) =>
    {
      'id': 'order-dup',
      'makerId': 'maker-1',
      'billNo': 'PO-2026-091-001',
      'billDate': '2026-09-25',
      'status': 0,
      'canEdit': true,
      'supplierId': 'sup-1',
      'settlementMethodId': 'sm-1',
      'currencyId': 'cny',
      'exchangeRate': 1,
      'taxRate': 0,
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
        purchaseRepositoryProvider(
          PurchaseDocType.order,
        ).overrideWithValue(PurchaseRepository(api, PurchaseDocType.order)),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        writeAllDocumentScope(DocumentDataScope.purchase),
        sessionProvider.overrideWith(_EmptySessionNotifier.new),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) => const PurchaseOrderEditPage(id: 'order-dup'),
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
  testWidgets('同供应商同货品多行：汇总合并后提交单行数量之和', (tester) async {
    final api = await _pumpEditor(tester, [
      {
        'id': 'pi-1',
        'goodsId': 'goods-1',
        'colorId': 'c-1',
        'unitId': 'u-1',
        'qty': 10,
        'price': 3.5,
      },
      {
        'id': 'pi-2',
        'goodsId': 'goods-1',
        'colorId': 'c-1',
        'unitId': 'u-1',
        'qty': 5,
        'price': 3.5,
      },
    ]);

    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();

    expect(find.text('发现重复货品'), findsOneWidget);
    await tester.tap(find.text('汇总合并'));
    await tester.pumpAndSettle();

    expect(api.lastPutBody, isNotNull);
    final items = (api.lastPutBody!['items'] as List).cast<Map<String, dynamic>>();
    expect(items, hasLength(1));
    expect(items.single['goodsId'], 'goods-1');
    expect(items.single['qty'], 15.0);
    expect(items.single['supplierId'], 'sup-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('返回修改：不提交，重复行整行标红', (tester) async {
    final api = await _pumpEditor(tester, [
      {
        'id': 'pi-1',
        'goodsId': 'goods-1',
        'colorId': 'c-1',
        'unitId': 'u-1',
        'qty': 10,
        'price': 3.5,
      },
      {
        'id': 'pi-2',
        'goodsId': 'goods-1',
        'colorId': 'c-1',
        'unitId': 'u-1',
        'qty': 5,
        'price': 3.5,
      },
    ]);

    final ctx = tester.element(find.byKey(const ValueKey('uten-edit-save')));
    final tint = Theme.of(ctx)
        .colorScheme
        .errorContainer
        .withValues(alpha: 0.42);
    expect(_redRowDecorations(tint), findsNothing);

    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();

    expect(api.lastPutBody, isNull);
    expect(_redRowDecorations(tint), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}

class _EmptySessionNotifier extends SessionNotifier {
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
  }) async {
    if (path.contains('reference-methods/settlement')) {
      return const [
        {'id': 'sm-1', 'code': 'M30', 'name': '月结30天'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return detail;
  }
}
