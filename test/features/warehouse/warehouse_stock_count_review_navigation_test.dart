import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/stock/counts/models/stock_count_request.dart';
import 'package:uten_imp/features/stock/counts/pages/stock_count_review_page.dart';
import 'package:uten_imp/features/stock/counts/repositories/stock_count_request_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_task_center.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_task_center_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_badges.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

import '../../helpers/badge_summary_fixture.dart';
import 'workshop_material_test_support.dart';

typedef _Query = ({
  String? warehouse,
  String? keyword,
  String? status,
  int size,
});

class _Repo implements StockCountRequestRepository {
  int pending = 1;
  int approvals = 0;
  final queries = <_Query>[];
  Completer<StockCountRequest>? pendingDetail;
  Completer<StockCountRequest>? pendingApproval;

  StockCountRequest request([String status = 'PENDING']) => StockCountRequest(
    id: 'r-1',
    requestNo: 'PK20261001000001',
    warehouseId: 'bin-1',
    warehouseName: '注塑车间内料仓',
    reviewRoute: 'WAREHOUSE',
    status: status,
    version: 1,
    allowedActions: status == 'PENDING'
        ? const ['APPROVE', 'REJECT']
        : const [],
    lines: const [
      StockCountRequestLine(
        goodsId: 'g-1',
        goodsName: '塑料颗粒',
        unitName: 'kg',
        beforeQty: '0',
        targetQty: '100',
        deltaQty: '100',
        currentQty: '0',
      ),
    ],
  );

  @override
  Future<PagedResult<StockCountRequest>> list({
    String? reviewRoute,
    String? status,
    String? warehouseId,
    String? scopeWarehouseId,
    String? keyword,
    int page = 1,
    int size = 50,
  }) async {
    expect(reviewRoute, 'WAREHOUSE');
    expect(
      warehouseId,
      isNull,
    ); // Selected main warehouse must include children.
    queries.add((
      warehouse: scopeWarehouseId,
      keyword: keyword,
      status: status,
      size: size,
    ));
    return PagedResult(
      items: pending > 0 ? [request()] : [],
      page: page,
      size: size,
      total: pending,
      totalPages: 1,
    );
  }

  @override
  Future<StockCountRequest> detail(String id) async =>
      pendingDetail == null ? request() : await pendingDetail!.future;

  @override
  Future<StockCountRequest> approve(
    String id, {
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  }) async {
    approvals++;
    final result = pendingApproval == null
        ? request('APPROVED')
        : await pendingApproval!.future;
    pending = 0;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  Map<String, dynamic>? lastQuery;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastQuery = query;
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 1,
    };
  }
}

final _scope = StateProvider<WarehouseTaskScope>(
  (ref) => const WarehouseTaskScope.all(),
);

BadgeSummary _summary({
  int review = 1,
  int issue = 0,
  int returned = 0,
  int counting = 0,
}) => badgeSummaryFixture(
  entries: {
    BadgeEntry.warehouseStockCountReview: (review, 0),
    BadgeEntry.warehouseWorkshopMaterial: (issue + returned, counting),
  },
  facts: {
    BadgeFact.workshopMaterialPendingIssue: issue,
    BadgeFact.workshopMaterialPendingReturn: returned,
    BadgeFact.workshopMaterialCounting: counting,
  },
);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repo repo, {
  Set<String> permissions = const {Perm.stockCountWarehouseReview},
  BadgeSummary? summary,
  WarehouseTaskScope scope = const WarehouseTaskScope.all(),
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        stockCountRequestRepositoryProvider.overrideWithValue(repo),
        workshopMaterialRepositoryProvider.overrideWithValue(
          FakeWorkshopMaterialRepository(),
        ),
        warehouseTaskScopeProvider.overrideWith((ref) => ref.watch(_scope)),
        _scope.overrideWith((ref) => scope),
        fixedBadgeSummaryOverride(summary ?? _summary()),
        // ADR-149: 选了某个仓时任务中心计数来自同一汇总接口带 scopeWarehouseId; 这里给定那一份
        // (跟着全站汇总重拉, 与生产实现同一订阅关系)。
        warehouseScopedBadgesProvider.overrideWith((ref, selected) {
          final global = ref.watch(badgeSummaryProvider);
          // 模拟服务端按所选仓算出的那一份: 待审数 = 仓库审核队列当前张数。
          return selected.isAll ? global : _summary(review: repo.pending);
        }),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: WarehouseTaskCenterPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(WarehouseTaskCenterPage)),
  );
}

Finder _label(String text) => find.byWidgetPredicate(
  (w) => w is UtenSegmentBadgeLabel && w.label == text,
);

