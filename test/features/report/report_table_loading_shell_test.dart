import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/inputs/uten_reference_picker_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/pages/finance_account_flow_page.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_overview_page.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/finance/pages/finance_statement_page.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/production/config/production_report_config.dart';
import 'package:uten_imp/features/production/pages/production_report_page.dart';
import 'package:uten_imp/features/production/pages/where_used_report_page.dart';
import 'package:uten_imp/features/purchase/config/purchase_report_config.dart';
import 'package:uten_imp/features/purchase/pages/purchase_report_table_page.dart';
import 'package:uten_imp/features/report/shared/report_filter_prefs.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_report_config.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_report_table_page.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_report_config.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/stock_ledger/material_trace_models.dart';

import '../../helpers/badge_summary_fixture.dart';

Map<String, dynamic> _report(String label) => {
  'columns': [
    {'key': 'serverField', 'label': label, 'type': 'text'},
  ],
  'rows': <Object?>[],
  'facets': <String, dynamic>{},
  'page': 1,
  'total': 0,
  'totalPages': 0,
};

class _Api extends ApiClient {
  _Api() : super(Dio());
  final pending = <Completer<Map<String, dynamic>>>[];
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/reports/where-used/materials') {
      return {
        'items': [
          {'id': 'material-1', 'code': 'MAT', 'name': '材料'},
        ],
        'total': 1,
        'page': 1,
        'totalPages': 1,
      };
    }
    if (path.contains('/reports/')) {
      queries.add({...?query});
      final gate = Completer<Map<String, dynamic>>();
      pending.add(gate);
      return gate.future;
    }
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

class _StatementPrefs extends FinanceStatementReportPrefsNotifier {
  @override
  ReportFilterPrefs build() => const ReportFilterPrefs(
    docType: 'AR',
    extra: {'partyId': 'party-1', 'view': 'flow'},
  );
}

class _AccountPrefs extends FinanceAccountFlowReportPrefsNotifier {
  @override
  ReportFilterPrefs build() => const ReportFilterPrefs(
    docType: 'statement',
    extra: {'accountId': 'account-1'},
  );
}

class _Names extends FinanceNameService {
  _Names(ApiClient api, {this.hold = false})
    : super(api, DioPaymentStyleRepository(api));
  final bool hold;
  final ready = Completer<void>();

  @override
  Future<void> ensureLoaded({
    bool refreshAccounts = false,
    bool includeCounterparties = true,
  }) => hold ? ready.future : Future<void>.value();

  @override
  Map<String, String> get accountEntries => {'account-1': '测试账户'};
}

