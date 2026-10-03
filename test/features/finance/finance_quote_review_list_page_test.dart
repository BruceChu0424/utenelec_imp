// 报价核价队列(ADR-134)：三个分段(待核价红 / 已核价 / 已退回黄)、按分段向服务端取数、
// 状态说明文案、空态、双击进入核价详情后刷新；路由守卫与 hub 目录登记。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/hub_catalog.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/finance/models/sales_quote_finance_review.dart';
import 'package:uten_imp/features/finance/pages/finance_quote_review_list_page.dart';
import 'package:uten_imp/features/finance/repositories/sales_quote_finance_review_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

import '../../helpers/badge_summary_fixture.dart';

class _FakeRepo implements SalesQuoteFinanceReviewRepository {
  final List<(SalesQuoteFinanceState, int, String?)> calls = [];

  /// 与服务端 QuoteFinanceListItem record 字段逐字一致。
  static SalesQuoteFinanceListItem _item(
    String id, {
    String? returnReason,
    String? confirmedBy,
    String? orderNo,
    int needsPrice = 0,
    bool resubmitted = false,
    String? claimedBy,
    bool claimedByMe = false,
  }) => SalesQuoteFinanceListItem.fromJson({
    'id': id,
    'billNo': 'XB-$id',
    'billDate': '2026-09-26',
    'clientName': '客户$id',
    'sellerName': '张销售',
    'makerName': '张销售',
    'submittedAt': '2026-09-27T01:00:00Z',
    'lineCount': 3,
    'pricePendingCount': needsPrice,
    'totalOriginal': '1234.5',
    'clientFileCurrency': 'USD',
    'statusBucket': 'PENDING_FINANCE',
    'reviewRevision': 2,
    'resubmitted': resubmitted,
    'financeReturnReason': returnReason,
    'financeReturnedAt': null,
    'financeConfirmedAt': null,
    'financeConfirmedByName': confirmedBy,
    'convertedOrderNo': orderNo,
    'claimedByName': claimedBy,
    'claimedByMe': claimedByMe,
  });

  @override
  Future<PagedResult<SalesQuoteFinanceListItem>> list({
    required SalesQuoteFinanceState state,
    int page = 1,
    int size = 20,
    String? keyword,
  }) async {
    calls.add((state, size, keyword));
    final items = switch (state) {
      SalesQuoteFinanceState.pending => [
        _item('p1', needsPrice: 2, claimedBy: '王会计'),
        _item('p2', resubmitted: true, claimedByMe: true),
      ],
      SalesQuoteFinanceState.confirmed => [
        _item('c1', confirmedBy: '王会计'),
        _item('c2', confirmedBy: '王会计', orderNo: 'XD-9'),
      ],
      SalesQuoteFinanceState.returned => [_item('r1', returnReason: '客户要改数量')],
    };
    final filtered = keyword == null
        ? items
        : items.where((i) => i.billNo.contains(keyword)).toList();
    return PagedResult(
      items: size == 1 ? filtered.take(1).toList() : filtered,
      page: page,
      size: size,
      total: filtered.length,
      totalPages: 1,
    );
  }

  @override
  Future<SalesQuoteFinanceReview> review(String quoteId) =>
      throw UnimplementedError();

  @override
  Future<SalesQuoteFinanceReview> saveEdits(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
    required SalesQuoteFinanceHeader header,
    List<SalesQuoteFinanceLineEdit> lines = const [],
  }) => throw UnimplementedError();

  @override
  Future<void> returnToSales(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
    required String reason,
  }) => throw UnimplementedError();

  @override
  Future<void> confirm(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
  }) => throw UnimplementedError();

  @override
  Future<SalesQuoteFinanceReview> reopen(
    String quoteId, {
    required int expectedRevision,
  }) => throw UnimplementedError();
}