/// 2026-10-01 右上角「盘点审核」快捷按钮退役：办理路径 = 点「车间内料仓」
/// 大类 → 点「盘点审核」小类段。
Future<void> _openReviewSection(WidgetTester tester) async {
  await tester.tap(find.text('车间内料仓'));
  await tester.pumpAndSettle();
  await tester.tap(_label('盘点审核'));
  await tester.pumpAndSettle();
}

List<int> _redCounts(WidgetTester tester, Finder parent) => tester
    .widgetList<UtenNotificationBadge>(
      find.descendant(of: parent, matching: find.byType(UtenNotificationBadge)),
    )
    .map((badge) => badge.count)
    .toList();

void main() {
  testWidgets('审核入口与分类同源红1，点申请直接进入真正审核而非周期录入', (tester) async {
    final repo = _Repo();
    await _pump(tester, repo);
    // 快捷按钮已删除，红数只在「车间内料仓」分类上。
    expect(find.byKey(const Key('warehouse-count-review-entry')), findsNothing);
    expect(_redCounts(tester, _label('车间内料仓')), [1]);
    await _openReviewSection(tester);
    expect(find.byType(StockCountReviewPage), findsOneWidget);
    expect(find.byType(WmBinStatusSegment), findsNothing);
    expect(find.text('周期盘点'), findsNothing);
    expect(find.byKey(const Key('wm-task-direct-issue')), findsNothing);
    expect(find.text('PK20261001000001'), findsOneWidget);
    expect(_redCounts(tester, _label('盘点审核')), [1]);
    await tester.tap(find.text('查看明细'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stock-count-approve')), findsOneWidget);
    expect(find.text('返回审核列表'), findsOneWidget);
    await tester.tap(find.text('返回审核列表'));
    await tester.pumpAndSettle();
    expect(find.text('PK20261001000001'), findsOneWidget);
    expect(
      repo.queries.where((q) => q.size == 1),
      isEmpty,
    ); // ALL reuses summary.
  });

  testWidgets('无待审不画红0，真实周期盘点只画黄数并保持单独入口', (tester) async {
    final repo = _Repo()..pending = 0;
    await _pump(
      tester,
      repo,
      summary: _summary(review: 0, counting: 2),
      permissions: {Perm.stockCountWarehouseReview, Perm.workshopMaterialView},
    );
    await _openReviewSection(tester);
    expect(find.byType(UtenNotificationBadge), findsNothing);
    expect(_label('周期盘点'), findsOneWidget);
    expect(
      find.descendant(
        of: _label('周期盘点'),
        matching: find.byType(UtenInProgressBadge),
      ),
      findsOneWidget,
    );
    expect(find.text('暂无盘点申请'), findsOneWidget);
    await tester.tap(find.text('周期盘点'));
    await tester.pumpAndSettle();
    expect(find.byType(WmBinStatusSegment), findsOneWidget);
    await tester.tap(_label('盘点审核'));
    await tester.pumpAndSettle();
    expect(find.byType(StockCountReviewPage), findsOneWidget);
    expect(find.byType(WmBinStatusSegment), findsNothing);
  });

  testWidgets('未授权时没有审核入口、不请求其列表或scope待审数', (tester) async {
    final repo = _Repo();
    await _pump(
      tester,
      repo,
      permissions: {Perm.workshopMaterialIssue},
      scope: const WarehouseTaskScope.warehouse('main-warehouse'),
    );
    expect(find.byKey(const Key('warehouse-count-review-entry')), findsNothing);
    await tester.tap(find.text('车间内料仓'));
    await tester.pumpAndSettle();
    expect(find.text('盘点审核'), findsNothing);
    expect(find.text('周期盘点'), findsNothing);
    expect(repo.queries, isEmpty);
  });

  testWidgets('分类合并独立发退料和审核入口各一次，模块仍为6', (tester) async {
    final container = await _pump(
      tester,
      _Repo(),
      summary: _summary(issue: 3, returned: 2),
      permissions: {Perm.workshopMaterialIssue, Perm.stockCountWarehouseReview},
    );
    expect(_redCounts(tester, _label('车间内料仓')), [6]);
    expect(
      container.read(badgeSummaryProvider).moduleTodo(BadgeModule.warehouse),
      6,
    );
    await tester.tap(find.text('车间内料仓'));
    await tester.pumpAndSettle();
    expect(_redCounts(tester, _label('待发料')), [3]);
    expect(_redCounts(tester, _label('待收退回')), [2]);
    expect(_redCounts(tester, _label('盘点审核')), [1]);
  });

  testWidgets('同scope审核生效后自动返回并刷新队列、父子分类与快捷入口', (tester) async {
    final repo = _Repo()
      ..pendingDetail = Completer<StockCountRequest>()
      ..pendingApproval = Completer<StockCountRequest>();
    final container = await _pump(
      tester,
      repo,
      scope: const WarehouseTaskScope.warehouse('main-warehouse'),
      summary: _summary(review: 8),
    );
    // 选了仓: 大类数来自按所选仓汇总的那一份(1), 不是全站汇总(8)。
    expect(_redCounts(tester, _label('车间内料仓')), [1]);
    await _openReviewSection(tester);
    expect(_redCounts(tester, _label('盘点审核')), [1]);
    expect(repo.queries.every((q) => q.warehouse == 'main-warehouse'), isTrue);
    await tester.tap(find.text('查看明细'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    repo.pendingDetail!.complete(repo.request());
    await tester.pumpAndSettle();
    final listQueriesBeforeApprove = repo.queries
        .where((query) => query.size == 50)
        .length;
    await tester.tap(find.byKey(const Key('stock-count-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stock-count-review-confirm')));
    await tester.pump();
    expect(repo.approvals, 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    repo.pendingApproval!.complete(repo.request('APPROVED'));
    await tester.pumpAndSettle();
    expect(repo.approvals, 1);
    expect(find.text('返回审核列表'), findsNothing);
    expect(find.byKey(const Key('stock-count-approve')), findsNothing);
    // ADR-149: 不再用 list(size:1) 凑数, 计数只来自汇总; 审核成功触发汇总重拉,
    // 下一份汇总(全站与所选仓两份同时)带回 0 后红数消失。
    expect(repo.queries.where((q) => q.size == 1), isEmpty);
    final badges =
        container.read(badgeSummaryProvider.notifier)
            as FixedBadgeSummaryNotifier;
    expect(badges.refreshCalls, greaterThan(0));
    badges.emit(_summary(review: 0));
    await tester.pumpAndSettle();
    expect(find.byType(UtenNotificationBadge), findsNothing);
    expect(find.text('暂无盘点申请'), findsOneWidget);
    expect(
      repo.queries.where((query) => query.size == 50).length,
      greaterThan(listQueriesBeforeApprove),
    );
  });

  testWidgets('切换仓库范围清除原详情并拒绝旧范围迟到响应', (tester) async {
    final repo = _Repo();
    final container = await _pump(tester, repo);
    await _openReviewSection(tester);
    expect(repo.queries.every((q) => q.warehouse == null), isTrue);
    repo.pendingDetail = Completer<StockCountRequest>();
    await tester.tap(find.text('查看明细'));
    await tester.pump();
    container.read(_scope.notifier).state = const WarehouseTaskScope.warehouse(
      'other-main',
    );
    await tester.pumpAndSettle();
    repo.pendingDetail!.complete(repo.request());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stock-count-approve')), findsNothing);
    expect(find.text('返回审核列表'), findsNothing);
    expect(repo.queries.last.warehouse, 'other-main');
  });

  testWidgets('审批进行中切仓，迟到成功只刷新当前队列不恢复旧申请详情', (tester) async {
    final repo = _Repo()..pendingApproval = Completer<StockCountRequest>();
    final container = await _pump(tester, repo);
    await _openReviewSection(tester);
    await tester.tap(find.text('查看明细'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stock-count-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stock-count-review-confirm')));
    await tester.pump();
    expect(repo.approvals, 1);
    container.read(_scope.notifier).state = const WarehouseTaskScope.warehouse(
      'other-main',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(repo.queries.last.warehouse, 'other-main');
    repo.pendingApproval!.complete(repo.request('APPROVED'));
    await tester.pumpAndSettle();
    expect(find.text('返回审核列表'), findsNothing);
    expect(find.byKey(const Key('stock-count-approve')), findsNothing);
    expect(find.text('审核通过，库存已按盘点更新'), findsNothing);
    expect(find.text('暂无盘点申请'), findsOneWidget);
    // 迟到的成功也触发汇总重拉; 下一份汇总(按当前所选仓)带回 0 后红数消失。
    final badges =
        container.read(badgeSummaryProvider.notifier)
            as FixedBadgeSummaryNotifier;
    expect(badges.refreshCalls, greaterThan(0));
    badges.emit(_summary(review: 0));
    await tester.pumpAndSettle();
    expect(find.byType(UtenNotificationBadge), findsNothing);
  });

  test('list仓库范围与精确仓及搜索是独立参数', () async {
    final api = _Api();
    await StockCountRequestRepository(api).list(
      reviewRoute: 'WAREHOUSE',
      status: 'PENDING',
      warehouseId: 'bin',
      scopeWarehouseId: 'main',
      keyword: '颗粒',
      size: 1,
    );
    expect(api.lastQuery, {
      'reviewRoute': 'WAREHOUSE',
      'status': 'PENDING',
      'warehouseId': 'bin',
      'scopeWarehouseId': 'main',
      'keyword': '颗粒',
      'page': 1,
      'size': 1,
    });
  });
}