Future<void> _mount(WidgetTester tester, Widget page, _Api api) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final names = _Names(api, hold: page is FinanceAccountFlowPage);
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'report-reader'),
        ),
        currentPermissionsProvider.overrideWithValue(const {}),
        isSuperAdminProvider.overrideWithValue(false),
        financeStatementReportPrefsProvider.overrideWith(_StatementPrefs.new),
        financeAccountFlowReportPrefsProvider.overrideWith(_AccountPrefs.new),
        financeNameServiceProvider.overrideWith((ref) => names),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('委外出入状况表按聚合值发送排序与筛选并保留导出条件', (tester) async {
    final api = _Api();
    await _mount(
      tester,
      const SubcontractReportTablePage(kind: SubcontractReportKind.inOutStatus),
      api,
    );
    Map<String, dynamic> response() => {
      ..._report('期末结存'),
      'columns': [
        {'key': 'closingQty', 'label': '期末结存', 'type': 'number'},
      ],
      'columnSearchKeys': ['closingQty'],
    };
    api.pending.single.complete(response());
    await tester.pumpAndSettle();
    await tester.tap(find.text('期末结存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从大到小'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(api.queries.last['sort'], 'closingQty');
    expect(api.queries.last['order'], 'desc');
    api.pending.last.complete(response());
    await tester.pumpAndSettle();
    await tester.tap(find.text('期末结存'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-column-keyword-input')),
      '>0',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(api.queries.last['f.search.closingQty'], '>0');
    expect(
      tester
          .widget<UtenExportButton>(find.byType(UtenExportButton))
          .queryParams['f.search.closingQty'],
      '>0',
    );
    api.pending.last.complete(response());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final entry in <(String, Widget)>[
    ('采购', const PurchaseReportTablePage(kind: PurchaseReportKind.detail)),
    (
      '委外',
      const SubcontractReportTablePage(kind: SubcontractReportKind.detail),
    ),
  ]) {
    testWidgets('${entry.$1}差异数表头条件发送服务端且打印导出沿用同一条件', (tester) async {
      final api = _Api();
      await _mount(tester, entry.$2, api);
      api.pending.single.complete({
        ..._report('差异数'),
        'columns': [
          {'key': 'differenceQty', 'label': '差异数', 'type': 'number'},
        ],
        'columnSearchKeys': ['differenceQty'],
        'rows': [
          {'differenceQty': -2, 'differenceQtyExact': '-2.0000000001'},
        ],
        'total': 51,
        'totalPages': 2,
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('差异数'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '-10..0',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(api.queries.last['f.search.differenceQty'], '-10..0');
      expect(api.queries.last['page'], 1);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      expect(table.serverColumnSearchKeys, {'differenceQty'});
      expect(table.filters['search.differenceQty'], '-10..0');
      expect(
        tester
            .widget<UtenExportButton>(find.byType(UtenExportButton))
            .queryParams['f.search.differenceQty'],
        '-10..0',
      );
      api.pending.last.complete({
        ..._report('差异数'),
        'columns': [
          {'key': 'differenceQty', 'label': '差异数', 'type': 'number'},
        ],
        'columnSearchKeys': ['differenceQty'],
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in <(String, Widget)>[
    ('采购', const PurchaseReportTablePage(kind: PurchaseReportKind.detail)),
    ('销售', const SalesReportPage(kind: SalesReportKind.detail)),
    ('财务', const FinanceReportTablePage(cardId: 'detail')),
    ('应收应付', const FinanceArApOverviewPage()),
    ('账户流水', const FinanceAccountFlowPage()),
    ('往来对账', const FinanceStatementPage()),
    (
      '委外',
      const SubcontractReportTablePage(kind: SubcontractReportKind.detail),
    ),
    ('仓库', const WarehouseReportTablePage(kind: WarehouseReportKind.detail)),
    ('生产', const ProductionReportPage(kind: ProductionReportKind.detail)),
  ]) {
    testWidgets('${entry.$1}慢请求期间表壳先显示，未确认时不显示空数据结论', (tester) async {
      final api = _Api();
      await _mount(tester, entry.$2, api);
      expect(api.pending, hasLength(1));
      final finder = find.byType(MasterDataTableView<Map<String, dynamic>>);
      final loading = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        finder,
      );
      expect(loading.isLoading, isTrue);
      expect(loading.columns, isEmpty, reason: '服务端表头未知时不伪造业务列');
      expect(loading.items, isEmpty);
      api.pending.single.complete(_report('服务端真实字段'));
      await tester.pumpAndSettle();
      final loaded = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        finder,
      );
      expect(loaded.isLoading, isFalse);
      expect(loaded.columns.single.label, '服务端真实字段');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('采购回切已读分类时立即恢复对应真实表头，仍等待新结果', (tester) async {
    final api = _Api();
    await _mount(
      tester,
      const PurchaseReportTablePage(kind: PurchaseReportKind.detail),
      api,
    );
    api.pending.single.complete(_report('订货真实列'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('申请'));
    await tester.pump();
    api.pending.last.complete(_report('申请真实列'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('订货'));
    await tester.pump();
    final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
      find.byType(MasterDataTableView<Map<String, dynamic>>),
    );
    expect(table.isLoading, isTrue);
    expect(table.columns.single.label, '订货真实列');
    expect(table.items, isEmpty);
    api.pending.last.complete(_report('订货新列'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('物料反查选定物料后慢请求期间保留表壳', (tester) async {
    final api = _Api();
    await _mount(tester, const WhereUsedReportPage(), api);
    final field = tester
        .widget<
          UtenReferencePickerField<
            ({GoodsListItem? material, MaterialTraceSubject subject})
          >
        >(
          find.byWidgetPredicate(
            (widget) => widget is UtenReferencePickerField,
          ),
        );
    final candidates = await field.loadSuggestions('MAT');
    field.onSelected(candidates.single);
    await tester.pump();
    expect(api.pending, hasLength(1));
    final finder = find.byType(MasterDataTableView<Map<String, dynamic>>);
    final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
      finder,
    );
    expect(table.isLoading, isTrue);
    expect(table.columns, isEmpty);
    api.pending.single.complete(_report('反查真实列'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
