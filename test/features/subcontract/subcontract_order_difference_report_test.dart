import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_report_config.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final entry in const {
    'zh': ['订货', '订货明细报表'],
    'en': ['Orders', 'Order detail report'],
    'ko': ['발주', '발주 상세 보고서'],
  }.entries) {
    testWidgets(
      '${entry.key} order switch loads authoritative variance and keeps export on the same report',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1500, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final api = _OrderReportApi();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              apiClientProvider.overrideWithValue(api),
              currentPermissionsProvider.overrideWithValue(const {
                Perm.subcontractReportView,
                Perm.subcontractReportExport,
              }),
            ],
            child: MaterialApp(
              locale: Locale(entry.key),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: const SubcontractReportTablePage(
                kind: SubcontractReportKind.detail,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(entry.value[0]));
        await tester.pumpAndSettle();
        expect(api.paths, contains('/subcontract/reports/ORDER/detail'));
        expect(find.text(entry.value[1]), findsOneWidget);
        final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
          find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<Map<String, dynamic>>,
          ),
        );
        expect(
          table.columns.map((column) => column.key),
          contains('differenceQty'),
        );
        expect(table.items.single['differenceQtyExact'], '-1194');
        final export = tester.widget<UtenExportButton>(
          find.byType(UtenExportButton),
        );
        expect(export.report, 'ORDER/detail');
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _OrderReportApi extends ApiClient {
  _OrderReportApi() : super(Dio());
  final List<String> paths = [];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    if (!path.contains('/subcontract/reports/')) return {};
    return {
      'columns': [
        {'key': 'billNo', 'label': '单号', 'type': 'text'},
        {
          'key': 'differenceQty',
          'label': '差异数',
          'type': 'number',
          'unitKey': '__unitName',
        },
      ],
      'rows': [
        {
          'billNo': 'WO-1',
          'differenceQty': -1194,
          'differenceQtyExact': '-1194',
          '__unitName': '个',
        },
      ],
      'facets': <String, dynamic>{},
      'page': 1,
      'size': 50,
      'total': 1,
      'totalPages': 1,
    };
  }
}
