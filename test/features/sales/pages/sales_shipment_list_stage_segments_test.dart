// 销售出货单列表「按真实阶段分段」（2026-09-20 用户口径：出货单等待财务审核、财务已放行
// 待出库时 status 仍是 0，此前全被归到「草稿」）。断言：
//   1. 分段行是 草稿/等待财务审核/财务已退回/已审/已出库/红冲/历史记录；
//   2. 点某段发 stage=<阶段> 且不带 status；
//   3. 状态列按行真实阶段显示（等待财务审核 / 已审 · 待出库），不再一律「草稿」。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('shipment list segments by real stage and labels rows by stage', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _StageApi();
    final router = GoRouter(
      initialLocation: '/sales/shipments',
      routes: [
        GoRoute(
          path: '/sales/shipments',
          builder: (_, state) => SalesDocListPage(
            docType: SalesDocType.shipment,
            initialStatus: state.uri.queryParameters['status'],
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          salesMasterNameServiceProvider.overrideWithValue(
            SalesMasterNameService(api),
          ),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in const [
      '草稿',
      '等待财务审核',
      '财务已退回',
      '已审',
      '已出库',
      '红冲',
      '历史记录',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '分段「$label」');
    }
    // 默认不选不发请求。
    expect(api.listQueries, isEmpty);

    await tester.tap(find.text('等待财务审核'));
    await tester.pumpAndSettle();
    expect(api.listQueries.last['stage'], 'PENDING_FINANCE');
    expect(api.listQueries.last.containsKey('status'), isFalse);
    // 行状态按真实阶段：等待财审行与财务已放行待出库行各自成文，不再一律「草稿」。
    expect(find.text('等待财务审核'), findsNWidgets(2));
    expect(find.text('已审 · 待出库'), findsOneWidget);
    expect(find.text('草稿'), findsOneWidget);

    await tester.tap(find.text('已审'));
    await tester.pumpAndSettle();
    expect(api.listQueries.last['stage'], 'FINANCE_APPROVED');

    await tester.tap(find.text('已出库'));
    await tester.pumpAndSettle();
    expect(api.listQueries.last['stage'], 'SHIPPED');
    expect(tester.takeException(), isNull);
  });
}

class _StageApi extends ApiClient {
  _StageApi() : super(Dio());

  final List<Map<String, dynamic>> listQueries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/shipments') {
      listQueries.add(Map<String, dynamic>.from(query ?? const {}));
      return const {
        'items': [
          {
            'id': 'shipment-pending',
            'billNo': 'XC-PENDING',
            'billDate': '2026-09-20',
            'clientId': 'client-1',
            'status': 0,
            'financeAudit': 0,
            'warehouseWorkStatus': 'PENDING_PICK',
            'salesConfirmed': true,
            'financeReviewPending': true,
            'writable': true,
          },
          {
            'id': 'shipment-approved',
            'billNo': 'XC-APPROVED',
            'billDate': '2026-09-20',
            'clientId': 'client-1',
            'status': 0,
            'financeAudit': 1,
            'warehouseWorkStatus': 'PENDING_PICK',
            'salesConfirmed': true,
            'writable': true,
          },
        ],
        'page': 1,
        'size': 20,
        'total': 2,
        'totalPages': 1,
      };
    }
    return const <String, dynamic>{'items': <Map<String, dynamic>>[]};
  }
}
