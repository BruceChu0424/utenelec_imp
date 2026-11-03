import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_date_range_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/components/inputs/uten_reference_picker_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_exception.dart';
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
import '../../support/uten_test_actions.dart';

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

class _BankPrefs extends FinanceAccountFlowReportPrefsNotifier {
  @override
  ReportFilterPrefs build() => const ReportFilterPrefs(
    docType: 'bankDetail',
    sortKey: 'amount',
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
  Map<String, String> get accountEntries => {
    'account-1': '测试账户',
    'account-2': '第二账户',
  };
}

Future<void> _mount(
  WidgetTester tester,
  Widget page,
  _Api api, {
  bool bankPrefs = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final names = _Names(api, hold: page is FinanceAccountFlowPage);
  await setUtenTestSurfaceSize(tester, const Size(1500, 1000));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'report-reader'),
        ),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.financeReportExport,
          Perm.purchaseReportExport,
          Perm.salesReportExport,
          Perm.subcontractReportExport,
          Perm.stockReportExport,
          Perm.productionReportExport,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        financeStatementReportPrefsProvider.overrideWith(_StatementPrefs.new),
        financeAccountFlowReportPrefsProvider.overrideWith(
          bankPrefs ? _BankPrefs.new : _AccountPrefs.new,
        ),
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

Future<UtenExportButton> _exportControl(WidgetTester tester) async {
  var finder = find.byType(UtenExportButton);
  if (finder.evaluate().isNotEmpty) return tester.widget(finder);
  final actions = find.byKey(const ValueKey('master-table-action-overflow'));
  expect(actions, findsOneWidget);
  await tester.tap(actions);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  finder = find.byType(UtenExportButton);
  expect(finder, findsOneWidget);
  final control = tester.widget<UtenExportButton>(finder);
  await tester.tapAt(const Offset(4, 4));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return control;
}

void main() {
  testWidgets('恢复银行原币金额排序时不带已丢失币种的排序条件', (tester) async {
    final api = _Api();
    await _mount(tester, const FinanceAccountFlowPage(), api, bankPrefs: true);
    expect(api.queries.single.containsKey('sort'), isFalse);
    api.pending.single.complete(_report('银行字段'));
    await tester.pumpAndSettle();
    expect(
      (await _exportControl(tester)).queryParams.containsKey('sort'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
  Map<String, dynamic> accountReport(String label, int amount) => {
    ..._report('单据号'),
    'columns': [
      {'key': 'billNo', 'label': '单据号', 'type': 'text'},
      {'key': 'inAmount', 'label': '收入', 'type': 'money'},
      {'key': 'balance', 'label': '余额', 'type': 'money'},
    ],
    'rows': [
      {'billNo': label, 'inAmount': amount, 'balance': amount},
    ],
    'total': 1,
    'totalPages': 1,
  };

  MasterDataTableView<Map<String, dynamic>> accountTable(WidgetTester tester) =>
      tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));

  testWidgets('账户切换慢请求和失败不得将旧金额显示在新账户下，重试恢复真实金额', (tester) async {
    final api = _Api();
    await _mount(tester, const FinanceAccountFlowPage(), api);
    api.pending.single.complete(accountReport('账户一金额', 100));
    await tester.pumpAndSettle();
    expect(accountTable(tester).items.single['inAmount'], 100);
    tester
        .widget<UtenDropdownField>(find.byType(UtenDropdownField))
        .onChanged('account-2');
    await tester.pump();
    expect(api.queries.last['accountId'], 'account-2');
    expect(accountTable(tester).items, isEmpty);
    expect(accountTable(tester).isLoading, isTrue);
    expect(accountTable(tester).totalPages, -1);
    api.pending.last.completeError(
      ApiException('TEMPORARY', '暂时无法读取账户二', httpStatus: 503),
    );
    await tester.pumpAndSettle();
    expect(accountTable(tester).items, isEmpty);
    expect(accountTable(tester).error, contains('暂时无法读取账户二'));
    expect(accountTable(tester).isLoading, isFalse);
    final export = (await _exportControl(tester));
    expect(export.queryParams['accountId'], 'account-2');
    accountTable(tester).onRetry!();
    await tester.pump();
    api.pending.last.complete(accountReport('账户二金额', 250));
    await tester.pumpAndSettle();
    expect(accountTable(tester).items.single['inAmount'], 250);
    expect(accountTable(tester).error, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('快速切换账户时晚到的旧请求不能覆盖当前账户金额', (tester) async {
    final api = _Api();
    await _mount(tester, const FinanceAccountFlowPage(), api);
    api.pending.single.complete(accountReport('初始', 100));
    await tester.pumpAndSettle();
    tester
        .widget<UtenDropdownField>(find.byType(UtenDropdownField))
        .onChanged('account-2');
    await tester.pump();
    final old = api.pending.last;
    tester
        .widget<UtenDropdownField>(find.byType(UtenDropdownField))
        .onChanged('account-1');
    await tester.pump();
    api.pending.last.complete(accountReport('账户一最新', 300));
    await tester.pumpAndSettle();
    old.complete(accountReport('晚到账户二', 999));
    await tester.pumpAndSettle();
    expect(accountTable(tester).items.single['inAmount'], 300);
    expect(find.text('晚到账户二'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final bank in [('银行存取明细', 'bank/detail'), ('银行存取汇总', 'bank/summary')]) {
    testWidgets('${bank.$1}列表和下载携带相同账户日期及查询条件', (tester) async {
      final api = _Api();
      await _mount(tester, const FinanceAccountFlowPage(), api);
      api.pending.single.complete(accountReport('初始', 100));
      await tester.pumpAndSettle();
      await tester.tap(find.text(bank.$1));
      await tester.pump();
      expect(api.queries.last['accountId'], 'account-1');
      expect(api.queries.last['dateFrom'], isNotNull);
      expect(api.queries.last['dateTo'], isNotNull);
      api.pending.last.complete(accountReport('银行真实单据', 120));
      await tester.pumpAndSettle();
      final export = (await _exportControl(tester));
      expect(export.report, bank.$2);
      expect(export.queryParams, {
        for (final e in api.queries.last.entries)
          if (!const {
            'page',
            'size',
            'includeCount',
            'includeFacets',
            'includeTotals',
          }.contains(e.key))
            e.key: e.value,
      });
      expect(find.textContaining('尚未启用'), findsNothing);
      tester
          .widget<UtenDropdownField>(find.byType(UtenDropdownField))
          .onChanged(null);
      await tester.pump();
      expect(api.queries.last.containsKey('accountId'), isFalse);
      expect(accountTable(tester).items, isEmpty);
      api.pending.last.complete(accountReport('全部账户银行单据', 240));
      await tester.pumpAndSettle();
      expect(accountTable(tester).items.single['inAmount'], 240);
      expect(tester.takeException(), isNull);
    });
  }

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
      (await _exportControl(tester)).queryParams['f.search.closingQty'],
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
        (await _exportControl(tester)).queryParams['f.search.differenceQty'],
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

  for (final entry in <(String, Widget)>[
    ('采购', const PurchaseReportTablePage(kind: PurchaseReportKind.detail)),
    ('销售', const SalesReportPage(kind: SalesReportKind.detail)),
    (
      '委外',
      const SubcontractReportTablePage(kind: SubcontractReportKind.detail),
    ),
    ('仓库', const WarehouseReportTablePage(kind: WarehouseReportKind.detail)),
    ('生产', const ProductionReportPage(kind: ProductionReportKind.detail)),
  ]) {
    testWidgets('${entry.$1}日期单入口取消保留条件，确认后一次查询完整区间并等待结束', (tester) async {
      final api = _Api();
      await _mount(tester, entry.$2, api);
      api.pending.single.complete(_report('真实字段'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenDateRangeButton), findsOneWidget);
      final entryButton = find.descendant(
        of: find.byType(UtenDateRangeButton),
        matching: find.byType(UtenButton),
      );
      expect(find.text('选择日期'), findsOneWidget);
      await tester.tap(entryButton);
      await tester.pumpAndSettle();
      expect(find.byType(UtenDateRangePickerDialog), findsOneWidget);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(1));
      await tester.tap(entryButton);
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byType(UtenDateRangePickerDialog)),
      ).pop((start: DateTime(2024, 2), end: DateTime(2024, 2, 29)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(api.queries, hasLength(2));
      expect(api.queries.last['dateFrom'], '2024-02-01');
      expect(api.queries.last['dateTo'], '2024-02-29');
      expect(api.queries.last['page'], 1);
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      api.pending.last.complete(_report('新区间真实字段'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.byType(UtenDateRangePickerDialog), findsNothing);
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
