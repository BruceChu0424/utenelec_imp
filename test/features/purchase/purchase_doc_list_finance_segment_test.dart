// 采购订货单列表「等待财务审核」分段契约（2026-09-19）：
// 财务通过前订货单 status 保持 0，在审单不再混进「草稿」段——
//  - 「草稿」段请求带 financeApproval=NONE（真草稿，排除在审单）；
//  - 「等待财务审核」段请求带 financeApproval=PENDING，计数为普通数字
//   （中性括号 (N)，不挂红色通知徽章）；
//  - 计数拉取两份（NONE / PENDING 各一），与分段口径一一对应。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('order list separates drafts from awaiting-finance segment', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _OrderListApi();
    final router = GoRouter(
      initialLocation: '/purchase/orders?status=draft',
      routes: [
        GoRoute(
          path: '/purchase/orders',
          builder: (_, state) => PurchaseDocListPage(
            docType: PurchaseDocType.order,
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
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 深链落在「草稿」段：列表请求带 NONE 切片（在审单不算草稿）。
    expect(
      api.queries.any((q) => q['size'] == 20 && q['financeApproval'] == 'NONE'),
      isTrue,
      reason: '草稿段请求必须带 financeApproval=NONE',
    );
    // 计数拉取两份：NONE 与 PENDING 各一。
    expect(
      api.queries.any((q) => q['size'] == 1 && q['financeApproval'] == 'NONE'),
      isTrue,
    );
    expect(
      api.queries.any(
        (q) => q['size'] == 1 && q['financeApproval'] == 'PENDING',
      ),
      isTrue,
    );

    // 「等待财务审核」段存在（限定在工具条内，避免与行内状态徽章撞文案）。
    final toolbar = find.byWidgetPredicate(
      (widget) => widget is UtenFilterToolbar,
    );
    final awaitingSegment = find.descendant(
      of: toolbar,
      matching: find.text('等待财务审核'),
    );
    expect(awaitingSegment, findsOneWidget);

    // 点选「等待财务审核」段：列表请求带 status=0 + financeApproval=PENDING。
    api.queries.clear();
    await tester.tap(awaitingSegment);
    await tester.pumpAndSettle();
    final listQuery = api.queries.lastWhere(
      (q) => q['size'] == 20,
      orElse: () => const {},
    );
    expect(listQuery['status'], 0);
    expect(listQuery['financeApproval'], 'PENDING');

    // 段计数是普通数字（中性括号形态），不挂红色通知徽章。
    expect(find.text('(3)'), findsOneWidget);
    expect(
      find.descendant(
        of: toolbar,
        matching: find.byType(UtenNotificationBadge),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

/// 记录全部 GET /purchase/orders 查询；计数段 size=1、列表段 size=20。
class _OrderListApi extends ApiClient {
  _OrderListApi() : super(Dio());

  final List<Map<String, dynamic>> queries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add(Map<String, dynamic>.from(query ?? const {}));
    return {
      'items': [
        {
          'id': 'order-1',
          'billNo': 'PO26090001',
          'billDate': '2026-09-19',
          'status': 0,
          'financeApproval': {'status': 'PENDING'},
        },
      ],
      'page': 1,
      // 列表 size=20 的请求返回 2；计数 size=1 按段返回 5 / 3。
      'total': query?['size'] == 1
          ? (query?['financeApproval'] == 'PENDING' ? 3 : 5)
          : 2,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
