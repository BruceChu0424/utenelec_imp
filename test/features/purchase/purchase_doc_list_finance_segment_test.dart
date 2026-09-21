// 采购订货单列表「等待财务审核 / 财务已退回」分段契约（2026-09-19 建, 2026-09-21 改）：
// 财务通过前订货单 status 保持 0，在审单与财务退回件都不再混进「草稿」段——
//  - 「草稿」段请求带 financeApproval=NONE（真草稿，排除在审单与退回件）；
//  - 「等待财务审核」段请求带 financeApproval=PENDING，计数为黄色在办徽章
//    (ADR-100: 单已经交出去、球在财务手上、还没完, 现在不用本人动手);
//  - 「财务已退回」段请求带 financeApproval=REJECTED，计数为红色通知徽章
//    (用户口径: 父分类有红徽章, 子分类也要有数; 财务退回不能放在草稿里,
//     更不能被当成「进行中」吞掉——它要本人改单重报);
//  - 已审 / 红冲已经结束，仍是中性括号 (N)；
//  - 分段计数一次取自 GET /documents/status-counts?kind=purchaseOrder，
//    不再用 list(size:1) 逐段凑数。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'order list separates drafts, awaiting-finance and finance-rejected',
    (tester) async {
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
            currentPermissionsProvider.overrideWithValue(const {
              Perm.purchaseOrderView,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // 深链落在「草稿」段：列表请求带 NONE 切片（在审单与退回件不算草稿）。
      expect(
        api.listQueries.any(
          (q) => q['size'] == 20 && q['financeApproval'] == 'NONE',
        ),
        isTrue,
        reason: '草稿段请求必须带 financeApproval=NONE',
      );
      // 分段计数只走一次 status-counts，不再 list(size:1) 逐段凑数。
      expect(api.listQueries.any((q) => q['size'] == 1), isFalse);
      // 进页面 / 刷新钩子会各失效一次分段计数, 请求数不止一次, 但每次都是本类型.
      expect(api.statusCountQueries, isNotEmpty);
      expect(
        api.statusCountQueries.every((q) => q['kind'] == 'purchaseOrder'),
        isTrue,
      );

      final toolbar = find.byWidgetPredicate(
        (widget) => widget is UtenFilterToolbar,
      );
      Finder segment(String label) =>
          find.descendant(of: toolbar, matching: find.text(label));
      for (final label in const ['草稿', '等待财务审核', '财务已退回', '已审', '红冲']) {
        expect(segment(label), findsOneWidget, reason: '分段「$label」');
      }

      // 草稿 5 / 财务已退回 2 = 等本人动手 → 红徽章，整条工具条只此两枚。
      final badges = find.descendant(
        of: toolbar,
        matching: find.byType(UtenNotificationBadge),
      );
      expect(badges, findsNWidgets(2));
      expect(
        find.descendant(of: toolbar, matching: find.text('5')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: toolbar, matching: find.text('2')),
        findsOneWidget,
      );
      // 等待财务审核 3 = 在办 → 黄徽章一枚, 不再是中性括号 (3), 见 ADR-100。
      final progressBadges = find.descendant(
        of: toolbar,
        matching: find.byType(UtenInProgressBadge),
      );
      expect(progressBadges, findsOneWidget);
      expect(
        find.descendant(of: progressBadges, matching: find.text('3')),
        findsOneWidget,
      );
      expect(find.text('(3)'), findsNothing);
      // 已审 7 / 红冲 1 已经结束，仍是中性括号。
      expect(find.text('(7)'), findsOneWidget);
      expect(find.text('(1)'), findsOneWidget);

      // 点选「财务已退回」段：列表请求带 status=0 + financeApproval=REJECTED。
      api.listQueries.clear();
      await tester.tap(segment('财务已退回'));
      await tester.pumpAndSettle();
      var listQuery = api.listQueries.lastWhere(
        (q) => q['size'] == 20,
        orElse: () => const {},
      );
      expect(listQuery['status'], 0);
      expect(listQuery['financeApproval'], 'REJECTED');

      // 点选「等待财务审核」段：列表请求带 status=0 + financeApproval=PENDING。
      api.listQueries.clear();
      await tester.tap(segment('等待财务审核'));
      await tester.pumpAndSettle();
      listQuery = api.listQueries.lastWhere(
        (q) => q['size'] == 20,
        orElse: () => const {},
      );
      expect(listQuery['status'], 0);
      expect(listQuery['financeApproval'], 'PENDING');
      expect(tester.takeException(), isNull);
    },
  );
}

/// 记录全部 GET /purchase/orders 列表查询与 /documents/status-counts 计数查询。
class _OrderListApi extends ApiClient {
  _OrderListApi() : super(Dio());

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
        'DRAFT': 5,
        'PENDING_FINANCE': 3,
        'FINANCE_REJECTED': 2,
        'APPROVED': 7,
        'REVERSED': 1,
      };
    }
    listQueries.add(Map<String, dynamic>.from(query ?? const {}));
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
      'total': 2,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
