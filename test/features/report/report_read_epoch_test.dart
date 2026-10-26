import 'dart:async';

import 'package:dio/dio.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/finance/pages/finance_account_flow_page.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_overview_page.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/finance/pages/finance_statement_page.dart';
import 'package:uten_imp/features/production/config/production_report_config.dart';
import 'package:uten_imp/features/production/pages/production_report_page.dart';
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
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class _Permissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void replace(Set<String> value) => state = value;
}

final _permissions = NotifierProvider<_Permissions, Set<String>>(
  _Permissions.new,
);

class _StatementPrefs extends FinanceStatementReportPrefsNotifier {
  @override
  ReportFilterPrefs build() =>
      const ReportFilterPrefs(extra: {'partyId': 'party-1'});
}

void _aba(ProviderContainer container, _ReportApi api) {
  api.newReader = true;
  final before = container.read(exportContextEpochProvider);
  container.read(_permissions.notifier).replace({'changed:reader'});
  expect(container.read(exportContextEpochProvider), greaterThan(before));
  container.read(_permissions.notifier).replace({});
  expect(container.read(exportContextEpochProvider), greaterThan(before + 1));
}

class _ReportApi extends ApiClient {
  _ReportApi() : super(Dio());
  bool newReader = false;
  final pending = <Completer<Map<String, dynamic>>>[];
  final paths = <String>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/reports/')) {
      paths.add(path);
      if (newReader) return _report(value: 'reader-B-fresh');
      final completion = Completer<Map<String, dynamic>>();
      pending.add(completion);
      return completion.future;
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/accounts/')) {
      return [
        {'id': 'account-1', 'name': '账户', 'code': 'A1'},
      ];
    }
    if (path.endsWith('/clients/dict') || path.endsWith('/suppliers/dict')) {
      return [
        {'id': 'party-1', 'name': '往来单位', 'code': 'P1'},
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};
}

Map<String, dynamic> _report({
  bool large = false,
  String value = 'reader-A-secret',
}) => {
  'columns': [
    {'key': 'proof', 'label': '记录', 'type': 'text', 'width': 280},
  ],
  'rows': [
    {'id': 'row-1', 'proof': value},
  ],
  'facets': {
    if (large)
      'proof': List.generate(
        3000,
        (index) => {'value': '$index', 'label': '$index', 'count': 1},
      ),
  },
  'page': 1,
  'total': 1,
  'totalPages': 1,
};

Future<ProviderContainer> _mount(
  WidgetTester tester,
  Widget page,
  _ReportApi api,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'report-reader'),
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        financeStatementReportPrefsProvider.overrideWith(_StatementPrefs.new),
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
  for (var i = 0; i < 8 && api.pending.isEmpty; i++) {
    await tester.pump();
  }
  expect(api.pending, isNotEmpty);
  return ProviderScope.containerOf(
    tester.element(find.byType(page.runtimeType)),
  );
}

