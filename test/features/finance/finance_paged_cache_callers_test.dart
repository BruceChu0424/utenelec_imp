import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_asset_models.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/models/sales_quote_finance_review.dart';
import 'package:uten_imp/features/finance/payables/models/finance_payable.dart';
import 'package:uten_imp/features/finance/payables/models/supplier_settlement.dart';
import 'package:uten_imp/features/finance/payables/models/subcontract_loss_claim.dart';
import 'package:uten_imp/shared/sales_review/sales_order_review.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_page.dart';
import 'package:uten_imp/features/finance/pages/finance_reconciliation_page.dart';
import 'package:uten_imp/features/finance/pages/finance_quote_review_list_page.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_order_confirmation_page.dart';
import 'package:uten_imp/features/finance/pages/finance_procurement_approval_tasks_page.dart';
import 'package:uten_imp/features/finance/payables/pages/finance_payables_page.dart';
import 'package:uten_imp/features/finance/payables/widgets/supplier_settlement_panel.dart';
import 'package:uten_imp/features/finance/payables/widgets/subcontract_loss_claim_panel.dart';
import 'package:uten_imp/features/finance/widgets/finance_asset_ledger_panel.dart';
import 'package:uten_imp/features/finance/widgets/finance_asset_ui.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/uten_test_actions.dart';

class _Api extends ApiClient {
  _Api(this.endpoint) : super(Dio());
  final String endpoint;
  final readQueries = <Map<String, dynamic>>[];
  final countQueries = <Map<String, dynamic>>[];
  List<int> get reads => [
    for (final query in readQueries)
      if (endpoint != ApiEndpoints.salesQuoteFinanceReviewList ||
          query['state'] == 'pending')
        (query['page'] as num?)?.toInt() ?? 1,
  ];
  int pages = 3;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != endpoint) return {};
    final page = (query?['page'] as num?)?.toInt() ?? 1;
    final size = (query?['size'] as num?)?.toInt() ?? 20;
    if (size > 1) {
      readQueries.add({...?query});
    } else {
      countQueries.add({...?query});
    }
    return {
      'page': page,
      'size': size,
      'total': size == 1 ? 0 : size * pages,
      'totalPages': size == 1 ? 1 : pages,
      'summary': {'outstandingLocal': '1.000001', 'pendingLossCases': 1},
      'items': size == 1
          ? <Map<String, dynamic>>[]
          : [
              for (
                var index = (page - 1) * size + 1;
                index <= page * size;
                index++
              )
                {
                  'id': 'row-$index',
                  'orderId': 'order-$index',
                  'caseId': 'case-$index',
                  'quoteId': 'quote-$index',
                  'billNo': 'DOC-$index',
                  'wasteBillNo': 'LOSS-$index',
                  'billDate': '2026-10-26',
                  'direction': 'AR',
                  'orderType': 'PURCHASE',
                  'supplierName': '供应商$index',
                  'clientName': '客户$index',
                  'name': '资产$index',
                  'currencyCode': '001',
                  'currencyName': '人民币',
                  'status': path == '/finance/ar-ap' ? 0 : 'PENDING',
                  'totalOriginal': '999999999999.000001',
                  'totalLocal': '999999999999.000001',
                  'amount': '999999999999.000001',
                  'amountOriginal': path == '/finance/ar-ap'
                      ? 100.000001
                      : '999999999999.000001',
                  'outstandingOriginal': '999999999999.000001',
                  'outstandingLocal': '999999999999.000001',
                  'lineCount': 1,
                  'financeRejected': false,
                  'financeConfirmed': false,
                  'allowedActions': <String>[],
                },
            ],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async => {};
  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};
}

