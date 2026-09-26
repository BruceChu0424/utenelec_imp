// 委外订货编辑页保存前查重（2026-09-25，与采购同款）：
//  - 同「委外商+条款+货品+颜色+单位+换算率」多行 → 保存先弹复核弹窗；
//  - 完全一致的重复行可「删除重复行」每组保留一行提交；
//  - 汇总合并数量相加。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_order_edit_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

Map<String, dynamic> _orderDetail({required List<Map<String, dynamic>> items}) =>
    {
      'id': 'order-dup',
      'makerId': 'maker-1',
      'billNo': 'WO-2026-091-001',
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
        subcontractRepositoryProvider(
          SubcontractDocType.order,
        ).overrideWithValue(SubcontractRepository(api, SubcontractDocType.order)),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        writeAllDocumentScope(DocumentDataScope.subcontract),
        sessionProvider.overrideWith(_EmptySessionNotifier.new),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) => const SubcontractOrderEditPage(id: 'order-dup'),
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

void main() {
  testWidgets('完全一致的重复行：删除重复行只提交一行', (tester) async {
    final api = await _pumpEditor(tester, [
      {
        'id': 'wi-1',
        'goodsId': 'goods-1',
        'colorId': 'c-1',
        'unitId': 'u-1',
        'qty': 5,
        'price': 3.5,
      },
      {
        'id': 'wi-2',
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
    expect(find.text('各行内容完全一致'), findsOneWidget);
    await tester.tap(find.text('删除重复行'));
    await tester.pumpAndSettle();

    expect(api.lastPutBody, isNotNull);
    final items = (api.lastPutBody!['items'] as List).cast<Map<String, dynamic>>();
    expect(items, hasLength(1));
    expect(items.single['goodsId'], 'goods-1');
    expect(items.single['qty'], 5.0);
    expect(items.single['supplierId'], 'sup-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('数量不同的重复行：汇总合并提交数量之和', (tester) async {
    final api = await _pumpEditor(tester, [
      {
        'id': 'wi-1',
        'goodsId': 'goods-1',
        'colorId': 'c-1',
        'unitId': 'u-1',
        'qty': 10,
        'price': 3.5,
      },
      {
        'id': 'wi-2',
        'goodsId': 'goods-1',
        'colorId': 'c-1',
        'unitId': 'u-1',
        'qty': 5,
        'price': 3.5,
      },
    ]);

    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();

    expect(find.text('删除重复行'), findsNothing);
    await tester.tap(find.text('汇总合并'));
    await tester.pumpAndSettle();

    final items = (api.lastPutBody!['items'] as List).cast<Map<String, dynamic>>();
    expect(items, hasLength(1));
    expect(items.single['qty'], 15.0);
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
