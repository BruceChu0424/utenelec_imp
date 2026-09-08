import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/pages/sales_order_progress_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

/// 页面 build 期捕获本页路径（onPageResume 返回即刷新用），需包一层 GoRouter。
Widget _host() {
  final router = GoRouter(
    initialLocation: '/sales/progress',
    routes: [
      GoRoute(
        path: '/sales/progress',
        builder: (_, _) => const SalesOrderProgressPage(),
      ),
    ],
  );
  addTearDown(router.dispose);
  return MaterialApp.router(routerConfig: router);
}

void main() {
  testWidgets(
    'progress page shows REJECTED filter and rejection details while clearing only completion notices',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ProgressApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesOrderView,
            }),
          ],
          child: _host(),
        ),
      );
      await tester.pumpAndSettle();

      // 分类分段范式（ADR-066）：阶段行默认不选（内容区是引导占位，不发
      // progress 请求），先点「财务驳回」段才按 stage=REJECTED 加载。
      await tester.tap(find.text('财务驳回'));
      await tester.pumpAndSettle();

      // 2026-09-05 起列表为 MasterDataTableView：阶段列为语义底色单元格
      //（驳回人/时间在进度详情页展示，不再进表格行）。
      expect(find.text('财务驳回'), findsWidgets);
      expect(find.text('SO-REJECTED'), findsOneWidget);
      expect(find.textContaining('结账方式错误'), findsOneWidget);
      expect(api.readBySourceQueries, hasLength(1));
      final events = api.readBySourceQueries.single['events'] as String;
      expect(events, contains('PRODUCTION_FINISHED_INBOUND'));
      expect(events, contains('PRODUCTION_REPORTED'));
      expect(events, isNot(contains('SALES_ORDER_FINANCE_REJECTED')));
    },
  );

  testWidgets(
    'history segment loads ALL orders (stage empty) across every stage',
    (tester) async {
      // 历史记录 = 全部订单档案视图：含被驳回/进行中/已发货/已中止/已结案，
      // 不再只查已发货——用户反馈「点全部查不到订单」的口径回归锁。
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ProgressApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesOrderView,
            }),
          ],
          child: _host(),
        ),
      );
      await tester.pumpAndSettle();

      // 未选时间前不发请求（ADR-066 历史段时间门控）。
      expect(api.progressQueries, isEmpty);

      await tester.tap(find.text('历史记录'));
      await tester.pumpAndSettle();
      expect(api.progressQueries, isEmpty);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();

      expect(api.progressQueries, hasLength(1));
      // 历史记录不带 stage 参数（repo 空串省略）= 后端默认全部订单。
      expect(api.progressQueries.single.containsKey('stage'), isFalse);
      // 终态/被驳回订单都能出现在历史里；取消单（finance 未确认）显示「已中止」
      // 而非「等待财务审核」——终态优先于财务闸门。
      expect(find.text('SO-REJECTED'), findsOneWidget);
      expect(find.text('SO-CANCELED'), findsOneWidget);
      expect(find.text('已中止'), findsOneWidget);
      expect(find.text('SO-CLOSED'), findsOneWidget);
      expect(find.text('已结案'), findsOneWidget);
      expect(find.text('等待财务审核'), findsNothing);
    },
  );
}

class _ProgressApi extends ApiClient {
  _ProgressApi() : super(Dio());

  final List<Map<String, dynamic>> readBySourceQueries = [];
  final List<Map<String, dynamic>> progressQueries = [];

  Map<String, dynamic> _row(
    String id,
    String billNo, {
    String stage = 'PENDING',
    bool financeConfirmed = true,
    bool financeRejected = false,
    bool stopped = false,
    bool closed = false,
  }) => {
    'orderId': id,
    'billNo': billNo,
    'billDate': '2026-08-27',
    'deliverDate': '2026-09-10',
    'clientName': '测试客户',
    'orderQty': 10,
    'producedQty': 0,
    'shippedQty': 0,
    'reservedQty': 0,
    'plannedQty': 0,
    'productionPct': 0,
    'stage': stage,
    'financeConfirmed': financeConfirmed && !financeRejected,
    'financeRejected': financeRejected,
    'stopped': stopped,
    'closed': closed,
    if (financeRejected) ...{
      'financeRejectedReason': '结账方式错误',
      'financeRejectedAt': '2026-08-27T08:00:00+08:00',
      'financeRejectedByName': '财务张经理',
    },
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders/progress') {
      progressQueries.add(Map<String, dynamic>.from(query ?? const {}));
      final stage = (query ?? const {})['stage'] as String? ?? '';
      final allRows = <Map<String, dynamic>>[
        _row(
          'order-rejected',
          'SO-REJECTED',
          stage: 'REJECTED',
          financeRejected: true,
        ),
        // 真实取消单画像：cancel 不清 finance_confirmed（仍 false）——阶段列
        // 必须先判终态再判财务闸门，否则错显「等待财务审核」。
        _row(
          'order-canceled',
          'SO-CANCELED',
          stage: 'CANCELED',
          financeConfirmed: false,
          stopped: true,
        ),
        _row('order-closed', 'SO-CLOSED', stage: 'CLOSED', closed: true),
      ];
      // stage 非空 = 活跃阶段段精确匹配；'' = 历史记录全量（含终态）。
      final rows = stage.isEmpty
          ? allRows
          : allRows.where((r) => r['stage'] == stage).toList();
      return {
        'items': rows,
        'page': 1,
        'size': 50,
        'total': rows.length,
        'totalPages': 1,
      };
    }
    if (path == '/sales/orders/progress/stage-counts') {
      return const {
        'REJECTED': 1,
        'PENDING': 0,
        'PRODUCING': 0,
        'SHIPPABLE': 0,
        'SHIPPED': 0,
      };
    }
    if (path == '/notices/unread-count') return const {'count': 0};
    return const <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/notices/read-by-source') {
      readBySourceQueries.add(Map<String, dynamic>.from(query ?? const {}));
    }
    return const <String, dynamic>{};
  }
}
