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

class _Api extends ApiClient {
  _Api(this.endpoint) : super(Dio());
  final String endpoint;
  final reads = <int>[];
  int pages = 3;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != endpoint) return {};
    final page = (query?['page'] as num?)?.toInt() ?? 1;
    final size = (query?['size'] as num?)?.toInt() ?? 20;
    if (size > 1) reads.add(page);
    return {
      'page': page,
      'size': size,
      'total': size == 1 ? 0 : size * pages,
      'totalPages': size == 1 ? 1 : pages,
      'summary': {'outstandingLocal': '$page.000001', 'pendingLossCases': page},
      'items': size == 1
          ? <Map<String, dynamic>>[]
          : [
              {
                'id': 'row-$page',
                'orderId': 'order-$page',
                'caseId': 'case-$page',
                'quoteId': 'quote-$page',
                'billNo': 'DOC-$page',
                'wasteBillNo': 'LOSS-$page',
                'billDate': '2026-10-26',
                'direction': 'AR',
                'orderType': 'PURCHASE',
                'supplierName': '供应商$page',
                'clientName': '客户$page',
                'name': '资产$page',
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
      '${scenario.name} warms two following pages and reuses both directions',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        await tester.binding.setSurfaceSize(const Size(1700, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
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
        expect(api.reads, [1, 2, 3]);
        expect(table().currentPage, 1);
        expect(table().expensiveRowMounts, isFalse);
        await table().onPageChange!(2);
        await tester.pumpAndSettle();
        expect(table().currentPage, 2);
        expect(api.reads, [1, 2, 3]);
        await table().onPageChange!(1);
        await tester.pumpAndSettle();
        expect(table().currentPage, 1);
        expect(api.reads, [1, 2, 3]);
        // Direct last-page navigation prepares 78 as a leading buffer. It
        // must not become the default refresh target instead of visible 79.
        api.pages = 80;
        table().onRetry!();
        await tester.pumpAndSettle();
        final rows = table().rowsController!;
        rows.goToPage(79);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pumpAndSettle();
        expect(rows.visiblePage, 79);
        expect(api.reads, containsAll([79, 78, 77, 80]));
        expect(api.reads, isNot(contains(76)));
        final beforeRefresh = api.reads.length;
        table().onRetry!();
        await tester.pumpAndSettle();
        expect(
          api.reads.skip(beforeRefresh).first,
          79,
          reason: 'default retry/refresh reads the actual visible page',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
