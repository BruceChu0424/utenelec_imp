import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_order_progress.dart';
import 'package:uten_imp/features/sales/pages/sales_order_progress_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/documents/imported_document_policy.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../../support/page_resume_test_bridge.dart';

/// 页面 build 期捕获本页路径（onPageResume 返回即刷新用），需包一层 GoRouter。
Widget _host() {
  final router = GoRouter(
    initialLocation: '/sales/progress',
    routes: [
      GoRoute(
        path: '/sales/progress',
        builder: (_, _) => const SalesOrderProgressPage(),
      ),
      GoRoute(
        path: '/sales/orders/:id',
        builder: (_, _) => const Scaffold(body: Text('ORDER-DETAIL')),
      ),
    ],
  );
  addTearDown(router.dispose);
  return PageResumeTestBridge(
    router: router,
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets(
    'progress page shows REJECTED filter and rejection details while clearing only completion notices',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ProgressApi();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'sales-test'),
            ),
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesOrderView,
            }),
          ],
          child: _host(),
        ),
      );
      await tester.pumpAndSettle();

      // 主阶段加载整组；财务驳回作为同表的状态筛选下推服务端。
      await tester.tap(find.text('进行中'));
      await tester.pumpAndSettle();
      expect(
        api.progressQueries.map((q) => q['stage']),
        contains('IN_PROGRESS'),
        reason: '大类直接按组拉，不该退化成前端多拼几次单阶段请求',
      );
      expect(api.progressQueries.last['stage'], 'IN_PROGRESS');
      expect(api.progressQueries.last['originScope'], 'CURRENT');
      expect(api.facetQueries.last['originScope'], 'CURRENT');
      final table = tester.widget<MasterDataTableView<SalesOrderProgressRow>>(
        find.byType(MasterDataTableView<SalesOrderProgressRow>),
      );
      table.onFilterChanged('stage', 'REJECTED');
      await tester.pumpAndSettle();
      expect(api.progressQueries.last['stage'], 'REJECTED');

      // 2026-09-05 起列表为 MasterDataTableView：阶段列为语义底色单元格
      //（驳回人/时间在订货单详情页展示，不再进表格行）。
      expect(find.text('财务驳回'), findsWidgets);
      expect(find.text('SO-REJECTED'), findsOneWidget);
      expect(
        table.columns.map((column) => column.key),
        isNot(contains('productionPct')),
      );
      expect(find.text('生产进度'), findsNothing);
      expect(find.textContaining('结账方式错误'), findsOneWidget);
      expect(api.readBySourceQueries, hasLength(1));
      final events = api.readBySourceQueries.single['events'] as String;
      expect(events, contains('PRODUCTION_FINISHED_INBOUND'));
      expect(events, contains('PRODUCTION_REPORTED'));
      expect(events, isNot(contains('SALES_ORDER_FINANCE_REJECTED')));
    },
  );

  // 两层分类 + 三形态计数(ADR-100 / docs/00-项目准则/14-徽章与计数口径.md)。
  //
  // 大类行四段(草稿 / 进行中 / 可发货 / 历史记录，2026-09-25 草稿置顶)：
  // 「草稿」红 = 本人开了头没交出去的单；其余每个大类同时挂两枚徽章：
  // 黄 = 本类里还在别人手上跑的单，红 = 本类里等销售动手的单，两枚都是各小类之和。
  // 小类行要等大类选中后才出现；里面「财务驳回」「可分批发货」红(销售要改单/要开单)，
  // 其余四档黄(球在生产/财务/仓库手上)。
  // 黄徽章与红徽章同规矩：归零整枚不渲染，不留 `(0)` 占位。
  testWidgets(
    'main groups retain badges; state header queries all pages within the selected group',
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

      Finder segment(String label) => find.byWidgetPredicate(
        (widget) => widget is UtenSegmentBadgeLabel && widget.label == label,
      );

      // 大类行四段：草稿置顶(红) + 三个链路大类，六个阶段不再一字排开。
      expect(segment('草稿'), findsOneWidget);
      final draftSeg = tester.widget<UtenSegmentBadgeLabel>(segment('草稿'));
      expect(draftSeg.count, 2, reason: '草稿红数 = stage-counts 的 DRAFT 桶');
      expect(draftSeg.countForm, UtenSegmentCountForm.actionable);
      expect(
        find.descendant(
          of: segment('草稿'),
          matching: find.byType(UtenNotificationBadge),
        ),
        findsOneWidget,
        reason: '草稿是本人待办，走红通知徽章',
      );
      expect(segment('进行中'), findsOneWidget);
      expect(segment('可发货'), findsOneWidget);
      expect(segment('历史记录'), findsOneWidget);
      // 小类要等大类选中后才出现（草稿段无小类）。
      expect(segment('财务驳回'), findsNothing);
      expect(segment('生产中'), findsNothing);

      // 「进行中」大类 = 红 1(财务驳回) + 黄 3(生产中; 待排产 0 不计)。
      final inProgressGroup = tester.widget<UtenSegmentBadgeLabel>(
        segment('进行中'),
      );
      expect(inProgressGroup.count, 1, reason: '红 = 本类里等销售动手的单');
      expect(inProgressGroup.countForm, UtenSegmentCountForm.actionable);
      expect(inProgressGroup.inProgressCount, 3, reason: '黄 = 本类里还在跑的单');
      expect(
        find.descendant(
          of: segment('进行中'),
          matching: find.byType(UtenNotificationBadge),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: segment('进行中'),
          matching: find.byType(UtenInProgressBadge),
        ),
        findsOneWidget,
      );

      // 「可发货」整类都是 0：两枚徽章都缩回，不留 `(0)` 占位。
      expect(tester.widget<UtenSegmentBadgeLabel>(segment('可发货')).count, 0);
      expect(
        find.descendant(
          of: segment('可发货'),
          matching: find.byType(UtenNotificationBadge),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: segment('可发货'), matching: find.text('(0)')),
        findsNothing,
      );

      // 点开大类后不再多一条子阶段；固定状态桶可查询其他页的阶段。
      await tester.tap(find.text('进行中'));
      await tester.pumpAndSettle();
      expect(segment('财务驳回'), findsNothing);
      expect(segment('生产中'), findsNothing);
      expect(find.text('SO-PRODUCING'), findsNothing);
      MasterDataTableView<SalesOrderProgressRow> table() => tester.widget(
        find.byType(MasterDataTableView<SalesOrderProgressRow>),
      );
      expect(table().facets['stage']!.map((bucket) => bucket.value), [
        'REJECTED',
        'PENDING',
        'PRODUCING',
      ]);
      table().onFilterChanged('stage', 'PRODUCING');
      await tester.pumpAndSettle();
      expect(api.progressQueries.last['stage'], 'PRODUCING');
      expect(api.progressQueries.last['page'], 1);
      expect(find.text('SO-PRODUCING'), findsOneWidget);

      table().onFilterChanged('stage', null);
      await tester.pumpAndSettle();
      expect(api.progressQueries.last['stage'], 'IN_PROGRESS');
      final queryCount = api.progressQueries.length;
      table().onFilterChanged('stage', 'WAREHOUSE_PENDING');
      await tester.pumpAndSettle();
      expect(
        api.progressQueries.length,
        queryCount,
        reason: '状态过滤不能把记录带出当前主工作阶段',
      );

      table().onFilterChanged('stage', 'REJECTED');
      await tester.pumpAndSettle();
      // 主工作阶段切换清除旧状态，新的状态桶仍包含当前页以外的档位。
      await tester.tap(find.text('可发货'));
      await tester.pumpAndSettle();
      expect(api.progressQueries.last['stage'], 'READY_TO_SHIP');
      expect(table().filters['stage'], isNull);
      expect(table().facets['stage']!.map((bucket) => bucket.value), [
        'SHIPPABLE',
        'SHIPMENT_PENDING',
        'WAREHOUSE_PENDING',
      ]);
      expect(segment('可分批发货'), findsNothing);
      expect(segment('财务驳回'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history segment defaults to last three months; 全部 loads ALL orders (stage empty)',
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

      // 2026-10-04 起红数「草稿」阶段进页面自动选中（stage=DRAFT 直查）。
      expect(api.progressQueries, [
        {'originScope': 'CURRENT', 'page': 1, 'size': 50, 'stage': 'DRAFT'},
      ]);

      await tester.tap(find.text('历史记录'));
      await tester.pumpAndSettle();
      // 历史门默认近三个月（2026-10-24 口径）：选中即按最近三个月加载，
      // 时间胶囊仍可切「全部」或具体时间段。
      expect(api.progressQueries, hasLength(2));
      // 历史记录不带 stage 参数（repo 空串省略）= 后端默认全部订单。
      expect(api.progressQueries.last.containsKey('stage'), isFalse);
      expect(api.progressQueries.last['originScope'], 'ALL');
      expect(api.facetQueries.last['originScope'], 'ALL');
      final defaultRange = UtenHistoryTimeValue.lastThreeMonths().range!;
      expect(
        api.progressQueries.last['dateFrom'],
        ChinaDateTime.formatDate(defaultRange.start),
      );
      expect(
        api.progressQueries.last['dateTo'],
        ChinaDateTime.formatDate(defaultRange.end),
      );

      // 「全部」不再默认选中：点它切换为不限时间，全量重查（不带日期）。
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(api.progressQueries, hasLength(3));
      expect(api.progressQueries.last.containsKey('stage'), isFalse);
      expect(api.progressQueries.last.containsKey('dateFrom'), isFalse);
      expect(api.progressQueries.last.containsKey('dateTo'), isFalse);

      // 终态/被驳回订单都能出现在历史里；取消单（finance 未确认）显示「已中止」
      // 而非「等待财务审核」——终态优先于财务闸门。
      expect(find.text('SO-REJECTED'), findsOneWidget);
      expect(find.text('SO-CANCELED'), findsOneWidget);
      expect(find.text('已中止'), findsOneWidget);
      expect(find.text('SO-CLOSED'), findsOneWidget);
      expect(find.text('已结案'), findsOneWidget);
      expect(find.text('等待财务审核'), findsNothing);

      tester
          .widget<UtenHistoryTimeFilter>(find.byType(UtenHistoryTimeFilter))
          .onChanged(
            UtenHistoryTimeValue.range(
              DateTimeRange(
                start: DateTime(2026, 8),
                end: DateTime(2026, 8, 31),
              ),
            ),
          );
      await tester.pumpAndSettle();
      MasterDataTableView<SalesOrderProgressRow> table() => tester.widget(
        find.byType(MasterDataTableView<SalesOrderProgressRow>),
      );
      table().onFilterChanged('stage', 'REJECTED');
      await tester.pumpAndSettle();
      expect(api.progressQueries.last['stage'], 'REJECTED');
      table().onFilterChanged('stage', null);
      await tester.pumpAndSettle();
      expect(api.progressQueries.last.containsKey('stage'), isFalse);
      expect(api.progressQueries.last['dateFrom'], '2026-08-01');
      expect(api.progressQueries.last['dateTo'], '2026-08-31');
    },
  );

  // 2026-09-25 用户口径「进行中前面加个草稿」：新建订货单中途退出后，单据只存在于
  // 草稿态（chain_status 恒为 0，落不进任何链路大类），此前在本页找不到。
  // 草稿段按 stage='DRAFT' 直查；草稿行没有进度可看，行点击直达编辑页继续办单。
  testWidgets(
    'draft segment queries stage=DRAFT and routes rows to the edit page',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ProgressApi();

      String? editRouteId;
      final router = GoRouter(
        initialLocation: '/sales/progress',
        routes: [
          GoRoute(
            path: '/sales/progress',
            builder: (_, _) => const SalesOrderProgressPage(),
          ),
          GoRoute(
            path: '/sales/orders/:id/edit',
            builder: (_, state) {
              editRouteId = state.pathParameters['id'];
              return const Scaffold(body: Center(child: Text('EDIT-STUB')));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesOrderView,
            }),
          ],
          child: PageResumeTestBridge(
            router: router,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Finder segment(String label) => find.byWidgetPredicate(
        (widget) => widget is UtenSegmentBadgeLabel && widget.label == label,
      );

      // 选中草稿段：按 stage='DRAFT' 直查，不叠加链路大类过滤。
      await tester.tap(segment('草稿'));
      await tester.pumpAndSettle();
      expect(api.progressQueries.single['stage'], 'DRAFT');

      // 草稿段没有小类行（草稿不是链路阶段，无子档可分）。
      expect(segment('待排产'), findsNothing);
      expect(segment('财务驳回'), findsNothing);

      // 草稿行状态列显示「草稿」，不因 finance_confirmed=false 错显「等待财务审核」。
      expect(find.text('SO-DRAFT'), findsOneWidget);
      expect(find.text('草稿'), findsWidgets);
      expect(find.text('等待财务审核'), findsNothing);

      // 双击行直达编辑页（表格单击选中、双击打开；草稿没有进度详情可看）。
      await tester.tap(find.text('SO-DRAFT'));
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(find.text('SO-DRAFT'));
      await tester.pumpAndSettle();
      expect(editRouteId, 'order-draft');
      expect(find.text('EDIT-STUB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('legacy raw drafts and rejections only open historical details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ProgressApi(includeLegacy: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.salesOrderView,
            Perm.salesOrderEdit,
            Perm.salesOrderDelete,
            Perm.salesOrderCancel,
            Perm.salesShipmentCreate,
          }),
        ],
        child: _host(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SO-LEGACY-DRAFT'), findsNothing);
    await tester.tap(find.text('历史记录'));
    await tester.pumpAndSettle();
    expect(api.progressQueries.last['originScope'], 'ALL');
    expect(api.facetQueries.last['originScope'], 'ALL');
    final table = tester.widget<MasterDataTableView<SalesOrderProgressRow>>(
      find.byType(MasterDataTableView<SalesOrderProgressRow>),
    );
    final legacyRows = table.items.where((row) => row.historyReadOnly).toList();
    expect(legacyRows, hasLength(2));
    for (final row in legacyRows) {
      expect(
        table.columns.firstWhere((c) => c.key == 'stage').value(row),
        importedBusinessHistoryLabel,
      );
      expect(table.idOf!(row), isNull);
      expect(table.rowColor!(row), isNull);
      expect(row.shippable, isFalse);
      expect(salesProgressShipmentInFlightText(row), isNull);
      expect(
        table.rowMenuBuilder!(row).whereType<UtenMenuItem>().map(
          (e) => e.label,
        ),
        ['打开订单详情'],
        reason:
            'all mutation permissions are granted, so only archive policy blocks actions',
      );
    }
    final draft = legacyRows.firstWhere((row) => row.stage == 'DRAFT');
    expect(draft.reservedQty, 10);
    expect(draft.shipmentInFlightQty, 10);
    // Real table double-click must route a raw DRAFT archive to detail, not edit.
    await tester.tap(find.text('SO-LEGACY-DRAFT'));
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(find.text('SO-LEGACY-DRAFT'));
    await tester.pumpAndSettle();
    expect(find.text('ORDER-DETAIL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _ProgressApi extends ApiClient {
  _ProgressApi({this.includeLegacy = false}) : super(Dio());

  final bool includeLegacy;

  final List<Map<String, dynamic>> readBySourceQueries = [];
  final List<Map<String, dynamic>> progressQueries = [];
  final List<Map<String, dynamic>> facetQueries = [];

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
        if (includeLegacy && query?['originScope'] == 'ALL') ...[
          {
            ..._row(
              'legacy-draft',
              'SO-LEGACY-DRAFT',
              stage: 'DRAFT',
              financeConfirmed: false,
            ),
            'legacyImported': true,
            'reservedQty': 10,
            'shipmentDraftQty': 4,
            'shipmentApprovedQty': 6,
          },
          {
            ..._row(
              'legacy-rejected',
              'SO-LEGACY-REJECTED',
              stage: 'REJECTED',
              financeRejected: true,
            ),
            'legacyImported': true,
          },
        ],
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
        _row('order-producing', 'SO-PRODUCING', stage: 'PRODUCING'),
      ];
      // 草稿单只在 stage='DRAFT' 可见（与后端 :stage='DRAFT' 门控同口径）：
      // 历史记录与其余阶段都不含草稿。草稿 finance_confirmed=false——若阶段列
      // 不先判草稿再判财务闸门，会错显「等待财务审核」。
      if (stage == 'DRAFT') {
        allRows.add(
          _row(
            'order-draft',
            'SO-DRAFT',
            stage: 'DRAFT',
            financeConfirmed: false,
          ),
        );
      }
      // 大类码展开成一组阶段(与后端 progressStagePredicate 同口径)；
      // stage 非空且非大类 = 单阶段精确匹配；'' = 历史记录全量(含终态)。
      const groups = <String, List<String>>{
        'IN_PROGRESS': ['REJECTED', 'PENDING', 'PRODUCING'],
        'READY_TO_SHIP': ['SHIPPABLE', 'SHIPMENT_PENDING', 'WAREHOUSE_PENDING'],
      };
      final wanted = groups[stage];
      final rows = stage.isEmpty
          ? allRows
          : allRows
                .where(
                  (r) => wanted == null
                      ? r['stage'] == stage
                      : wanted.contains(r['stage']),
                )
                .toList();
      return {
        // 进行中整组首屏只给驳回；生产中在另一页，表头须下推服务端才找得到。
        'items': stage == 'IN_PROGRESS' ? rows.take(1).toList() : rows,
        'page': 1,
        'size': 50,
        'total': rows.length,
        'totalPages': stage == 'IN_PROGRESS' ? 2 : 1,
      };
    }
    if (path == '/sales/orders/progress/stage-counts') {
      // PRODUCING 特意非零、PENDING 特意为零: 同一条分段行里同时钉住
      // 「有数亮黄徽章」与「归零整枚缩回」两半口径。DRAFT = 草稿段红徽章
      // （progressStageCounts 随 :stage='DRAFT' 一并带回草稿桶）。
      return const {
        'TASK_DRAFT': 2,
        'TASK_REJECTED': 1,
        'TASK_PRODUCING': 3,
        'DRAFT': 2,
        'REJECTED': 1,
        'PENDING': 0,
        'PRODUCING': 3,
        'SHIPPABLE': 0,
        'SHIPMENT_PENDING': 0,
        'WAREHOUSE_PENDING': 0,
        'SHIPPED': 0,
      };
    }
    if (path == '/sales/orders/progress/facets') {
      facetQueries.add(Map<String, dynamic>.from(query ?? const {}));
      return const {'billNo': <dynamic>[]};
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
