import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'report headers keep full query across page export and currency clear without replay',
    (tester) async {
      final api = await _pump(tester, 'detail');
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      final keys = Set.of(table().serverColumnSearchKeys);
      var money = table().columns.singleWhere(
        (column) => column.key == 'expectedOriginal',
      );
      expect(money.columnSearchEnabled, isFalse);
      expect(money.sortable, isFalse);
      table().onFilterChanged('currencyCode', 'currency-id');
      await tester.pumpAndSettle();
      money = table().columns.singleWhere(
        (column) => column.key == 'expectedOriginal',
      );
      expect(money.columnSearchEnabled, isTrue);
      expect(money.exactValueOf!(table().items.first), '90071992547409.1234');
      table().onFilterChanged(
        'search.expectedOriginal',
        '>=90071992547409.1234',
      );
      await tester.pumpAndSettle();
      table().onFilterChanged('search.orderDate', '2026-10..2026-11');
      await tester.pumpAndSettle();
      table().onSortChange!('expectedOriginal', false);
      await tester.pumpAndSettle();
      await table().onPageChange!(2);
      await tester.pumpAndSettle();
      expect(
        api.requests.last.$2,
        containsPair('f.search.expectedOriginal', '>=90071992547409.1234'),
      );
      expect(find.textContaining('search.expectedOriginal:'), findsNothing);
      expect(
        find.textContaining('未发运待收原币: >=90071992547409.1234'),
        findsOneWidget,
      );
      expect(
        api.requests.last.$2,
        containsPair('f.search.orderDate', '2026-10..2026-11'),
      );
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(
        export.queryParams,
        containsPair('f.search.expectedOriginal', '>=90071992547409.1234'),
      );
      expect(export.queryParams, containsPair('f.currencyCode', 'currency-id'));
      table().onFilterChanged('currencyCode', null);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(api.requests.last.$2['f.search.expectedOriginal'], isNull);
      expect(api.requests.last.$2['sort'], isNull);
      expect(api.requests.last.$2['f.search.orderDate'], '2026-10..2026-11');
      expect(table().serverColumnSearchKeys, keys);
      expect(
        table().columns
            .singleWhere((column) => column.key == 'expectedOriginal')
            .columnSearchEnabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'C2 inventory context is explicit and balance timeline cannot be reordered',
    (tester) async {
      await _pump(tester, 'recon');
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(table().headerFilterScopeDescription, contains('整组事实'));
      expect(table().headerFilterScopeDescription, contains('重复显示'));
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(3);
      await tester.pumpAndSettle();
      expect(
        table().columns
            .where((column) => column.type == 'number')
            .every((column) => !column.sortable),
        isTrue,
      );
      expect(table().serverColumnSearchKeys, contains('balance'));
      expect(
        table().columns
            .singleWhere((column) => column.key == 'balance')
            .columnSearchEnabled,
        isTrue,
      );
    },
  );
  testWidgets(
    'rejected new report conditions keep trusted headers without old facts or counts',
    (tester) async {
      final api = await _pump(tester, 'detail');
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(table().items, isNotEmpty);
      api.rejectHeaders = true;
      table().onFilterChanged('search.orderNo', 'REJECTED-NEW-SCOPE');
      await tester.pumpAndSettle();
      expect(table().items, isEmpty);
      expect(table().facets, isEmpty);
      expect(table().summaryBar, isNull);
      expect(table().filters['search.orderNo'], 'REJECTED-NEW-SCOPE');
      expect(table().error, '暂时无法检索');
      expect(table().serverColumnSearchKeys, contains('orderNo'));
      api.rejectHeaders = false;
      table().onFilterChanged('search.orderNo', null);
      await tester.pumpAndSettle();
      expect(table().items, isNotEmpty);
      expect(table().error, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'seven GL layouts preserve row order while trial balance keeps sortable columns',
    (tester) async {
      final api = await _pump(tester, 'gl');
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(
        table().columns
            .singleWhere((column) => column.key == 'orderDate')
            .sortable,
        isTrue,
      );
      for (final index in const [1, 2, 3, 4, 5, 6, 7]) {
        tester
            .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
            .onSelectionChanged!(index);
        await tester.pumpAndSettle();
        expect(
          table().columns
              .where(
                (column) =>
                    const {'number', 'money', 'date'}.contains(column.type),
              )
              .every((column) => !column.sortable),
          isTrue,
        );
        table().onSortChange!('orderDate', false);
        final key = table().columns
            .firstWhere((column) => column.type == 'text')
            .key;
        table().onFilterChanged('search.$key', 'MATCH');
        await tester.pumpAndSettle();
        expect(api.requests.last.$2['sort'], isNull);
        expect(
          tester
              .widget<UtenExportButton>(find.byType(UtenExportButton))
              .queryParams['sort'],
          isNull,
        );
      }
    },
  );
  testWidgets(
    'balance side menu sends the exact two-choice scope to the report and export',
    (tester) async {
      final api = await _pump(tester, 'gl');
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(1);
      await tester.pumpAndSettle();
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(
        table().facets['side']!.map((facet) => facet.value),
        containsAll(['资产', '负债和所有者权益']),
      );
      final header = find.byKey(const ValueKey('master-column-filter-side'));
      await tester.ensureVisible(header);
      await tester.pumpAndSettle();
      final rect = tester.getRect(header);
      await tester.tapAt(Offset(rect.left + 16, rect.center.dy));
      await tester.pumpAndSettle();
      await tester.tap(find.text('负债和所有者权益'));
      await tester.pumpAndSettle();
      expect(api.requests.last.$2['f.side'], '负债和所有者权益');
      expect(
        tester
            .widget<UtenExportButton>(find.byType(UtenExportButton))
            .queryParams['f.side'],
        '负债和所有者权益',
      );
      table().onFilterChanged('side', null);
      await tester.pumpAndSettle();
      expect(api.requests.last.$2['f.side'], isNull);
    },
  );
  testWidgets('C2 unproved price placeholders expose neither search nor sort', (
    tester,
  ) async {
    final api = await _pump(tester, 'recon');
    MasterDataTableView<Map<String, dynamic>> table() =>
        tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
    for (final key in ['materialPrice', 'materialAmount']) {
      final column = table().columns.singleWhere((column) => column.key == key);
      expect(column.columnSearchEnabled, isFalse);
      expect(column.sortable, isFalse);
      expect(table().serverColumnSearchKeys, isNot(contains(key)));
    }
    table().onFilterChanged('currencyCode', 'currency-id');
    await tester.pumpAndSettle();
    expect(
      table().columns
          .singleWhere((column) => column.key == 'processAmount')
          .columnSearchEnabled,
      isTrue,
    );
    table().onSortChange!('materialPrice', false);
    table().onFilterChanged('search.goodsName', 'KNOWN');
    await tester.pumpAndSettle();
    expect(api.requests.last.$2['sort'], isNull);
  });
  testWidgets(
    'trial footer renders the server full-scope totals instead of adding the visible page',
    (tester) async {
      await _pump(tester, 'gl', serverTotals: true);
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(table().items.single['debit'], 10);
      UtenTotalsSummaryBar totals() =>
          tester.widget(find.byType(UtenTotalsSummaryBar));
      final amount = totals().entries.singleWhere(
        (entry) => entry.label == '所列记录本期借方合计',
      );
      expect(amount.value.replaceAll(RegExp(r'[^0-9.\-]'), ''), '1234.56');
      expect(amount.value, contains('元'));
      await table().onPageChange!(2);
      await tester.pumpAndSettle();
      expect(
        totals().entries
            .singleWhere((entry) => entry.label == '所列记录本期借方合计')
            .value,
        amount.value,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<_HeaderApi> _pump(
  WidgetTester tester,
  String card, {
  bool serverTotals = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = _HeaderApi()..serverTotals = serverTotals;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.financeReportExport,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: FinanceReportTablePage(cardId: card),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

class _HeaderApi extends ApiClient {
  _HeaderApi() : super(Dio());
  final requests = <(String, Map<String, dynamic>)>[];
  bool rejectHeaders = false;
  bool serverTotals = false;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.startsWith('/finance/reports/')) return {};
    final parameters = Map<String, dynamic>.of(query ?? {});
    requests.add((path, parameters));
    if (rejectHeaders && parameters.containsKey('f.search.orderNo')) {
      throw ApiException('TEMPORARY', '暂时无法检索', httpStatus: 503);
    }
    if (serverTotals && path.endsWith('/gl/trial-balance')) {
      final page = parameters['page'] ?? 1;
      return {
        'readScopeVersion': 'scope-1',
        'columns': [
          {'key': 'code', 'label': '科目编码', 'type': 'text'},
          {'key': 'name', 'label': '科目', 'type': 'text'},
          {'key': 'debit', 'label': '本期借方', 'type': 'money', 'unitLabel': '元'},
          {'key': 'credit', 'label': '本期贷方', 'type': 'money', 'unitLabel': '元'},
        ],
        'columnSearchKeys': ['code', 'name', 'debit', 'credit'],
        'rows': [
          {
            'code': 'ACCOUNT-$page',
            'name': '科目',
            'debit': page == 1 ? 10 : 1224.56,
            'credit': page == 1 ? 0 : 345.67,
          },
        ],
        'facets': <String, dynamic>{},
        'page': page,
        'size': 1,
        'total': 2,
        'totalPages': 2,
        'totals': [
          {
            'key': 'debit',
            'label': '所列记录本期借方合计',
            'type': 'money',
            'groupKey': null,
            'unitLabel': '元',
            'groups': [
              {'unit': null, 'value': 1234.56, 'valueExact': '1234.5600'},
            ],
          },
          {
            'key': 'credit',
            'label': '所列记录本期贷方合计',
            'type': 'money',
            'groupKey': null,
            'unitLabel': '元',
            'groups': [
              {'unit': null, 'value': 345.67, 'valueExact': '345.6700'},
            ],
          },
        ],
      };
    }
    if (path.endsWith('/gl/balance-sheet')) {
      return {
        'readScopeVersion': 'scope-1',
        'columns': [
          {'key': 'item', 'label': '项目', 'type': 'text'},
          {'key': 'side', 'label': '类别', 'type': 'text'},
          {'key': 'lineNo', 'label': '行次', 'type': 'number'},
          {'key': 'periodEnd', 'label': '期末余额', 'type': 'money'},
        ],
        'columnSearchKeys': ['item', 'side', 'lineNo', 'periodEnd'],
        'rows': [
          {'item': '货币资金', 'side': '资产', 'lineNo': 1, 'periodEnd': 10},
        ],
        'facets': {
          'side': [
            {'value': '资产', 'label': '资产', 'count': 1},
            {'value': '负债和所有者权益', 'label': '负债和所有者权益', 'count': 0},
          ],
        },
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path.endsWith('/statements/subcontract')) {
      return {
        'readScopeVersion': 'scope-1',
        'columns': [
          {'key': 'goodsName', 'label': '品名及规格', 'type': 'text'},
          {'key': 'balance', 'label': '整组结存', 'type': 'number'},
          {'key': 'currencyCode', 'label': '加工币别', 'type': 'text'},
          {
            'key': 'processAmount',
            'label': '本币别加工金额',
            'type': 'money',
            'unitKey': 'currencyCode',
          },
          {'key': 'materialPrice', 'label': '材料款单价（待核验）', 'type': 'money'},
          {'key': 'materialAmount', 'label': '材料款金额（待核验）', 'type': 'money'},
        ],
        'columnSearchKeys': [
          'goodsName',
          'balance',
          'currencyCode',
          'processAmount',
        ],
        'rows': [
          {
            'goodsName': '材料',
            'balance': 5,
            'currencyCode': '美金',
            'processAmount': 10,
            'materialPrice': null,
            'materialAmount': null,
          },
        ],
        'facets': {
          'currencyCode': [
            {'value': 'currency-id', 'label': '美金', 'count': 1},
          ],
        },
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    final balance = path.endsWith('other-receivable');
    return {
      'readScopeVersion': 'scope-1',
      'columns': balance
          ? [
              {'key': 'billNo', 'label': '单号', 'type': 'text'},
              {'key': 'billDate', 'label': '日期', 'type': 'date'},
              {'key': 'balance', 'label': '本月结余(KG)', 'type': 'number'},
            ]
          : [
              {'key': 'orderNo', 'label': '销售订单号', 'type': 'text'},
              {'key': 'orderDate', 'label': '订单日期', 'type': 'date'},
              {'key': 'currencyCode', 'label': '币别', 'type': 'text'},
              {
                'key': 'expectedOriginal',
                'label': '未发运待收原币',
                'type': 'money',
                'unitKey': 'currencyCode',
              },
            ],
      'columnSearchKeys': balance
          ? ['billNo', 'billDate', 'balance']
          : ['orderNo', 'orderDate', 'currencyCode', 'expectedOriginal'],
      'rows': [
        balance
            ? {'billNo': 'C2-1', 'billDate': '2026-10-02', 'balance': 4.95}
            : {
                'orderNo': 'SO-1',
                'orderDate': '2026-10-01',
                'currencyCode': '美金',
                'expectedOriginal': 90071992547409.12,
                'expectedOriginalExact': '90071992547409.1234',
              },
      ],
      'facets': {
        'currencyCode': [
          {'value': 'currency-id', 'label': '美金', 'count': 51},
        ],
      },
      'page': parameters['page'] ?? 1,
      'size': 50,
      'total': 51,
      'totalPages': 2,
    };
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};
}
