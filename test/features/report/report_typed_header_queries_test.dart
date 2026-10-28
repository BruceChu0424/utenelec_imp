import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/config/production_report_config.dart';
import 'package:uten_imp/features/production/pages/production_report_page.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Api extends ApiClient {
  _Api(this.production) : super(Dio());
  final bool production;
  bool failHeaders = false;
  Completer<void>? headerGate;
  final queries = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.contains('/reports/')) return {};
    queries.add(Map.of(query ?? {}));
    if (query?['f.search.goodsName'] != null) {
      await headerGate?.future;
      if (failHeaders) {
        throw StateError('fixture failed search');
      }
    }
    final key = production ? 'qty' : 'price';
    return {
      'columns': [
        {'key': 'goodsName', 'label': '货品名称', 'type': 'text', 'width': 160},
        {'key': 'billDate', 'label': '开单日期', 'type': 'date', 'width': 120},
        {
          'key': key,
          'label': production ? '排产数量' : '单价',
          'type': production ? 'number' : 'money',
          'width': 120,
        },
      ],
      'columnSearchKeys': ['goodsName', 'billDate', key],
      'rows': [
        {
          'goodsName': '快照货品',
          'billDate': '2026-10-31',
          key: '0.123456789012',
          '${key}Exact': '0.123456789012',
        },
      ],
      'facets': <String, dynamic>{},
      'page': query?['page'] ?? 1,
      'size': 50,
      'total': 1,
      'totalPages': 1,
    };
  }
}

void main() {
  testWidgets(
    'sales client detail popup uses server header contracts inside the selected client and currency',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance(),
          api = _Api(false);
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({
              Perm.salesReportView,
            }),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: Scaffold(
              body: SalesClientDetailDialog(
                docType: SalesReportDocType.order,
                docSeg: 'orders',
                clientId: 'selected-client',
                currencyId: 'selected-currency',
                clientName: '客户甲',
                dateFrom: '2026-10-01',
                dateTo: '2026-10-31',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('单价'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '>=0.123456789012',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(api.queries.last, containsPair('clientId', 'selected-client'));
      expect(api.queries.last, containsPair('currencyId', 'selected-currency'));
      expect(
        api.queries.last,
        containsPair('f.search.price', '>=0.123456789012'),
      );
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      expect(table.serverColumnSearchKeys, contains('price'));
      api.failHeaders = true;
      table.onFilterChanged('search.goodsName', '失败查询不生效');
      await tester.pumpAndSettle();
      expect(api.queries.last, containsPair('f.search.goodsName', '失败查询不生效'));
      final retained = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      expect(
        retained.filters,
        containsPair('search.price', '>=0.123456789012'),
      );
      expect(
        retained.filters.containsKey('search.goodsName'),
        isFalse,
        reason:
            'the retained rows must keep their accepted filter labels after a failed new query',
      );
      expect(retained.items, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  for (final production in [false, true]) {
    testWidgets(
      '${production ? 'production' : 'sales'} pending or failed criteria never label accepted rows as the new query',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance(),
            api = _Api(production);
        await tester.binding.setSurfaceSize(const Size(1500, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue({
                Perm.salesReportView,
                Perm.productionReportView,
              }),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              home: production
                  ? const ProductionReportPage(
                      kind: ProductionReportKind.detail,
                    )
                  : const SalesReportPage(kind: SalesReportKind.detail),
            ),
          ),
        );
        await tester.pumpAndSettle();
        MasterDataTableView<Map<String, dynamic>> table() => tester.widget(
          find.byType(MasterDataTableView<Map<String, dynamic>>),
        );
        expect(table().items, hasLength(1));
        api.headerGate = Completer<void>();
        table().onFilterChanged('search.goodsName', 'new-unaccepted');
        await tester.pump();
        await tester.pump();
        expect(table().items, isEmpty);
        expect(table().facets, isEmpty);
        expect(table().summaryBar, isNull);
        expect(table().serverColumnSearchKeys, contains('goodsName'));
        api.failHeaders = true;
        api.headerGate!.complete();
        await tester.pumpAndSettle();
        expect(table().items, isEmpty);
        expect(
          table().filters,
          containsPair('search.goodsName', 'new-unaccepted'),
        );
        table().onFilterChanged('search.goodsName', null);
        await tester.pumpAndSettle();
        expect(table().items, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${production ? 'production plan' : 'sales report'} typed header searches and export retain one complete server query',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance(),
            api = _Api(production);
        await tester.binding.setSurfaceSize(const Size(1500, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue({
                Perm.salesReportView,
                Perm.salesReportExport,
                Perm.productionReportView,
                Perm.productionReportExport,
              }),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              home: production
                  ? const ProductionReportPage(
                      kind: ProductionReportKind.detail,
                    )
                  : const SalesReportPage(kind: SalesReportKind.detail),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final pair in [
          ('开单日期', 'billDate', '2026-10-01..2026-10-31'),
          (
            production ? '排产数量' : '单价',
            production ? 'qty' : 'price',
            '>=0.123456789012',
          ),
        ]) {
          await tester.tap(find.text(pair.$1));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('uten-column-keyword-input')),
            pair.$3,
          );
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();
          expect(api.queries.last['f.search.${pair.$2}'], pair.$3);
        }
        final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
          find.byType(MasterDataTableView<Map<String, dynamic>>),
        );
        expect(
          table.serverColumnSearchKeys,
          containsAll(['billDate', production ? 'qty' : 'price']),
        );
        expect(
          table.items,
          hasLength(1),
          reason:
              'server response remains authoritative even if it is only one partial page',
        );
        final export = tester.widget<UtenExportButton>(
          find.byType(UtenExportButton),
        );
        expect(
          export.queryParams['f.search.billDate'],
          '2026-10-01..2026-10-31',
        );
        expect(
          export.queryParams['f.search.${production ? 'qty' : 'price'}'],
          '>=0.123456789012',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
