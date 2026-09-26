// 销售任务中心（/sales/tasks，2026-09-24 三段式统一新增）契约测试：
// 大类按权限显隐、各大类=原独立页整页嵌入、历史其它出货预选历史段、
// 路由守卫 = 五类单据查看权限任一。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/sales/pages/sales_task_center_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/sales/')) {
      return const {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 1,
      };
    }
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

late SharedPreferences _preferences;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  Widget app(Widget page, Set<String> permissions) {
    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_FakeApi()),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(_FakeApi()),
        ),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: MaterialApp(
        // 任务中心页自身不依赖 GoRouter（无 context.go）；直接挂 home。
        home: page,
      ),
    );
  }

  test('route guard accepts any of the five sales view permissions', () {
    expect(requiredAnyPermFor(RouteName.salesTasks), const [
      Perm.salesQuoteView,
      Perm.salesOrderView,
      Perm.salesShipmentView,
      Perm.salesOtherShipmentView,
      Perm.salesReturnView,
    ]);
  });

  testWidgets('大类按权限显隐；进页面不预选', (tester) async {
    await tester.pumpWidget(
      app(const SalesTaskCenterPage(), const {Perm.salesOrderView}),
    );
    await tester.pump();

    // 只有订货单查看权限：仅「订货进度」一个大类。
    expect(find.text('订货进度'), findsOneWidget);
    expect(find.text('出货单'), findsNothing);
    expect(find.text('退货单'), findsNothing);
    expect(find.text('报价单'), findsNothing);
    expect(find.text('客户零星发货'), findsNothing);
    expect(find.text('历史其它出货'), findsNothing);
    // 进页面不预选大类：引导空态，不发请求。
    expect(find.text('在上方选择分类后开始浏览'), findsOneWidget);
  });

  testWidgets('全权限六大类；报价单大类嵌入列表页', (tester) async {
    await tester.pumpWidget(
      app(const SalesTaskCenterPage(), const {
        Perm.salesQuoteView,
        Perm.salesOrderView,
        Perm.salesShipmentView,
        Perm.salesOtherShipmentView,
        Perm.salesReturnView,
      }),
    );
    await tester.pump();
    for (final label in ['订货进度', '出货单', '客户零星发货', '退货单', '报价单', '历史其它出货']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    // 切到「报价单」大类：嵌入的列表页状态行出现（草稿/已审/红冲/历史记录）。
    await tester.tap(find.text('报价单'));
    await tester.pump();
    await tester.pump();
    expect(find.text('草稿'), findsOneWidget);
    expect(find.text('已审'), findsOneWidget);
    expect(find.text('红冲'), findsOneWidget);
    expect(find.text('历史记录'), findsOneWidget);
    // 状态默认不选：列表引导占位，不发请求。
    expect(find.text('在上方选择状态或历史记录后开始浏览'), findsOneWidget);
  });

  testWidgets('历史其它出货大类进入即预选历史段（时间门控）', (tester) async {
    await tester.pumpWidget(
      app(const SalesTaskCenterPage(), const {Perm.salesOtherShipmentView}),
    );
    await tester.pump();

    await tester.tap(find.text('历史其它出货'));
    await tester.pump();
    await tester.pump();
    // 历史段已预选但时间未选：时间门控占位，不发请求。
    expect(
      find.byKey(const Key('sales-doc-history-time-other-shipments')),
      findsOneWidget,
    );
  });
}