void main() {
  final pages = <String, Widget>{
    'sales': const SalesReportPage(kind: SalesReportKind.summary),
    'purchase': const PurchaseReportTablePage(kind: PurchaseReportKind.summary),
    'subcontract': const SubcontractReportTablePage(
      kind: SubcontractReportKind.summary,
    ),
    'warehouse': const WarehouseReportTablePage(
      kind: WarehouseReportKind.summary,
    ),
    'production': const ProductionReportPage(
      kind: ProductionReportKind.summary,
    ),
    'finance': const FinanceReportTablePage(cardId: 'detail'),
    'statement': const FinanceStatementPage(),
    'account': const FinanceAccountFlowPage(),
    'ar-ap': const FinanceArApOverviewPage(),
  };
  for (final entry in pages.entries) {
    testWidgets(
      '${entry.key} rejects old report when permissions change during sliced decoding',
      (tester) async {
        final api = _ReportApi();
        final container = await _mount(tester, entry.value, api);
        var changed = false;
        final previousObserver = debugUiWorkSliceObserver;
        debugUiWorkSliceObserver = (_, _) {
          if (changed) return;
          changed = true;
          _aba(container, api);
        };
        addTearDown(() => debugUiWorkSliceObserver = previousObserver);
        for (final request in api.pending) {
          request.complete(_report(large: true));
        }
        await tester.pumpAndSettle();
        expect(
          changed,
          isTrue,
          reason: 'the boundary must change inside actual decode work',
        );
        expect(find.text('reader-A-secret'), findsNothing);
        if (entry.key == 'ar-ap') {
          expect(find.text('请重新查询'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('${entry.key} clears already accepted report on reader ABA', (
      tester,
    ) async {
      final api = _ReportApi();
      final container = await _mount(tester, entry.value, api);
      for (final request in api.pending) {
        request.complete(_report());
      }
      await tester.pumpAndSettle();
      expect(find.text('reader-A-secret'), findsOneWidget);
      _aba(container, api);
      await tester.pumpAndSettle();
      expect(find.text('reader-A-secret'), findsNothing);
      if (entry.key == 'ar-ap') {
        expect(find.text('请重新查询'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  final modePairs = <String, (Widget, Widget)>{
    'sales': (
      const SalesReportPage(kind: SalesReportKind.detail),
      const SalesReportPage(kind: SalesReportKind.summary),
    ),
    'purchase': (
      const PurchaseReportTablePage(kind: PurchaseReportKind.detail),
      const PurchaseReportTablePage(kind: PurchaseReportKind.summary),
    ),
    'subcontract': (
      const SubcontractReportTablePage(kind: SubcontractReportKind.detail),
      const SubcontractReportTablePage(kind: SubcontractReportKind.summary),
    ),
    'warehouse': (
      const WarehouseReportTablePage(kind: WarehouseReportKind.detail),
      const WarehouseReportTablePage(kind: WarehouseReportKind.summary),
    ),
    'production': (
      const ProductionReportPage(kind: ProductionReportKind.detail),
      const ProductionReportPage(kind: ProductionReportKind.summary),
    ),
    'finance': (
      const FinanceReportTablePage(cardId: 'detail'),
      const FinanceReportTablePage(cardId: 'summary'),
    ),
  };
  for (final entry in modePairs.entries) {
    testWidgets(
      '${entry.key} same State report identity retires late former schema',
      (tester) async {
        final api = _ReportApi();
        final selected = ValueNotifier(entry.value.$1);
        addTearDown(selected.dispose);
        await _mount(
          tester,
          ValueListenableBuilder<Widget>(
            valueListenable: selected,
            builder: (_, page, _) => page,
          ),
          api,
        );
        final state = tester.state(find.byType(entry.value.$1.runtimeType));
        selected.value = entry.value.$2;
        await tester.pump();
        await tester.pump();
        expect(
          tester.state(find.byType(entry.value.$2.runtimeType)),
          same(state),
        );
        expect(api.pending, hasLength(2));
        expect(
          api.paths.first,
          contains(entry.key == 'finance' ? '/order-plan' : '/detail'),
        );
        expect(api.paths.last, contains('/summary'));
        final fresh = _report(value: 'mode-B-row');
        fresh['columns'] = [
          {'key': 'proof', 'label': 'mode-B-schema', 'type': 'text'},
        ];
        api.pending.last.complete(fresh);
        await tester.pumpAndSettle();
        api.pending.first.complete(_report(value: 'mode-A-late'));
        await tester.pumpAndSettle();
        expect(find.text('mode-B-row'), findsOneWidget);
        expect(find.text('mode-A-late'), findsNothing);
        final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
          find.byType(MasterDataTableView<Map<String, dynamic>>).first,
        );
        expect(table.columns.single.label, 'mode-B-schema');
        expect(table.currentPage, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'subcontract route detail to summary reuses State with the new API and schema',
    (tester) async {
      final api = _ReportApi();
      final router = GoRouter(
        initialLocation: '/subcontract/report/detail',
        routes: [
          GoRoute(
            path: '/subcontract/report/:kind',
            builder: (_, state) => SubcontractReportTablePage(
              kind: state.pathParameters['kind'] == 'summary'
                  ? SubcontractReportKind.summary
                  : SubcontractReportKind.detail,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _mount(tester, Router.withConfig(config: router), api);
      final before = tester.state(find.byType(SubcontractReportTablePage));
      api.pending.first.complete(_report(value: 'old-detail'));
      await tester.pumpAndSettle();
      router.go('/subcontract/report/summary');
      await tester.pump();
      await tester.pump();
      expect(
        tester.state(find.byType(SubcontractReportTablePage)),
        same(before),
      );
      expect(find.text('old-detail'), findsNothing);
      expect(api.paths.last, '/subcontract/reports/RECEIPT/summary');
      api.pending.last.complete(_report(value: 'new-summary'));
      await tester.pumpAndSettle();
      expect(find.text('new-summary'), findsOneWidget);
      expect(
        router.routeInformationProvider.value.uri.path,
        '/subcontract/report/summary',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'customer drill-down removes its old title and cannot revive after ABA',
    (tester) async {
      final api = _ReportApi();
      final container = await _mount(
        tester,
        const SalesClientDetailDialog(
          docType: SalesReportDocType.order,
          docSeg: 'orders',
          clientId: 'client-1',
          clientName: 'secret customer',
          dateFrom: '2026-10-01',
          dateTo: '2026-10-22',
        ),
        api,
      );
      _aba(container, api);
      for (final request in api.pending) {
        request.complete(_report());
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('secret customer'), findsNothing);
      expect(find.text('reader-A-secret'), findsNothing);
      expect(find.text('账号、权限或服务器已变化，请关闭后重新打开明细'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
