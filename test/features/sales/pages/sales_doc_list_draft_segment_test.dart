// 销售单据列表「草稿」段（G5-draft-list）。
//
// 订货单列表原本是「链路阶段」工作台：四个大类段都按 chain_status 过滤，而草稿的
// chain_status 恒为 0，落不进任何段——销售存的草稿在订货单列表里根本看不到。
// 本测试锁住修复后的三条口径：
//   1. 第 5 段「草稿」发的请求是 status=0 且不带任何 chain 过滤；
//   2. 草稿段下不再显示状态小类行（草稿本身就是状态口径）；
//   3. 路由 ?status=draft 深链直接落在草稿段（新建页「草稿(N)」按钮的落点）。

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';

Future<_RecordingApi> _pumpOrderList(
  WidgetTester tester, {
  String? initialStatus,
  DraftCounts counts = const DraftCounts(salesOrder: 2),
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _RecordingApi();
  final location = initialStatus == null
      ? '/sales/orders'
      : '/sales/orders?status=$initialStatus';
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/sales/orders',
        builder: (_, state) => SalesDocListPage(
          docType: SalesDocType.order,
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
        draftCountsProvider.overrideWith((ref) async => counts),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('草稿段只按 status=0 查，不叠加任何链路过滤', (tester) async {
    final api = await _pumpOrderList(tester);

    api.listQueries.clear();
    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();

    expect(api.listQueries, isNotEmpty, reason: '选中草稿段应立即发请求');
    final query = api.listQueries.last;
    expect(query['status'], 0);
    // 草稿 chain_status 恒为 0；再叠链路过滤就一张也查不出来。
    expect(query.containsKey('chain'), isFalse);
    expect(query.containsKey('chainGroup'), isFalse);
    expect(query.containsKey('closed'), isFalse);
  });

  testWidgets('草稿段计数来自 drafts/count，与新建页按钮同源', (tester) async {
    await _pumpOrderList(tester, counts: const DraftCounts(salesOrder: 7));

    // 计数形态（docs/00-项目准则/14-徽章与计数口径.md）：草稿是「我自己没写完的
    // 东西」，没人在等它 → 中性括号 `(7)`，不挂红色待办徽章。
    final draftSegment = find.byWidgetPredicate(
      (widget) => widget is UtenSegmentBadgeLabel && widget.label == '草稿',
    );
    expect(
      tester.widget<UtenSegmentBadgeLabel>(draftSegment).countForm,
      UtenSegmentCountForm.browsing,
    );
    expect(
      find.descendant(of: draftSegment, matching: find.text('(7)')),
      findsOneWidget,
    );
    expect(find.byType(UtenNotificationBadge), findsNothing);
  });

  testWidgets('草稿段下隐藏状态小类行（草稿本身就是状态）', (tester) async {
    await _pumpOrderList(tester);

    // 先点链路大类：小类行出现（草稿/已审/红冲/历史记录）。
    await tester.tap(find.text('待生产'));
    await tester.pumpAndSettle();
    expect(find.text('已审'), findsOneWidget);
    expect(find.text('历史记录'), findsOneWidget);

    // 切到大类「草稿」段（.first = 大类行；.last 会命中小类行里的同名段）。
    await tester.tap(find.text('草稿').first);
    await tester.pumpAndSettle();
    expect(find.text('已审'), findsNothing);
    expect(find.text('历史记录'), findsNothing);
  });

  testWidgets('?status=draft 深链直接落在草稿段并加载', (tester) async {
    final api = await _pumpOrderList(tester, initialStatus: 'draft');

    expect(api.listQueries, isNotEmpty, reason: '深链应免点击直接加载');
    expect(api.listQueries.last['status'], 0);
    expect(api.listQueries.last.containsKey('chainGroup'), isFalse);

    // 列表已渲染（不是「选择分类」引导占位）。
    final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<SalesDocListItem>,
      ),
    );
    expect(table.items.single.billNo, 'XD202609110001');
  });

  testWidgets('无 ?status 时仍是引导占位，不误发请求', (tester) async {
    final api = await _pumpOrderList(tester);

    expect(
      api.listQueries.where((q) => q.containsKey('status')),
      isEmpty,
      reason: '大类未选时不应发列表请求',
    );
    expect(find.textContaining('选择分类'), findsOneWidget);
  });
}

/// 记录 `/sales/orders` 列表请求的 query，用来断言「草稿段发了什么过滤」。
class _RecordingApi extends ApiClient {
  _RecordingApi() : super(Dio());

  final List<Map<String, dynamic>> listQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders') {
      listQueries.add(Map<String, dynamic>.from(query ?? const {}));
      return const <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'order-draft-1',
            'billNo': 'XD202609110001',
            'billDate': '2026-09-11',
            'clientId': 'client-1',
            'status': 0,
            'writable': true,
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    // stats / 名称解析等其它读：返回空结构即可。
    return const <String, dynamic>{'items': <Map<String, dynamic>>[]};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const <Map<String, dynamic>>[];
}
