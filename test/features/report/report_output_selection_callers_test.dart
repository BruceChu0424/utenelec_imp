import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/production/config/production_report_config.dart';
import 'package:uten_imp/features/production/pages/production_report_page.dart';
import 'package:uten_imp/features/purchase/config/purchase_report_config.dart';
import 'package:uten_imp/features/purchase/pages/purchase_report_table_page.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_report_config.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_report_table_page.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_report_config.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';

void main() {
  final cases = <({String domain, String report, Widget page})>[
    (
      domain: 'sales',
      report: 'ORDER/detail',
      page: const SalesReportPage(kind: SalesReportKind.detail),
    ),
    (
      domain: 'purchase',
      report: 'order/detail',
      page: const PurchaseReportTablePage(kind: PurchaseReportKind.detail),
    ),
    (
      domain: 'subcontract',
      report: 'RECEIPT/detail',
      page: const SubcontractReportTablePage(
        kind: SubcontractReportKind.detail,
      ),
    ),
    (
      domain: 'production',
      report: 'plan/detail',
      page: const ProductionReportPage(kind: ProductionReportKind.detail),
    ),
    (
      domain: 'stock',
      report: 'TRANSFER/detail',
      page: const WarehouseReportTablePage(kind: WarehouseReportKind.detail),
    ),
    (
      domain: 'finance',
      report: 'receipt/detail',
      page: const FinanceReportTablePage(cardId: 'detail'),
    ),
  ];
  for (final sample in cases) {
    testWidgets(
      '${sample.domain} actual report page exports one selected row with its accepted filters',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _CallerApi(sample.domain);
        final projections = TableColumnProjectionController();
        addTearDown(projections.dispose);
        await tester.binding.setSurfaceSize(const Size(2200, 1300));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'caller-fixture-reader'),
              ),
              isSuperAdminProvider.overrideWithValue(false),
              currentPermissionsProvider.overrideWithValue({
                Perm.salesReportView,
                Perm.salesReportExport,
                Perm.purchaseReportView,
                Perm.purchaseReportExport,
                Perm.subcontractReportView,
                Perm.subcontractReportExport,
                Perm.productionReportView,
                Perm.productionReportExport,
                Perm.stockReportView,
                Perm.stockReportExport,
                Perm.financeReportView,
                Perm.financeReportExport,
                Perm.financeViewAll,
              }),
              fixedBadgeSummaryOverride(badgeSummaryFixture()),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: TableColumnProjectionScope(
                controller: projections,
                child: sample.page,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (sample.domain == 'finance') {
          await selectFilterSegment(tester, '销售收款明细');
          await tester.pumpAndSettle();
        }
        MasterDataTableView<Map<String, dynamic>> table() => tester.widget(
          find.byType(MasterDataTableView<Map<String, dynamic>>),
        );
        expect(table().items, isNotEmpty);
        final toolbar = find.byWidgetPredicate(
          (widget) => widget is UtenFilterToolbar,
        );
        final search = find
            .descendant(of: toolbar, matching: find.byType(TextField))
            .first;
        await tester.enterText(search, '查阅');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        table().onFilterChanged('proof', '范围A');
        await tester.pumpAndSettle();
        table().onFilterChanged('search.goodsName', '查阅');
        await tester.pumpAndSettle();
        table().onSortChange!('goodsName', false);
        await tester.pumpAndSettle();
        expect(table().currentPage, 1);
        expect(table().totalPages, 1);
        final physical = table().rowsController?.items ?? table().items;
        expect(physical, hasLength(2));
        expect(physical.map((row) => row['__lineId']), [
          '${sample.domain}-line-1',
          '${sample.domain}-line-2',
        ]);
        expect(
          physical.singleWhere(
            (row) => row['__lineId'] == '${sample.domain}-line-2',
          )['__srcId'],
          '${sample.domain}-document',
          reason:
              'The existing document navigation identity stays on the source row',
        );
        final accepted = api.reads.last;
        expect(
          api.readEndpoints.last,
          '/${sample.domain}/reports/${sample.report}',
        );
        expect(accepted['dateFrom'], isNotNull);
        expect(accepted['dateTo'], isNotNull);
        expect(accepted['keyword'], '查阅');
        expect(accepted['f.proof'], '范围A');
        expect(
          accepted['f.search.goodsName'] ?? accepted['search.goodsName'],
          '查阅',
        );
        expect(accepted['sort'], 'goodsName');
        expect(accepted['order'], 'desc');
        final row = find.text('查阅项目').last;
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        final projection = projections.tables.single;
        expect(projection.outputSelection.count, 1);
        final declared = table().toolbarActions!
            .whereType<UtenExportButton>()
            .single;
        expect(declared.report, sample.report);
        final query = Map<String, dynamic>.of(declared.queryParams);
        for (final entry in query.entries) {
          expect(
            accepted[entry.key],
            entry.value,
            reason: 'The accepted read and export must share ${entry.key}',
          );
        }
        var export = find.byType(UtenExportButton).hitTestable();
        if (export.evaluate().isEmpty) {
          await tester.tap(find.byTooltip('表格操作'));
          await tester.pumpAndSettle();
          export = find.byType(UtenExportButton).hitTestable();
        }
        expect(export, findsOneWidget);
        await tester.tap(export);
        await tester.pumpAndSettle();
        expect(find.text('仅已选（1 项）'), findsOneWidget);
        await tester.tap(find.byKey(const Key('table-output-selected')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('直接下载'));
        await tester.pumpAndSettle();
        expect(api.capabilityReads, greaterThan(0));
        expect(api.jobs, hasLength(1));
        final request = api.jobs.single;
        expect(request['domain'], sample.domain);
        expect(request['report'], sample.report);
        final parameters = Map<String, dynamic>.from(
          request['parameters'] as Map,
        );
        for (final entry in query.entries) {
          if (entry.key == 'sort' || entry.key == 'order') {
            expect(request[entry.key], entry.value);
          } else {
            expect(parameters[entry.key], entry.value.toString());
          }
        }
        final selectors = List<Map<String, dynamic>>.from(
          (request['columnProjection'] as Map)['rowSelection'] as List,
        );
        expect(selectors, hasLength(1));
        expect(selectors.single.keys, ['__lineId']);
        expect(
          selectors.single['__lineId'],
          '${sample.domain}-line-2',
          reason:
              'Different report lines must retain their own identity when they share a document header',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _CallerApi extends ApiClient {
  _CallerApi(this.domain) : super(Dio());
  final String domain;
  final reads = <Map<String, dynamic>>[], jobs = <Map<String, dynamic>>[];
  final readEndpoints = <String>[];
  int capabilityReads = 0;
  // Two report lines of one document. The fake honors the complete reader's
  // requested (page, size): rows are the exact [(page-1)*size, page*size)
  // slice of the two lines, each keeping its own line identity.
  static const _lineTotal = 2;
  Map<String, dynamic> _report(Map<String, dynamic>? query) {
    final values = Map<String, dynamic>.from(query ?? {});
    reads.add(values);
    final page = (values['page'] as num?)?.toInt() ?? 1;
    final size = (values['size'] as num?)?.toInt() ?? 1;
    return {
      'columns': [
        {'key': 'goodsName', 'label': '货品名称', 'type': 'text', 'width': 220},
        {'key': 'billDate', 'label': '业务日期', 'type': 'date', 'width': 130},
        {'key': 'proof', 'label': '核查范围', 'type': 'text', 'width': 150},
      ],
      'columnSearchKeys': ['goodsName', 'billDate', 'proof'],
      'rows': [
        for (
          var line = (page - 1) * size + 1;
          line <= _lineTotal && line <= page * size;
          line++
        )
          {
            '__lineId': '$domain-line-$line',
            '__srcId': '$domain-document',
            'goodsName': '查阅项目',
            'billDate': '2026-10-11',
            'proof': '范围A',
          },
      ],
      'facets': {
        'proof': [
          {'value': '范围A', 'count': _lineTotal},
        ],
      },
      'page': page,
      'size': size,
      'total': _lineTotal,
      'totalPages': (_lineTotal / size).ceil(),
      'readScopeVersion': '$domain-fixture-scope',
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/report-export-jobs/capabilities') {
      capabilityReads++;
      return {'available': true, 'selectionVersion': 1};
    }
    if (path.startsWith('/$domain/reports/')) {
      readEndpoints.add(path);
      return _report(query);
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    if (path == '/report-export-jobs') {
      final request = Map<String, dynamic>.from(body as Map);
      jobs.add(request);
      return {
        'id': request['id'],
        'domain': request['domain'],
        'report': request['report'],
        'format': 'xlsx',
        'status': 'FAILED',
        'rows': 0,
        'bytes': 0,
        'error': 'Fixture captured without publishing a file',
      };
    }
    if (path.startsWith('/$domain/reports/') && path.endsWith('/search')) {
      readEndpoints.add(path.substring(0, path.length - '/search'.length));
      return _report({
        ...?query,
        if (body is Map) ...Map<String, dynamic>.from(body),
      });
    }
    return {};
  }
}
