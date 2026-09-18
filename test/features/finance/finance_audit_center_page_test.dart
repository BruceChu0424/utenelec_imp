import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/models/sales_order_finance_confirmation.dart';
import 'package:uten_imp/features/finance/pages/finance_audit_center_page.dart';
import 'package:uten_imp/features/finance/providers/finance_procurement_approval_count_provider.dart';
import 'package:uten_imp/features/finance/providers/sales_order_finance_confirmation_count_provider.dart';
import 'package:uten_imp/features/finance/repositories/sales_order_finance_confirmation_repository.dart';
import 'package:uten_imp/features/warehouse/providers/procurement_inbound_count_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sales_shipment_finance_count_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  testWidgets('segments follow permissions; nothing preselected', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const FinanceAuditCenterPage(), const {
        Perm.salesOrderFinanceView,
        Perm.financeShipmentAudit,
      }),
    );
    await tester.pumpAndSettle();

    expect(find.text('销售订单确认'), findsOneWidget);
    expect(find.text('订单修改确认'), findsOneWidget);
    expect(find.text('出货审核'), findsOneWidget);
    // 无权限的队列不出现。
    expect(find.text('订货审批'), findsNothing);
    expect(find.text('超量到货审批'), findsNothing);
    expect(find.text('IQC 退回贷项'), findsNothing);
    // 进页面不预选大类：内容区是引导空态。
    expect(find.text('在上方选择分类后开始审核'), findsOneWidget);
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

  testWidgets('initialSegment deep link embeds the sales confirm queue', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const FinanceAuditCenterPage(initialSegment: 'salesConfirm'),
        const {Perm.salesOrderFinanceView},
        repository: _EmptyConfirmationRepository(),
      ),
    );
    await tester.pumpAndSettle();

    // 分段内容 = 队列页自带的小类行（待确认/已驳回），不再是引导空态。
    expect(find.text('在上方选择分类后开始审核'), findsNothing);
    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('已驳回'), findsOneWidget);
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
      salesOrderFinanceConfirmationCountProvider.overrideWith((ref) async => 3),
      salesOrderFinanceQueueCountProvider(false).overrideWith((ref) async => 3),
      salesOrderFinanceQueueCountProvider(true).overrideWith((ref) async => 1),
      salesShipmentFinanceCountProvider.overrideWith((ref) async => 2),
      financeProcurementApprovalCountProvider.overrideWith((ref) async => 0),
      financeArrivalExceptionCountProvider.overrideWith((ref) async => 0),
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
  @override
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
    bool? rejected,
    String? keyword,
    bool? changesOnly,
  }) async => const SalesOrderFinancePendingPage(
    items: [],
    page: 1,
    size: 20,
    total: 0,
    totalPages: 1,
  );

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
