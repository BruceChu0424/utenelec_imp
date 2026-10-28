import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_report_config.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'warehouse report uses declared typed headers and the same export query with kg guidance',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final api = _ReportApi();
      final router = GoRouter(
        initialLocation: '/warehouse/report-header',
        routes: [
          GoRoute(
            path: '/warehouse/report-header',
            builder: (_, _) => const WarehouseReportTablePage(
              kind: WarehouseReportKind.detail,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({
              Perm.stockReportView,
              Perm.stockReportExport,
            }),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(table().serverColumnSearch, isTrue);
      expect(
        table().serverColumnSearchKeys,
        containsAll(['billDate', 'qty', 'weight', 'warehouseName']),
      );
      final quantity = table().columns.singleWhere(
        (column) => column.key == 'qty',
      );
      expect(quantity.columnSearchEnabled, isTrue);
      expect(
        quantity.exactValueOf!(table().items.single),
        '99999999999999.0001',
      );
      expect(
        table().columns
            .singleWhere((column) => column.key == 'approved')
            .columnSearchEnabled,
        isFalse,
      );
      expect(
        table().columns.singleWhere((column) => column.key == 'weight').info,
        contains('千克'),
      );
      expect(table().headerFilterScopeDescription, contains('kg'));
      table().onFilterChanged(
        'search.qty',
        '99999999999999.0001..99999999999999.0002',
      );
      await tester.pumpAndSettle();
      table().onFilterChanged('search.weight', '>0.5');
      await tester.pumpAndSettle();
      table().onFilterChanged('search.billDate', '2026-10-01..2026-10-31');
      await tester.pumpAndSettle();
      table().onFilterChanged('approved', 'false');
      await tester.pumpAndSettle();
      final query = api.queries.last;
      expect(query['search.qty'], '99999999999999.0001..99999999999999.0002');
      expect(query['search.weight'], '>0.5');
      expect(query['search.billDate'], '2026-10-01..2026-10-31');
      expect(query['f.approved'], 'false');
      expect(query.containsKey('f.search.qty'), isFalse);
      expect(query['page'], 1);
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(export.queryParams['search.qty'], query['search.qty']);
      expect(export.queryParams['search.weight'], query['search.weight']);
      expect(export.queryParams['search.billDate'], query['search.billDate']);
      expect(export.queryParams['f.approved'], 'false');
      expect(tester.takeException(), isNull);
    },
  );
}

class _ReportApi extends ApiClient {
  _ReportApi() : super(Dio());
  final queries = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.startsWith('/stock/reports/')) return {};
    queries.add(Map.of(query ?? {}));
    return {
      'columns': [
        {'key': 'approved', 'label': '是否审核', 'type': 'bool'},
        {'key': 'billDate', 'label': '开单日期', 'type': 'date'},
        {'key': 'warehouseName', 'label': '仓库', 'type': 'text'},
        {'key': 'qty', 'label': '数量', 'type': 'number', 'unitKey': 'unitName'},
        {'key': 'weight', 'label': '重量', 'type': 'weight'},
      ],
      'rows': [
        {
          'approved': false,
          'billDate': '2026-10-28',
          'warehouseName': '成品仓',
          'qty': 99999999999999.0001,
          'qtyExact': '99999999999999.0001',
          'weight': 0.5001,
          'weightExact': '0.5001',
          'unitName': '件',
        },
      ],
      'columnSearchKeys': ['billDate', 'warehouseName', 'qty', 'weight'],
      'facets': {
        'approved': [
          {'value': 'true', 'label': '已审', 'count': 1},
          {'value': 'false', 'label': '未审', 'count': 2},
        ],
      },
      'page': query?['page'] ?? 1,
      'size': 50,
      'total': 1,
      'totalPages': 1,
      'totals': <Map<String, dynamic>>[],
      'readScopeVersion': 'warehouse-header-scope',
    };
  }
}
