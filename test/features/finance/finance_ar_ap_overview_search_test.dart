import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/features/report/shared/report_filter_prefs.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/client_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_overview_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'one global table combines categories and preserves server exact-before-near order',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(tester, prefs: prefs, api: api);
      final baseline = Map<String, dynamic>.of(api.reportQueries.last);
      await tester.enterText(_searchField(), 'C-002');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        api.locationQueries
            .where((query) => query['keyword'] == 'C-002')
            .map((query) => query['page']),
        [1, 2],
      );
      expect(
        _tree(tester).visibleFilterIds,
        containsAll(<String>{
          '__client_root__',
          'overseas',
          'southeast-asia',
          '__supplier_root__',
          'domestic-supplier',
        }),
      );
      expect(_tree(tester).selectedIds, isEmpty);
      expect(_table(tester).items.map((row) => row['partyName']), [
        'EXACT-C-002',
        'PREFIX-C-002',
        'NEAR-C-002',
      ]);
      expect(_table(tester).items.map((row) => row['categoryId']).toSet(), {
        'southeast-asia',
        'domestic-supplier',
        'overseas',
      });
      expect(_table(tester).totalPages, 2);
      expect(find.text('共 4'), findsOneWidget);
      expect(find.text('应收应付 · 全部搜索结果'), findsOneWidget);
      _expectGlobal(api.reportQueries.last, 'C-002');
      expect(api.reportQueries.last['dateFrom'], baseline['dateFrom']);
      expect(api.reportQueries.last['dateTo'], baseline['dateTo']);
      await tester.tap(find.textContaining('海外客户'));
      await tester.pumpAndSettle();
      _expectGlobal(api.reportQueries.last, 'C-002');
      expect(_table(tester).items, hasLength(3));
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      _expectGlobal(export.queryParams, 'C-002');
      _table(tester).onPageChange!(2);
      await tester.pumpAndSettle();
      expect(api.reportQueries.last['page'], 2);
      _expectGlobal(api.reportQueries.last, 'C-002');
      expect(_table(tester).items.single['partyName'], 'PAGE2-C-002');
      _table(tester).onSortChange!('arAmount', false);
      await tester.pumpAndSettle();
      expect(api.reportQueries.last, containsPair('sort', 'arAmount'));
      expect(api.reportQueries.last, containsPair('order', 'desc'));
      expect(api.reportQueries.last['page'], 1);
      _expectGlobal(api.reportQueries.last, 'C-002');
    },
  );

  testWidgets(
    'a category code is retained as the keyword without selecting that branch',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(tester, prefs: prefs, api: api);
      await tester.enterText(_searchField(), 'SEA-001');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(_tree(tester).selectedIds, isEmpty);
      expect(_tree(tester).visibleFilterIds, contains('southeast-asia'));
      _expectGlobal(api.reportQueries.last, 'SEA-001');
      expect(find.text('latest-SEA-001'), findsOneWidget);
    },
  );

  testWidgets(
    'clearing a search restores original type and category while keeping date display and sort',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi(delayLocationKeyword: 'OVER');
      await _pumpPage(
        tester,
        prefs: prefs,
        api: api,
        initialPrefs: const ReportFilterPrefs(
          docType: 'SUPPLIER',
          sortKey: 'arAmount',
          sortAsc: false,
          extra: {'categoryId': 'domestic-supplier', 'displayMode': 'AP_ONLY'},
        ),
      );
      final before = Map<String, dynamic>.of(api.reportQueries.last);
      expect(before['categoryType'], 'SUPPLIER');
      expect(before['categoryId'], 'domestic-supplier');
      await tester.enterText(_searchField(), 'OVER');
      await tester.pump(const Duration(milliseconds: 320));
      await tester.tap(find.textContaining('海外客户'));
      await tester.pump(const Duration(milliseconds: 600));
      _expectGlobal(api.reportQueries.last, 'OVER');
      expect(_tree(tester).selectedIds, isEmpty);
      await tester.enterText(_searchField(), '');
      await tester.pumpAndSettle();
      expect(
        api.reportQueries.last,
        allOf(
          containsPair('categoryType', 'SUPPLIER'),
          containsPair('categoryId', 'domestic-supplier'),
        ),
      );
      expect(api.reportQueries.last, isNot(contains('keyword')));
      for (final field in [
        'dateFrom',
        'dateTo',
        'displayMode',
        'sort',
        'order',
      ]) {
        expect(api.reportQueries.last[field], before[field], reason: field);
      }
      expect(_tree(tester).selectedIds, {'domestic-supplier'});
      expect(find.text('应收应付 · 供应商：国内供应商'), findsOneWidget);
    },
  );

  testWidgets('stale report response cannot replace the latest global search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _OverviewApi(delayFirstSearch: true);
    await _pumpPage(tester, prefs: prefs, api: api);
    await tester.enterText(_searchField(), 'C-002');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.enterText(_searchField(), 'C-003');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('latest-C-003'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('stale-C-002'), findsNothing);
    expect(find.text('latest-C-003'), findsOneWidget);
    expect(_tree(tester).selectedIds, isEmpty);
    _expectGlobal(api.reportQueries.last, 'C-003');
  });

  testWidgets(
    'server empty search result does not fall back to unfiltered rows',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(tester, prefs: prefs, api: api);
      final before = api.reportQueries.length;
      await tester.enterText(_searchField(), 'NO-SUCH-PARTY');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('未找到匹配「NO-SUCH-PARTY」的分类或往来单位'), findsOneWidget);
      expect(api.reportQueries.length, before + 1);
      _expectGlobal(api.reportQueries.last, 'NO-SUCH-PARTY');
      expect(_table(tester).items, isEmpty);
      expect(find.text('initial'), findsNothing);
    },
  );

  testWidgets(
    'failed category hints do not block global results or restore a superseded report',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(tester, prefs: prefs, api: api);
      api.holdNextReport();
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('只应收≠0').last);
      await tester.pump();
      expect(api.heldReport, isNotNull);
      await tester.enterText(_searchField(), 'LOCATOR-FAIL');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.textContaining('分类定位暂不可用'), findsOneWidget);
      expect(find.text('latest-LOCATOR-FAIL'), findsOneWidget);
      _expectGlobal(api.reportQueries.last, 'LOCATOR-FAIL');
      expect(api.reportQueries.last['displayMode'], 'AR_ONLY');
      expect(_table(tester).isLoading, isFalse);
      api.completeHeldReport('stale-held-report');
      await tester.pump();
      expect(find.text('stale-held-report'), findsNothing);
      expect(find.text('latest-LOCATOR-FAIL'), findsOneWidget);
    },
  );

  testWidgets('new input invalidates old report during the debounce window', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _OverviewApi();
    await _pumpPage(tester, prefs: prefs, api: api);
    api.holdNextReport();
    await tester.enterText(_searchField(), 'C-002');
    await tester.pump(const Duration(milliseconds: 350));
    expect(api.heldReport, isNotNull);
    await tester.enterText(_searchField(), 'C-003');
    await tester.pump();
    api.completeHeldReport('stale-in-debounce');
    await tester.pump();
    expect(find.text('stale-in-debounce'), findsNothing);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('latest-C-003'), findsOneWidget);
  });
}

