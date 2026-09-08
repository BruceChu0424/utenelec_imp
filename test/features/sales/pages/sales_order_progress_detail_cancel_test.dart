// 进度详情页：财务驳回框的「取消订单」终止处置入口（2026-09-05）。
//
// 驳回单不能只有「修改订单」一个出口——客户撤单/重谈时销售可直接取消，
// 订单转已中止、不再挂在「财务驳回」段。本测试锁定：按钮按权限显隐、
// 确认后调用 POST /sales/orders/{id}/cancel 并刷新详情。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/pages/sales_order_progress_detail_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'rejected order offers cancel (terminal) beside edit; confirm posts cancel and reloads',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _DetailApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesOrderView,
              Perm.salesOrderEdit,
              Perm.salesOrderCancel,
            }),
          ],
          child: const MaterialApp(
            home: SalesOrderProgressDetailPage(orderId: 'order-rej'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('修改订单'), findsOneWidget);
      expect(find.text('取消订单'), findsOneWidget);

      await tester.tap(find.text('取消订单'));
      await tester.pumpAndSettle();
      expect(find.textContaining('确认取消订单'), findsOneWidget);

      await tester.tap(find.text('确认取消订单'));
      await tester.pumpAndSettle();

      expect(api.cancelCalls, 1);
      // 取消后详情重拉（reload），已中止徽标出现。
      expect(api.detailCalls, greaterThanOrEqualTo(2));
      expect(find.text('已中止'), findsOneWidget);
    },
  );

  testWidgets('cancel entry hidden without sales_order:cancel authority', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_DetailApi()),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.salesOrderView,
            Perm.salesOrderEdit,
          }),
        ],
        child: const MaterialApp(
          home: SalesOrderProgressDetailPage(orderId: 'order-rej'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('修改订单'), findsOneWidget);
    expect(find.text('取消订单'), findsNothing);
  });
}

class _DetailApi extends ApiClient {
  _DetailApi() : super(Dio());

  int detailCalls = 0;
  int cancelCalls = 0;

  Map<String, dynamic> _detail({bool stopped = false}) => {
    'id': 'order-rej',
    'billNo': 'SO-REJ',
    'billDate': '2026-09-01',
    'status': 1,
    'writable': true,
    'financeConfirmed': false,
    'financeRejected': !stopped,
    if (!stopped) ...{
      'financeRejectedReason': '结账方式错误',
      'financeRejectedAt': '2026-09-02T08:00:00+08:00',
      'financeRejectedByName': '财务张经理',
    },
    'stopped': stopped,
    'closed': false,
    'items': const <Map<String, dynamic>>[],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders/order-rej') {
      detailCalls++;
      // 取消后重拉的详情 = 已中止终态（驳回态已清）。
      return _detail(stopped: cancelCalls > 0);
    }
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    // 履约时间线走 getList（repo.progressTimeline）：驳回单无进度事件。
    return const <Map<String, dynamic>>[];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders/order-rej/cancel') {
      cancelCalls++;
      return _detail(stopped: true);
    }
    return const <String, dynamic>{};
  }
}
