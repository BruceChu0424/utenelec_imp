import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/pages/sales_order_progress_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

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
          child: const MaterialApp(home: SalesOrderProgressPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 分类分段范式（ADR-066）：阶段行默认不选（内容区是引导占位，不发
      // progress 请求），先点「财务驳回」段才按 stage=REJECTED 加载。
      await tester.tap(find.text('财务驳回'));
      await tester.pumpAndSettle();

      expect(find.text('财务驳回'), findsWidgets);
      expect(
        find.byKey(const ValueKey('sales-order-progress-finance-rejected')),
        findsOneWidget,
      );
      expect(find.textContaining('结账方式错误'), findsOneWidget);
      expect(find.textContaining('财务张经理'), findsOneWidget);
      expect(api.readBySourceQueries, hasLength(1));
      final events = api.readBySourceQueries.single['events'] as String;
      expect(events, contains('PRODUCTION_FINISHED_INBOUND'));
      expect(events, contains('PRODUCTION_REPORTED'));
      expect(events, isNot(contains('SALES_ORDER_FINANCE_REJECTED')));
    },
  );
}

class _ProgressApi extends ApiClient {
  _ProgressApi() : super(Dio());

  final List<Map<String, dynamic>> readBySourceQueries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders/progress') {
      return const {
        'items': [
          {
            'orderId': 'order-rejected',
            'billNo': 'SO-REJECTED',
            'billDate': '2026-08-27',
            'deliverDate': '2026-09-10',
            'clientName': '测试客户',
            'orderQty': 10,
            'producedQty': 0,
            'shippedQty': 0,
            'reservedQty': 0,
            'plannedQty': 0,
            'productionPct': 0,
            'stage': 'REJECTED',
            'financeConfirmed': false,
            'financeRejected': true,
            'financeRejectedReason': '结账方式错误',
            'financeRejectedAt': '2026-08-27T08:00:00+08:00',
            'financeRejectedByName': '财务张经理',
          },
        ],
        'page': 1,
        'size': 50,
        'total': 1,
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
