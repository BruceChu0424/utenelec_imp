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
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
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
          // 有出货查看权限才会拉分段计数(2026-09-21 六阶段全带数)。
          currentPermissionsProvider.overrideWithValue(const <String>{
            Perm.salesShipmentView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
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
    // 2026-09-21 用户口径: 父分类(hub 卡)有红徽章, 子分类也要有数——分段计数一次取自
    // /documents/status-counts?kind=salesShipment。三形态(ADR-100):
    //   · 草稿 4 / 财务已退回 2 = 红徽章(销售自己要提交、要改单重报);
    //   · 等待财务审核 3 / 已审 1 = 黄色进行中徽章(球在财务、仓库手上, 单子还在跑;
    //     「已审」在状态列的全称就是「已审 · 待出库」, 不是终态);
    //   · 已出库 9 / 红冲 0 = 中性括号(已经结束; 0 也显示保持队形), 历史记录不挂数。
    expect(api.statusCountQueries.single['kind'], 'salesShipment');
    expect(api.statusCountQueries.single.containsKey('shipmentKind'), isFalse);
    expect(find.byType(UtenNotificationBadge), findsNWidgets(2));
    expect(find.text('4'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.byType(UtenInProgressBadge), findsNWidgets(2));
    expect(find.text('3'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('(9)'), findsOneWidget);
    expect(find.text('(0)'), findsOneWidget);

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
  final List<Map<String, dynamic>> statusCountQueries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/documents/status-counts') {
      statusCountQueries.add(Map<String, dynamic>.from(query ?? const {}));
      return const {
        'DRAFT': 4,
        'PENDING_FINANCE': 3,
        'FINANCE_REJECTED': 2,
        'FINANCE_APPROVED': 1,
        'SHIPPED': 9,
        'REVERSED': 0,
      };
    }
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