Finder _searchField() => find.descendant(
  of: find.byKey(const ValueKey('finance-ar-ap-unified-search')),
  matching: find.byType(TextField),
);
MasterDataTableView<Map<String, dynamic>> _table(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
UtenCategoryTreeView<ProductCategoryNode> _tree(WidgetTester tester) =>
    tester.widget(find.byType(UtenCategoryTreeView<ProductCategoryNode>));
void _expectGlobal(Map<String, dynamic> query, String keyword) {
  expect(query['keyword'], keyword);
  expect(query, isNot(contains('categoryType')));
  expect(query, isNot(contains('categoryId')));
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required _OverviewApi api,
  ReportFilterPrefs initialPrefs = const ReportFilterPrefs(),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1600, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWithValue(api),
        financeArApOverviewReportPrefsProvider.overrideWith(
          () => _FixedPrefs(initialPrefs),
        ),
        clientCategoryRepositoryProvider.overrideWithValue(
          _ClientCategoryRepo(),
        ),
        supplierCategoryRepositoryProvider.overrideWithValue(
          _SupplierCategoryRepo(),
        ),
      ],
      child: const MaterialApp(home: FinanceArApOverviewPage()),
    ),
  );
  await tester.pumpAndSettle();
}

class _FixedPrefs extends FinanceArApOverviewReportPrefsNotifier {
  _FixedPrefs(this.initial);
  final ReportFilterPrefs initial;
  @override
  ReportFilterPrefs build() => initial;
  @override
  void update(ReportFilterPrefs value) => state = value;
}

class _OverviewApi extends ApiClient {
  _OverviewApi({this.delayFirstSearch = false, this.delayLocationKeyword})
    : super(Dio());

  final bool delayFirstSearch;
  final String? delayLocationKeyword;
  final reportQueries = <Map<String, dynamic>>[];
  final locationQueries = <Map<String, dynamic>>[];
  bool _holdNextReport = false;
  Completer<Map<String, dynamic>>? heldReport;

  void holdNextReport() => _holdNextReport = true;