void main() {
  final cases = <({String name, Widget widget, String endpoint})>[
    (
      name: 'ar-ap ledger',
      widget: const FinanceArApPage(),
      endpoint: '/finance/ar-ap',
    ),
    (
      name: 'account reconciliation',
      widget: const FinanceReconciliationPage(),
      endpoint: '/finance/reconciliations',
    ),
    (
      name: 'quote review',
      widget: const FinanceQuoteReviewListPage(),
      endpoint: ApiEndpoints.salesQuoteFinanceReviewList,
    ),
    (
      name: 'sales confirmation',
      widget: const FinanceSalesOrderConfirmationPage(),
      endpoint: ApiEndpoints.salesOrderFinanceConfirmationPending,
    ),
    (
      name: 'procurement approval',
      widget: const FinanceProcurementApprovalTasksPage(),
      endpoint: ApiEndpoints.financeProcurementApprovalTasks,
    ),
    (
      name: 'payables full summary',
      widget: const FinancePayablesPage(),
      endpoint: '/finance/payables',
    ),
    (
      name: 'supplier settlement',
      widget: const SupplierSettlementPanel(),
      endpoint: '/finance/supplier-settlements',
    ),
    (
      name: 'loss claims',
      widget: const SubcontractLossClaimPanel(),
      endpoint: '/finance/subcontract-loss-claims',
    ),
    (
      name: 'asset ledger',
      widget: const FinanceAssetLedgerPanel(
        ledger: FinanceAssetLedger.fixedAsset,
        policyReady: true,
        refreshToken: 0,
        capabilities: FinanceAssetCapabilities(
          canView: true,
          canEdit: false,
          canApprove: false,
          canPost: false,
          canDispose: false,
          canManagePeriod: false,
        ),
      ),
      endpoint: '/finance/fixed-assets',
    ),
  ];
  for (final scenario in cases) {
    testWidgets(
      '${scenario.name} completes bounded batches and scrolls without reads',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        await setUtenTestSurfaceSize(tester, const Size(1700, 1100));
        addTearDown(() => setUtenTestSurfaceSize(tester, null));
        final api = _Api(scenario.endpoint);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(prefs),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'finance-cache-caller'),
              ),
              currentPermissionsProvider.overrideWithValue({
                Perm.financeViewAll,
                Perm.arApLedgerView,
                Perm.accountView,
                Perm.accountBalanceView,
                Perm.accountFlowView,
                Perm.salesQuoteFinanceView,
                Perm.salesOrderFinanceView,
                Perm.financeOrderApprovalView,
                Perm.supplierSettlementView,
              }),
              isSuperAdminProvider.overrideWithValue(true),
              fixedBadgeSummaryOverride(badgeSummaryFixture()),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              home: Scaffold(body: scenario.widget),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final finder = find.byWidgetPredicate(
          (widget) =>
              widget is MasterDataTableView && widget.onPageChange != null,
        );
        MasterDataTableView<dynamic> table() => tester.widget(finder.first);
        expect(table().error, isNull);
        expect(api.reads, [1, 2, 3], reason: api.readQueries.toString());
        if (scenario.endpoint == ApiEndpoints.salesQuoteFinanceReviewList) {
          final counts = api.countQueries
              .where((query) => query['state'] != 'pending')
              .toList();
          expect(counts, hasLength(1));
          expect(counts.single['state'], 'returned');
          expect(counts.single['page'], 1);
          expect(counts.single['size'], 1);
          expect(
            api.readQueries.every((query) => query['state'] == 'pending'),
            isTrue,
          );
        }
        final batchSize = api.readQueries.first['size'] as int? ?? 20;
        String lastId(int number) => switch (scenario.endpoint) {
          // The quote endpoint's public wire identity is `id`, which its DTO
          // exposes as quoteId; retain that source instead of the unused alias.
          ApiEndpoints.salesQuoteFinanceReviewList => 'row-$number',
          ApiEndpoints.salesOrderFinanceConfirmationPending => 'order-$number',
          ApiEndpoints.financeProcurementApprovalTasks => 'case-$number',
          _ => 'row-$number',
        };
        expect(table().items, hasLength(batchSize * 3));
        expect(table().items.map(_idOf).toSet(), hasLength(batchSize * 3));
        expect(_idOf(table().items.last), lastId(batchSize * 3));
        expect(table().currentPage, 1);
        expect(table().totalPages, 1);
        expect(table().expensiveRowMounts, isFalse);
        await tester.drag(finder.first, const Offset(0, -900));
        await tester.pumpAndSettle();
        expect(api.reads, [1, 2, 3]);
        await tester.drag(finder.first, const Offset(0, 900));
        await tester.pumpAndSettle();
        expect(table().currentPage, 1);
        expect(api.reads, [1, 2, 3]);
        expect(
          find.byKey(const ValueKey('master-table-page-next')),
          findsNothing,
        );
        // A new data revision is read completely, with the original bounded
        // batch size. Its full tail is already local before any scrolling.
        api.pages = 80;
        final beforeLargerRead = api.reads.length;
        table().onRetry!();
        await tester.pumpAndSettle();
        expect(api.reads.skip(beforeLargerRead), [
          for (var p = 1; p <= 80; p++) p,
        ]);
        expect(table().items, hasLength(batchSize * 80));
        expect(table().items.map(_idOf).toSet(), hasLength(batchSize * 80));
        expect(_idOf(table().items.last), lastId(batchSize * 80));
        final beforeScroll = api.reads.length;
        await tester.drag(finder.first, const Offset(0, -1800));
        await tester.pumpAndSettle();
        expect(api.reads, hasLength(beforeScroll));
        final beforeRefresh = api.reads.length;
        table().onRetry!();
        await tester.pumpAndSettle();
        expect(
          api.reads.skip(beforeRefresh),
          [for (var page = 1; page <= 80; page++) page],
          reason: 'explicit refresh revalidates the whole original scope',
        );
        expect(table().items, hasLength(batchSize * 80));
        expect(table().currentPage, 1);
        expect(table().totalPages, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

String _idOf(Object? row) => switch (row) {
  ArApLedgerItem(:final id) => id,
  ReconciliationItem(:final id) => id,
  SalesQuoteFinanceListItem(:final quoteId) => quoteId,
  SalesOrderFinancePendingItem(:final orderId) => orderId,
  FinanceProcurementApprovalTask(:final caseId) => caseId,
  FinancePayableItem(:final id) => id,
  SupplierSettlementSummary(:final id) => id,
  SubcontractLossClaimSummary(:final id) => id,
  FinanceAssetSummary(:final id) => id,
  _ => throw StateError('Unexpected complete financial row ${row.runtimeType}'),
};