Future<_FakeRepo> _pump(
  WidgetTester tester, {
  Size size = const Size(1600, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _FakeRepo();
  final router = GoRouter(
    initialLocation: '/finance/quote-review',
    routes: [
      GoRoute(
        path: '/finance/quote-review',
        builder: (_, _) => const FinanceQuoteReviewListPage(),
      ),
      GoRoute(
        path: '/finance/quote-review/:id',
        builder: (context, state) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('detail-${state.pathParameters['id']}'),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
        ),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        salesQuoteFinanceReviewRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.salesQuoteFinanceView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(entries: {BadgeEntry.financeQuoteReview: (2, 0)}),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

UtenSegmentBadgeLabel _segment(WidgetTester tester, String label) =>
    tester.widget<UtenSegmentBadgeLabel>(
      find.byWidgetPredicate(
        (w) => w is UtenSegmentBadgeLabel && w.label == label,
      ),
    );

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  test('route guard and hub catalog register the quote review pages', () {
    expect(requiredAnyPermFor(RouteName.financeQuoteReview), const [
      Perm.salesQuoteFinanceView,
    ]);
    expect(requiredAnyPermFor(RoutePath.financeQuoteReview('q-1')), const [
      Perm.salesQuoteFinanceView,
    ]);
    expect(requiredAllPermsFor(RoutePath.financeQuoteReview('q-1')), isEmpty);
    expect(
      hubCardLocations[RouteName.finance],
      contains(RouteName.financeQuoteReview),
    );
    expect(
      hubUnionRequiredAny(RouteName.finance),
      contains(Perm.salesQuoteFinanceView),
    );
  });

  test('page permission scope maps to the V742 seeded surface', () {
    for (final path in [
      RouteName.financeQuoteReview,
      RoutePath.financeQuoteReview('q-1'),
    ]) {
      final scope = pagePermissionScopeFor(path);
      expect(scope?.surfaceKey, 'finance.sales-quote-review', reason: path);
      expect(scope?.title, '销售报价核价');
    }
    expect(
      pagePermissionScopeBySurfaceKey('finance.sales-quote-review')?.title,
      '销售报价核价',
    );
    final seeds = Directory('server/src/main/resources/db/migration')
        .listSync()
        .whereType<File>()
        .where((f) => RegExp(r'V742__').hasMatch(f.path))
        .map((f) => f.readAsStringSync())
        .join();
    expect(seeds, contains("'finance.sales-quote-review'"));
  });

  testWidgets('pending tab is red from the badge entry; returned is yellow', (
    tester,
  ) async {
    final repo = await _pump(tester);
    expect(repo.calls.first.$1, SalesQuoteFinanceState.returned);
    expect(
      repo.calls.map((c) => c.$1),
      contains(SalesQuoteFinanceState.pending),
    );
    final pending = _segment(tester, '待核价');
    expect(pending.count, 2);
    expect(pending.countForm, UtenSegmentCountForm.actionable);
    final returned = _segment(tester, '已退回');
    expect(returned.count, 1);
    expect(returned.countForm, UtenSegmentCountForm.inProgress);
    expect(_segment(tester, '已核价').count, isNull);

    expect(find.text('XB-p1'), findsOneWidget);
    expect(find.text('待核价 · 有 2 行没有标价 · 王会计 正在核价'), findsWidgets);
    expect(find.text('销售改后重新提交 · 你正在核价'), findsWidgets);
    expect(find.text('1234.50'), findsWidgets);
  });

  testWidgets('switching tabs queries the server state and explains rows', (
    tester,
  ) async {
    final repo = await _pump(tester);
    await tester.tap(find.text('已核价'));
    await tester.pumpAndSettle();
    expect(repo.calls.last.$1, SalesQuoteFinanceState.confirmed);
    expect(find.text('已核价 · 王会计'), findsWidgets);
    expect(find.text('已转订货单 XD-9'), findsWidgets);

    await tester.tap(find.text('已退回'));
    await tester.pumpAndSettle();
    expect(repo.calls.last.$1, SalesQuoteFinanceState.returned);
    expect(find.text('已退回: 客户要改数量'), findsWidgets);
  });

  testWidgets('double tap opens the review and refreshes after a decision', (
    tester,
  ) async {
    final repo = await _pump(tester);
    final callsBefore = repo.calls.length;
    await tester.tap(find.text('XB-p1'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('XB-p1'));
    await tester.pumpAndSettle();
    expect(find.text('detail-p1'), findsOneWidget);
    await tester.tap(find.text('detail-p1'));
    await tester.pumpAndSettle();
    expect(find.text('XB-p1'), findsOneWidget);
    expect(repo.calls.length, greaterThan(callsBefore));
  });

  testWidgets('compact layout shows cards with an explicit price button', (
    tester,
  ) async {
    await _pump(tester, size: const Size(420, 900));
    // 2026-09-29「大小屏共用一张表」：窄屏由表格内建卡片形态接管（统一挂
    // 表格 key）；点卡片即打开（原卡片上的显式按钮退役）。
    expect(
      find.byKey(const Key('quote-finance-desktop-table')),
      findsOneWidget,
    );
    await tester.tap(find.text('XB-p2'));
    await tester.pumpAndSettle();
    expect(find.text('detail-p2'), findsOneWidget);
  });
}
