import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_report_config.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final entry in const {
    '材料出': 'MATERIAL_ISSUE',
    '材料退': 'MATERIAL_RETURN',
  }.entries) {
    testWidgets(
      '${entry.value} displays linked order difference in its own unit and exports the same report',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1500, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final api = _MaterialReportApi();
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
            child: const MaterialApp(
              locale: Locale('zh'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: SubcontractReportTablePage(
                kind: SubcontractReportKind.detail,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(entry.key));
        await tester.pumpAndSettle();
        expect(
          api.paths,
          contains('/subcontract/reports/${entry.value}/detail'),
        );
        final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
          find.byType(MasterDataTableView<Map<String, dynamic>>),
        );
        final difference = table.columns.singleWhere(
          (column) => column.key == 'sourceOrderDifferenceQty',
        );
        expect(difference.value(table.items.single), '-6.0001 套');
        final export = tester.widget<UtenExportButton>(
          find.byType(UtenExportButton),
        );
        expect(export.report, '${entry.value}/detail');
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _MaterialReportApi extends ApiClient {
  _MaterialReportApi() : super(Dio());
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
          'key': 'sourceOrderDifferenceQty',
          'label': '订货差异数',
          'type': 'number',
          'unitKey': '__sourceOrderDifferenceUnitName',
        },
      ],
      'rows': [
        {
          'billNo': 'WW-M-1',
          'sourceOrderDifferenceQty': -6,
          'sourceOrderDifferenceQtyExact': '-6.0001',
          '__sourceOrderDifferenceUnitName': '套',
          '__unitName': '千克',
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
