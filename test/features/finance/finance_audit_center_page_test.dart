import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/models/sales_order_finance_confirmation.dart';
import 'package:uten_imp/features/finance/pages/finance_audit_center_page.dart';
import 'package:uten_imp/features/finance/providers/sales_order_finance_confirmation_count_provider.dart';
import 'package:uten_imp/features/finance/repositories/sales_order_finance_confirmation_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
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
    expect(find.text('出货审核'), findsOneWidget);
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
      expect(repository.changesFilters.last, isTrue);
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
    expect(repository.pendingQueries.last, (false, false, null));
    // 非当前分类在收起面板内；实际切换仍使用原队列的服务端查询。
    await selectFilterSegment(tester, '已驳回');
    await tester.pumpAndSettle();
    expect(find.text('已驳回'), findsOneWidget);
    expect(repository.pendingQueries.last, (true, false, null));
    await selectFilterSegment(tester, '已批准');
    await tester.pumpAndSettle();
    expect(find.text('已批准'), findsOneWidget);
    expect(repository.pendingQueries.last, (false, true, null));
    await selectFilterSegment(tester, '待确认');
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
}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(_preferences),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
      salesOrderFinanceQueueCountProvider(false).overrideWith((ref) async => 2),
      salesOrderFinanceQueueCountProvider(true).overrideWith((ref) async => 1),
      fixedBadgeSummaryOverride(
        badgeSummaryFixture(
          facts: {
            BadgeFact.salesOrderFinance: 3,
            BadgeFact.shipmentFinance: 2,
            BadgeFact.procurementApproval: 0,
            BadgeFact.financeArrivalException: 0,
          },
        ),
      ),
      if (repository != null)
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
    return const SalesOrderFinancePendingPage(
      items: [],
      page: 1,
      size: 20,
      total: 0,
      totalPages: 1,
    );
  }

  @override
  Future<int> pendingCount({bool? changesOnly}) async => 0;

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
