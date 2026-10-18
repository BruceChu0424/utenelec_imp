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
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';
import '../../../support/filter_segment_tap.dart';

Future<_RecordingApi> _pumpOrderList(
  WidgetTester tester, {
  String? initialStatus,
  bool initialHistory = false,
  SalesDocType docType = SalesDocType.order,
  DraftCounts counts = const DraftCounts(salesOrder: 2),
  Set<String> permissions = const {},
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _RecordingApi();
  final path = '/sales/${docType.pathSegment}';
  final location = initialStatus == null ? path : '$path?status=$initialStatus';
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: path,
        builder: (_, state) => SalesDocListPage(
          docType: docType,
          initialStatus: state.uri.queryParameters['status'],
          initialHistory: initialHistory,
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
        currentPermissionsProvider.overrideWithValue(permissions),
        draftCountsProvider.overrideWith((ref) => counts),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets(
    'completed shipment stages stay under history and history status clearing keeps its parent',
    (tester) async {
      final api = await _pumpOrderList(
        tester,
        docType: SalesDocType.shipment,
        counts: DraftCounts.empty,
      );
      expect(find.text('已出库'), findsNothing);
      expect(find.text('已反审'), findsNothing);
      expect(find.text('全部'), findsNothing);
      await tester.tap(find.text('历史记录'));
      await tester.pumpAndSettle();
      MasterDataTableView<SalesDocListItem> table() =>
          tester.widget(find.byType(MasterDataTableView<SalesDocListItem>));
      table().onFilterChanged('status', SalesShipmentStage.shipped);
      await tester.pumpAndSettle();
      expect(api.listQueries.last['stage'], SalesShipmentStage.shipped);
      expect(
        find.byKey(const Key('sales-doc-history-time-shipments')),
        findsOneWidget,
      );
      table().onFilterChanged('status', null);
      await tester.pumpAndSettle();
      expect(api.listQueries.last.containsKey('stage'), isFalse);
      expect(
        find.byKey(const Key('sales-doc-history-time-shipments')),
        findsOneWidget,
      );
      await tester.tap(find.text('已审'));
      await tester.pumpAndSettle();
      expect(
        api.listQueries.last['stage'],
        SalesShipmentStage.financeApproved,
        reason: '财务已通过但尚未出库必须保留活动入口',
      );
      table().onFilterChanged('status', null);
      await tester.pumpAndSettle();
      expect(api.listQueries.last['stage'], 'ACTIVE');
      expect(table().filters['status'], isNull);
      expect(
        find.byKey(const Key('sales-doc-history-time-shipments')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'quote activity keeps customer and conversion work while completed pricing buckets are historical',
    (tester) async {
      final api = await _pumpOrderList(
        tester,
        docType: SalesDocType.quote,
        counts: DraftCounts.empty,
      );
      await selectFilterSegment(tester, '待办与进行中');
      await tester.pumpAndSettle();
      expect(api.listQueries.last['bucket'], 'ACTIVE');
      MasterDataTableView<SalesDocListItem> table() =>
          tester.widget(find.byType(MasterDataTableView<SalesDocListItem>));
      table().onFilterChanged('status', SalesQuoteStage.approved);
      await tester.pumpAndSettle();
      expect(api.listQueries.last['bucket'], SalesQuoteStage.approved);
      expect(
        find.byKey(const Key('sales-doc-history-time-quotes')),
        findsOneWidget,
      );
      table().onFilterChanged('status', null);
      await tester.pumpAndSettle();
      expect(api.listQueries.last.containsKey('bucket'), isFalse);
      expect(
        find.byKey(const Key('sales-doc-history-time-quotes')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'ordinary order list preserves exact amount digits and masks stale Exact',
    (tester) async {
      await _pumpOrderList(tester, initialHistory: true);
      final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
        find.byType(MasterDataTableView<SalesDocListItem>),
      );
      final amount = table.columns.singleWhere((c) => c.key == 'total');
      for (final raw in ['0.0001', '99999999999999.9999']) {
        final row = SalesDocListItem.fromJson({
          'id': 'exact',
          'currencyId': 'usd',
          'totalOriginal': double.parse(raw),
          'totalOriginalExact': raw,
        });
        expect(amount.value(row), '$raw 美金');
      }
      expect(
        amount.value(
          SalesDocListItem.fromJson({
            'id': 'masked',
            'priceMasked': true,
            'totalOriginal': 0,
            'totalOriginalExact': '99999999999999.9999',
          }),
        ),
        '***',
      );
      expect(
        amount.value(
          SalesDocListItem.fromJson({
            'id': 'unknown',
            'totalOriginal': null,
            'totalOriginalExact': '99999999999999.9999',
          }),
        ),
        '—',
      );
    },
  );
  testWidgets('草稿段只按 status=0 查，不叠加任何链路过滤', (tester) async {
    final api = await _pumpOrderList(tester);

    // 2026-10-04 起红数「草稿」段进页面自动选中：status=0 查询随挂载即发。
    expect(api.listQueries, isNotEmpty, reason: '草稿段自动选中应立即发请求');
    final query = api.listQueries.last;
    expect(query['status'], 0);
    // 草稿 chain_status 恒为 0；再叠链路过滤就一张也查不出来。
    expect(query.containsKey('chain'), isFalse);
    expect(query.containsKey('chainGroup'), isFalse);
    expect(query.containsKey('closed'), isFalse);
  });

  testWidgets('草稿段计数来自 drafts/count，与新建页按钮同源', (tester) async {
    await _pumpOrderList(tester, counts: const DraftCounts(salesOrder: 7));

    // 计数形态（docs/00-项目准则/14-徽章与计数口径.md §四之七）：草稿是本人没提交的活，
    // hub 卡是红徽章，列表「草稿」段同形——红色待办徽章 `7`，不再是中性括号。
    final draftSegment = find.byWidgetPredicate(
      (widget) => widget is UtenSegmentBadgeLabel && widget.label == '草稿',
    );
    expect(
      tester.widget<UtenSegmentBadgeLabel>(draftSegment).countForm,
      // 2026-09-21: hub 卡草稿是红徽章, 列表「草稿」段同形(父有红徽章子也要红)。
      UtenSegmentCountForm.actionable,
    );
    expect(
      find.descendant(of: draftSegment, matching: find.text('7')),
      findsOneWidget,
    );
    // 整条工具条只有「草稿」一枚红徽章: 待生产 / 生产中 走黄色进行中徽章(ADR-100,
    // 球在生产手上), 待发货 / 本月完成 走中性括号, 都不许染红。
    expect(find.byType(UtenNotificationBadge), findsOneWidget);
  });

  testWidgets('订货阶段共用状态表头，草稿与历史保留主入口', (tester) async {
    await _pumpOrderList(
      tester,
      permissions: const {
        Perm.salesOrderCreate,
        Perm.salesQuoteConvert,
        Perm.salesShipmentCreate,
      },
    );

    // 链路大类不再另起状态子分类；筛选由状态表头承担。
    await tester.tap(find.text('待生产'));
    await tester.pumpAndSettle();
    expect(find.text('已审'), findsNothing);
    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('新建'), findsOneWidget);
    expect(find.text('从报价引入'), findsOneWidget);
    expect(find.text('批量发货'), findsOneWidget);

    // 草稿仍是独立主阶段；历史入口始终可达。
    await tester.tap(find.text('草稿').first);
    await tester.pumpAndSettle();
    expect(find.text('已审'), findsNothing);
    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('可发货置顶'), findsNothing);
    expect(find.byKey(const Key('sales-list-create')), findsOneWidget);
    expect(find.text('从报价引入'), findsNothing);
    expect(find.text('批量发货'), findsNothing);
  });

  testWidgets('状态表头筛选及清除保持当前生产阶段并下推服务端', (tester) async {
    final api = await _pumpOrderList(tester);
    await tester.tap(find.text('待生产'));
    await tester.pumpAndSettle();

    MasterDataTableView<SalesDocListItem> table() =>
        tester.widget(find.byType(MasterDataTableView<SalesDocListItem>));
    table().onFilterChanged('status', '1');
    await tester.pumpAndSettle();
    expect(api.listQueries.last['status'], 1);
    expect(api.listQueries.last['chainGroup'], 'pending');
    expect(api.listQueries.last['page'], 1);

    table().onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(api.listQueries.last.containsKey('status'), isFalse);
    expect(api.listQueries.last['chainGroup'], 'pending');
    expect(table().filters['status'], isNull);
  });

  testWidgets('历史状态筛选清除后继续历史范围，切阶段清除旧状态', (tester) async {
    final api = await _pumpOrderList(tester);
    await tester.tap(find.text('历史记录'));
    await tester.pumpAndSettle();

    MasterDataTableView<SalesDocListItem> table() =>
        tester.widget(find.byType(MasterDataTableView<SalesDocListItem>));
    table().onFilterChanged('status', '-1');
    await tester.pumpAndSettle();
    expect(api.listQueries.last['status'], -1);
    expect(api.listQueries.last.containsKey('chainGroup'), isFalse);

    table().onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(api.listQueries.last.containsKey('status'), isFalse);
    expect(api.listQueries.last.containsKey('chainGroup'), isFalse);

    table().onFilterChanged('status', '-1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('生产中'));
    await tester.pumpAndSettle();
    expect(api.listQueries.last.containsKey('status'), isFalse);
    expect(api.listQueries.last['chainGroup'], 'production');
  });

  testWidgets('?status=draft 深链直接落在草稿段并加载', (tester) async {
    final api = await _pumpOrderList(tester, initialStatus: 'draft');

    expect(api.listQueries, isNotEmpty, reason: '深链应免点击直接加载');
    expect(api.listQueries.last['status'], 0);
    expect(api.listQueries.last.containsKey('chainGroup'), isFalse);

    // 列表已渲染（不是「选择分类」引导占位）。
    expect(find.text('XD202609110001'), findsOneWidget);
    expect(find.textContaining('选择分类'), findsNothing);
  });

  testWidgets('预选历史记录直接请求全部订单，不叠加草稿或链路过滤', (tester) async {
    final api = await _pumpOrderList(tester, initialHistory: true);
    expect(api.listQueries, hasLength(1));
    final query = api.listQueries.single;
    expect(query['page'], 1);
    expect(query.containsKey('status'), isFalse);
    expect(query.containsKey('chain'), isFalse);
    expect(query.containsKey('chainGroup'), isFalse);
    expect(find.text('XD202609110001'), findsOneWidget);
  });

  testWidgets('历史其它出货预选入口免点击加载', (tester) async {
    final api = await _pumpOrderList(
      tester,
      initialHistory: true,
      docType: SalesDocType.otherShipment,
    );
    expect(api.listQueries, hasLength(1));
    expect(api.listQueries.single['page'], 1);
    expect(api.listQueries.single.containsKey('status'), isFalse);
    expect(find.text('XD202609110001'), findsOneWidget);
    expect(find.textContaining('选择状态'), findsNothing);
  });

  testWidgets('无 ?status 时红数「草稿」段自动选中并直接加载', (tester) async {
    final api = await _pumpOrderList(tester);

    // 2026-10-04 起进页面自动选中第一条红徽章大类（草稿，红2）：
    // 直接按 status=0 加载列表，不再停在「选择分类」引导占位。
    expect(api.listQueries.last['status'], 0);
    expect(find.textContaining('选择分类'), findsNothing);
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
    if (path == '/sales/orders' ||
        path == '/sales/other-shipments' ||
        path == '/sales/shipments' ||
        path == '/sales/quotes') {
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
  }) async => path == ApiEndpoints.currenciesDict
      ? const [
          {'id': 'usd', 'name': 'US Dollar', 'code': 'USD'},
        ]
      : const <Map<String, dynamic>>[];
}
