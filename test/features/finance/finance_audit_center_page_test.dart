import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/shared/sales_review/sales_order_review.dart';
import 'package:uten_imp/features/finance/pages/finance_audit_center_page.dart';
import 'package:uten_imp/features/finance/config/finance_requirement_names.dart';
import 'package:uten_imp/shared/sales_review/sales_order_review_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';
import '../../support/master_dictionary_fixture.dart';

late SharedPreferences _preferences;
final _repositorySource =
    StateProvider<SalesOrderFinanceConfirmationRepository?>((ref) => null);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  for (final scenario in [
    (group:'shipment', permission:Perm.salesShipmentFinanceView, path:'/sales/shipments', field:'stage', value:'FINANCE_HISTORY'),
    (group:'procurement', permission:Perm.financeOrderApprovalView, path:'/finance/procurement-approvals/history', field:'status', value:'HISTORY'),
    (group:'arrival', permission:Perm.financeOrderApprovalView, path:'/finance/procurement-arrival-exceptions/tasks', field:'status', value:'PROCESSED'),
    (group:'iqc', permission:Perm.procurementIqcRejectionView, path:'/procurement/iqc-rejections', field:'status', value:'TERMINAL'),
  ]) {
    testWidgets('${scenario.group} history selects the completed server query without preloading working rows', (tester) async {
      final api = _EmptyAuditApi();
      await tester.pumpWidget(_app(FinanceAuditCenterPage(initialSegment:scenario.group), {scenario.permission}, api:api, emptyCounts:true));
      await tester.pumpAndSettle();
      api.requests.clear();
      await selectFilterSegment(tester,'历史记录');
      await tester.pumpAndSettle();
      final rows = api.requests.where((request)=>request.path==scenario.path).toList();
      expect(rows, hasLength(1));
      expect(rows.single.query?[scenario.field], scenario.value);
      expect(api.requests.where((request)=>request.query?['status']=='PENDING' || request.query?['status']=='ACTIVE' || request.query?['financeAudit']==0), isEmpty);
      expect(tester.takeException(),isNull);
    });
  }

  testWidgets('a fast category click adopts the prepared default queue once', (
    tester,
  ) async {
    final pending = Completer<SalesOrderFinancePendingPage>();
    final repository = _EmptyConfirmationRepository()..nextPending = pending;
    await tester.pumpWidget(
      _app(
        const FinanceAuditCenterPage(),
        {Perm.salesOrderFinanceView},
        repository: repository,
        emptyCounts: true,
      ),
    );
    await tester.pump();
    expect(find.byType(UtenFilterPlaceholder), findsOneWidget);
    await selectFilterSegment(tester, '销售订单确认');
    await tester.pump();
    expect(
      repository.pendingQueries.where((query) => query == (false, false, null)),
      hasLength(1),
    );
    pending.complete(
      const SalesOrderFinancePendingPage(
        items: [],
        page: 1,
        size: 20,
        total: 0,
        totalPages: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('sales-order-finance-desktop-table')),
      findsOneWidget,
    );
    expect(
      repository.pendingQueries.where((query) => query == (false, false, null)),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-category gateway replacement retires queued preparation', (
    tester,
  ) async {
    final oldPending = Completer<SalesOrderFinancePendingPage>();
    final nextPending = Completer<SalesOrderFinancePendingPage>();
    final first = _EmptyConfirmationRepository()..nextPending = oldPending;
    final next = _EmptyConfirmationRepository()..nextPending = nextPending;
    await tester.pumpWidget(
      _app(
        const FinanceAuditCenterPage(),
        {Perm.salesOrderFinanceView},
        repository: first,
        dynamicRepository: true,
        emptyCounts: true,
      ),
    );
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FinanceAuditCenterPage)),
    );
    container.read(_repositorySource.notifier).state = next;
    await tester.pump();
    await tester.pump();
    await selectFilterSegment(tester, '销售订单确认');
    await tester.pump();
    oldPending.complete(
      SalesOrderFinancePendingPage(
        items: [
          SalesOrderFinancePendingItem.fromJson({
            'orderId': 'old',
            'billNo': 'OLD',
          }),
        ],
        page: 1,
        size: 20,
        total: 1,
        totalPages: 1,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('OLD'), findsNothing);
    expect(
      next.pendingQueries.where((query) => query == (false, false, null)),
      hasLength(1),
    );
    nextPending.complete(
      SalesOrderFinancePendingPage(
        items: [
          SalesOrderFinancePendingItem.fromJson({
            'orderId': 'new',
            'billNo': 'NEW',
          }),
        ],
        page: 1,
        size: 20,
        total: 1,
        totalPages: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('NEW'), findsWidgets);
    expect(find.text('OLD'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sales parent and pending category share one reactive badge without separate count requests',
    (tester) async {
      final repository = _EmptyConfirmationRepository();
      await tester.pumpWidget(
        _app(
          const FinanceAuditCenterPage(initialSegment: 'salesConfirm'),
          {Perm.salesOrderFinanceView},
          repository: repository,
        ),
      );
      await tester.pumpAndSettle();
      int? countOf(String value) => tester
          .widgetList<UtenFilterToolbar<String>>(
            find.byType(UtenFilterToolbar<String>),
          )
          .expand((t) => t.segments)
          .firstWhere((s) => s.value == value)
          .count;
      expect(countOf('salesConfirm'), 3);
      expect(countOf('pending'), 3);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FinanceAuditCenterPage)),
        listen: false,
      );
      (container.read(badgeSummaryProvider.notifier)
              as FixedBadgeSummaryNotifier)
          .emit(badgeSummaryFixture(facts: {BadgeFact.salesOrderFinance: 5}));
      await tester.pumpAndSettle();
      expect(countOf('salesConfirm'), 5);
      expect(countOf('pending'), 5);
      expect(repository.countRequests, 0);
    },
  );

  for (final target in [
    ('shipment', Perm.salesShipmentFinanceView, 'pending', 2),
    ('arrival', Perm.financeOrderApprovalView, 'PENDING_FINANCE', 4),
  ]) {
    testWidgets(
      'finance ${target.$1} pending child keeps its parent summary badge',
      (tester) async {
        await tester.pumpWidget(
          _app(
            FinanceAuditCenterPage(initialSegment: target.$1),
            {target.$2},
            api: _EmptyAuditApi(),
            arrivalCount: 4,
          ),
        );
        await tester.pumpAndSettle();
        final segment = tester
            .widgetList<UtenFilterToolbar<String>>(
              find.byType(UtenFilterToolbar<String>),
            )
            .expand((t) => t.segments)
            .firstWhere((s) => s.value == target.$3);
        expect(segment.count, target.$4);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [375.0, 1200.0]) {
    testWidgets(
      'unselected audit category keeps its instruction and discloses badge help inline ($width)',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repository = _EmptyConfirmationRepository();
        await tester.pumpWidget(
          _app(
            const FinanceAuditCenterPage(),
            const {Perm.salesOrderFinanceView},
            repository: repository,
            emptyCounts: true,
          ),
        );
        await tester.pumpAndSettle();
        const instruction = '在上方选择分类后开始审核';
        const help = '分段右侧数字徽章为该队列的待办数量';
        expect(find.byType(UtenFilterPlaceholder), findsOneWidget);
        expect(find.text(instruction), findsOneWidget);
        expect(find.text(help), findsNothing);
        final hint = find.byWidgetPredicate(
          (widget) => widget is UtenFieldHintIcon && widget.info == help,
        );
        final headingRect = tester.getRect(find.text(instruction));
        final hintRect = tester.getRect(hint);
        expect(hintRect.left, greaterThanOrEqualTo(headingRect.right));
        expect(
          (hintRect.center.dy - headingRect.center.dy).abs(),
          lessThan(16),
        );
        await tester.tap(hint);
        await tester.pumpAndSettle();
        expect(find.text(help), findsOneWidget);
        expect(find.text(instruction), findsOneWidget);
        expect(
          repository.pendingQueries,
          isEmpty,
          reason:
              'An unselected category must not fetch unseen working or historical rows',
        );
        expect(
          find.byKey(const Key('sales-order-finance-desktop-table')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'header refresh waits for the visible queue and prevents repeats',
    (tester) async {
      final repository = _EmptyConfirmationRepository();
      await tester.pumpWidget(
        _app(
          const FinanceAuditCenterPage(initialSegment: 'salesConfirm'),
          const {Perm.salesOrderFinanceView},
          repository: repository,
        ),
      );
      await tester.pumpAndSettle();
      final pending = Completer<SalesOrderFinancePendingPage>();
      repository.nextPending = pending;
      final refresh = find.byKey(const Key('finance-audit-center-refresh'));
      await tester.tap(refresh);
      await tester.pump();
      await tester.pump();
      final requests = repository.pendingQueries.length;
      expect(tester.widget<UtenRefreshButton>(refresh).busy, isTrue);
      await tester.tap(refresh);
      await tester.pump();
      expect(repository.pendingQueries.length, requests);

      pending.complete(
        const SalesOrderFinancePendingPage(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<UtenRefreshButton>(refresh).busy, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving a refreshing queue releases the header wait', (
    tester,
  ) async {
    final repository = _EmptyConfirmationRepository();
    await tester.pumpWidget(
      _app(
        const FinanceAuditCenterPage(initialSegment: 'salesConfirm'),
        const {Perm.salesOrderFinanceView},
        repository: repository,
      ),
    );
    await tester.pumpAndSettle();
    final pending = Completer<SalesOrderFinancePendingPage>();
    repository.nextPending = pending;
    final refresh = tester.widget<UtenRefreshButton>(
      find.byKey(const Key('finance-audit-center-refresh')),
    );
    var finished = false;
    final operation = Future<void>.sync(refresh.onRefresh).then((_) {
      finished = true;
    });
    await tester.pump();
    expect(finished, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await operation;
    expect(finished, isTrue);
    pending.complete(
      const SalesOrderFinancePendingPage(
        items: [],
        page: 1,
        size: 20,
        total: 0,
        totalPages: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('segments follow permissions; first red queue auto-selected', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const FinanceAuditCenterPage(), const {
        Perm.salesOrderFinanceView,
        Perm.salesShipmentFinanceView,
      }, repository: _EmptyConfirmationRepository()),
    );
    await tester.pumpAndSettle();

    expect(find.text('销售订单确认'), findsOneWidget);
    expect(find.text('订单修改确认'), findsNothing);
    expect(
      find.text(FinanceRequirementNames.customerShipmentReview),
      findsOneWidget,
    );
    // 无权限的队列不出现。
    expect(find.text('订货审批'), findsNothing);
    expect(find.text('超量到货审批'), findsNothing);
    expect(find.text('IQC 退回贷项'), findsNothing);
    // 2026-10-04 起进页面自动选中第一条红徽章队列（销售订单确认，红3）：
    // 内容区不再是引导空态，直接渲染该队列（小类行可见）。
    expect(find.text('在上方选择分类后开始审核'), findsNothing);
    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('业务审核中心'), findsOneWidget);
  });

  testWidgets('without any audit permission the center explains itself', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const FinanceAuditCenterPage(), const {}));
    await tester.pumpAndSettle();
    expect(find.text('暂无已授权的审核队列，请联系财务主管开通。'), findsOneWidget);
    expect(find.text('销售订单确认'), findsNothing);
  });

  testWidgets(
    'old salesChanges deep link selects the unified modification status',
    (tester) async {
      final repository = _EmptyConfirmationRepository();
      await tester.pumpWidget(
        _app(
          const FinanceAuditCenterPage(initialSegment: 'salesChanges'),
          const {Perm.salesOrderFinanceView},
          repository: repository,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('订单修改确认'), findsNothing);
      expect(find.text('待确认'), findsOneWidget);
      final table = tester
          .widget<MasterDataTableView<SalesOrderFinancePendingItem>>(
            find.byKey(const Key('sales-order-finance-desktop-table')),
          );
      expect(table.filters['status'], 'changes');
      expect(repository.changesFilters, contains(true));
      expect(find.text('目前没有订单修改待确认的销售订单'), findsOneWidget);
    },
  );

  testWidgets('initialSegment deep link embeds the sales confirm queue', (
    tester,
  ) async {
    final repository = _EmptyConfirmationRepository();
    await tester.pumpWidget(
      _app(
        const FinanceAuditCenterPage(initialSegment: 'salesConfirm'),
        const {Perm.salesOrderFinanceView},
        repository: repository,
      ),
    );
    await tester.pumpAndSettle();

    // 分段内容 = 队列页自带的小类行（待确认/已驳回），不再是引导空态。
    expect(find.text('在上方选择分类后开始审核'), findsNothing);
    expect(find.text('待确认'), findsOneWidget);
    final table = tester
        .widget<MasterDataTableView<SalesOrderFinancePendingItem>>(
          find.byKey(const Key('sales-order-finance-desktop-table')),
        );
    expect(table.filters['status'], isNull);
    expect(table.facets['status']!.map((bucket) => bucket.value), [
      'initial',
      'changes',
    ]);
    expect(repository.pendingQueries, contains((false, false, null)));
    // 非当前分类在收起面板内；实际切换仍使用原队列的服务端查询。
    await selectFilterSegment(tester, '已驳回');
    await tester.pumpAndSettle();
    expect(find.text('已驳回'), findsOneWidget);
    expect(repository.pendingQueries.last, (true, false, null));
    expect(find.text('历史单据'), findsNothing);
    final beforeHistory = repository.pendingQueries.length;
    await selectFilterSegment(tester, '历史记录');
    await tester.pumpAndSettle();
    expect(find.text('历史单据'), findsOneWidget);
    expect(repository.pendingQueries.last, (false, true, null));
    expect(
      repository.pendingQueries.skip(beforeHistory),
      [(false, true, null)],
      reason: 'History does not also reload the working or returned queues',
    );
    expect(find.text('待确认'), findsNothing);
    tester
        .widget<UtenSegmentRow<String>>(
          find.byKey(const Key('finance-audit-center-segments')),
        )
        .onSelectionChanged!({'salesConfirm'});
    await tester.pumpAndSettle();
    expect(repository.pendingQueries.last, (false, false, null));
    // 嵌入形态不渲染队列页自己的 AppBar（只有审核中心一个标题）。
    expect(find.text('销售订单财务确认'), findsNothing);
  });
}

Widget _app(
  Widget page,
  Set<String> permissions, {
  SalesOrderFinanceConfirmationRepository? repository,
  bool emptyCounts = false,
  int arrivalCount = 0,
  ApiClient? api,
  bool dynamicRepository = false,
}) {
  return ProviderScope(
    overrides: [
      emptyMasterDictionaryFixture(),
      sharedPreferencesProvider.overrideWithValue(_preferences),
      if (api != null) apiClientProvider.overrideWithValue(api),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
      fixedBadgeSummaryOverride(
        badgeSummaryFixture(
          facts: {
            BadgeFact.salesOrderFinance: emptyCounts ? 0 : 3,
            BadgeFact.shipmentFinance: emptyCounts ? 0 : 2,
            BadgeFact.procurementApproval: 0,
            BadgeFact.financeArrivalException: arrivalCount,
          },
        ),
      ),
      if (dynamicRepository)
        _repositorySource.overrideWith((ref) => repository),
      if (dynamicRepository)
        salesOrderFinanceConfirmationRepositoryProvider.overrideWith(
          (ref) => ref.watch(_repositorySource)!,
        ),
      if (repository != null && !dynamicRepository)
        salesOrderFinanceConfirmationRepositoryProvider.overrideWithValue(
          repository,
        ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: page,
    ),
  );
}

class _EmptyConfirmationRepository
    implements SalesOrderFinanceConfirmationRepository {
  final List<bool?> changesFilters = [];
  final pendingQueries = <(bool?, bool, bool?)>[];
  Completer<SalesOrderFinancePendingPage>? nextPending;
  @override
  Future<List<MasterFacetBucket>> billNoFacets({
    bool? rejected,
    String? keyword,
    bool? changesOnly,
    bool confirmed = false,
  }) async => const []; // 2026-09-25 单号列统一：页面 facets 静默降级。
  @override
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
    bool? rejected,
    String? keyword,
    bool? changesOnly,
    bool confirmed = false,
    String? sort,
    String? order,
    String? billNo,
  }) async {
    changesFilters.add(changesOnly);
    pendingQueries.add((rejected, confirmed, changesOnly));
    if (size != 1) {
      final pending = nextPending;
      nextPending = null;
      if (pending != null) return pending.future;
    }
    return const SalesOrderFinancePendingPage(
      items: [],
      page: 1,
      size: 20,
      total: 0,
      totalPages: 1,
    );
  }

  int countRequests = 0;
  @override
  Future<int> pendingCount({bool? changesOnly}) async {
    countRequests++;
    return 0;
  }

  @override
  Future<SalesOrderFinanceReview> review(String orderId) async {
    throw UnimplementedError();
  }

  @override
  Future<void> confirm(
    String orderId, {
    String? remark,
    int? expectedRevision,
    String? expectedClaimId,
  }) async {}

  @override
  Future<void> confirmBatch(
    Iterable<String> orderIds, {
    String? remark,
    Map<String, int>? expectedRevisions,
    Map<String, String>? expectedClaimIds,
  }) async {}

  @override
  Future<void> reject(
    String orderId, {
    required String reason,
    int? expectedRevision,
    String? expectedClaimId,
  }) async {}
}

class _EmptyAuditApi extends ApiClient {
  _EmptyAuditApi() : super(Dio());
  final requests = <({String path, Map<String,dynamic>? query})>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async { requests.add((path:path,query:query));return {'items': <dynamic>[], 'total': 0, 'totalPages': 1, 'page': 1}; }
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}