  void completeHeldReport(String label) {
    final held = heldReport;
    if (held == null || held.isCompleted) return;
    held.complete(_report(label));
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/reports/ar-ap/party-locations') {
      final q = Map<String, dynamic>.from(query ?? const {});
      locationQueries.add(q);
      final keyword = q['keyword']?.toString();
      if (keyword == 'LOCATOR-FAIL') {
        throw StateError('locator unavailable');
      }
      final page = (q['page'] as num?)?.toInt() ?? 1;
      if (keyword == delayLocationKeyword) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (keyword == 'C-002' ||
          keyword == 'C-003' ||
          keyword == delayLocationKeyword) {
        final item = page == 1
            ? <String, dynamic>{
                'partyType': 'CLIENT',
                'categoryId': 'southeast-asia',
              }
            : <String, dynamic>{
                'partyType': 'SUPPLIER',
                'categoryId': 'domestic-supplier',
              };
        return <String, dynamic>{
          'items': <Map<String, dynamic>>[item],
          'page': page,
          'size': 100,
          'total': 2,
          'totalPages': 2,
        };
      }
      return <String, dynamic>{
        'items': const <Map<String, dynamic>>[],
        'page': page,
        'size': 100,
        'total': 0,
        'totalPages': 0,
      };
    }
    if (path == '/finance/reports/ar-ap/overview') {
      final q = Map<String, dynamic>.from(query ?? const {});
      reportQueries.add(q);
      if (_holdNextReport) {
        _holdNextReport = false;
        final held = Completer<Map<String, dynamic>>();
        heldReport = held;
        return held.future;
      }
      final keyword = q['keyword']?.toString();
      if (delayFirstSearch && keyword == 'C-002') {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (keyword == 'NO-SUCH-PARTY') return _reportRows(const []);
      if (keyword == 'C-002' && !delayFirstSearch) {
        final page = (q['page'] as num?)?.toInt() ?? 1;
        return _reportRows(
          page == 1
              ? [
                  {
                    'id': 'client-exact',
                    'partyName': 'EXACT-C-002',
                    'categoryId': 'southeast-asia',
                    'arAmount': 100,
                  },
                  {
                    'id': 'supplier-prefix',
                    'partyName': 'PREFIX-C-002',
                    'categoryId': 'domestic-supplier',
                    'arAmount': 25,
                  },
                  {
                    'id': 'client-near',
                    'partyName': 'NEAR-C-002',
                    'categoryId': 'overseas',
                    'arAmount': 75,
                  },
                ]
              : [
                  {
                    'id': 'supplier-page2',
                    'partyName': 'PAGE2-C-002',
                    'categoryId': 'domestic-supplier',
                    'arAmount': 50,
                  },
                ],
          page: page,
          total: 4,
          totalPages: 2,
        );
      }
      final label = keyword == null
          ? 'initial'
          : keyword == 'C-002'
          ? 'stale-C-002'
          : 'latest-$keyword';
      return _report(label);
    }
    if (path == '/user/preferences') {
      return const <String, dynamic>{'preferences': <String, dynamic>{}};
    }
    return const <String, dynamic>{};
  }
}

Map<String, dynamic> _report(String partyName) => <String, dynamic>{
  'columns': <Map<String, dynamic>>[
    <String, dynamic>{
      'key': 'partyName',
      'label': '往来单位',
      'type': 'text',
      'width': 220,
    },
  ],
  'rows': <Map<String, dynamic>>[
    <String, dynamic>{'partyName': partyName},
  ],
  'page': 1,
  'size': 50,
  'total': 1,
  'totalPages': 1,
};

Map<String, dynamic> _reportRows(
  List<Map<String, dynamic>> rows, {
  int page = 1,
  int total = 0,
  int totalPages = 1,
}) => {
  'columns': [
    {'key': 'partyName', 'label': '往来单位', 'type': 'text', 'width': 220},
    {'key': 'arAmount', 'label': '应收金额', 'type': 'money', 'width': 160},
  ],
  'rows': rows,
  'page': page,
  'size': 50,
  'total': total,
  'totalPages': totalPages,
  'totals': [
    {
      'key': 'arAmount',
      'label': '应收合计',
      'type': 'money',
      'groupKey': 'currency',
      'groups': [
        {'unit': '人民币', 'value': 250},
      ],
    },
  ],
};

class _ClientCategoryRepo implements ClientCategoryRepository {
  @override
  Future<CategoryPrefixAvailability> prefixAvailability(
    String prefix, {
    String? categoryId,
  }) => throw UnsupportedError('not used');

  @override
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'overseas',
      code: 'OVERSEAS',
      name: '海外客户',
      level: 0,
      children: [
        ProductCategoryNode(
          id: 'southeast-asia',
          code: 'SEA-001',
          name: '东南亚客户',
          level: 1,
          parentId: 'overseas',
          children: const [],
        ),
      ],
    ),
  ];

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) =>
      throw UnsupportedError('not used');
  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');
  @override
  Future<ProductCategoryDetail> detail(String id) =>
      throw UnsupportedError('not used');
  @override
  Future<List<ProductCategoryNode>> subtree(String id) =>
      throw UnsupportedError('not used');
  @override
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  ) => throw UnsupportedError('not used');
}

class _SupplierCategoryRepo implements SupplierCategoryRepository {
  @override
  Future<CategoryPrefixAvailability> prefixAvailability(
    String prefix, {
    String? categoryId,
  }) => throw UnsupportedError('not used');

  @override
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'domestic-supplier',
      code: 'SUP-DOM',
      name: '国内供应商',
      level: 0,
      children: const [],
    ),
  ];

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) =>
      throw UnsupportedError('not used');
  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');
  @override
  Future<ProductCategoryDetail> detail(String id) =>
      throw UnsupportedError('not used');
  @override
  Future<List<ProductCategoryNode>> subtree(String id) =>
      throw UnsupportedError('not used');
  @override
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  ) => throw UnsupportedError('not used');
}
