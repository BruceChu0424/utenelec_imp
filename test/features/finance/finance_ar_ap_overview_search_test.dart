import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/client_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_overview_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'left search locates a party by code and category taps keep the query',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(tester, prefs: prefs, api: api);

      expect(
        find.byKey(const ValueKey('finance-ar-ap-unified-search')),
        findsOneWidget,
      );
      expect(find.text('搜索往来单位'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('finance-ar-ap-unified-search')),
        'C-002',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(
        api.locationQueries
            .where((query) => query['keyword'] == 'C-002')
            .map((query) => query['page']),
        [1, 2],
      );
      final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
        find.byType(UtenCategoryTreeView<ProductCategoryNode>),
      );
      expect(
        tree.visibleFilterIds,
        containsAll(<String>{'__client_root__', 'overseas', 'southeast-asia'}),
      );
      expect(tree.selectedIds, {'southeast-asia'});
      expect(api.reportQueries, contains(containsPair('keyword', 'C-002')));
      expect(
        api.reportQueries,
        contains(
          allOf(
            containsPair('categoryType', 'CLIENT'),
            containsPair('categoryId', 'southeast-asia'),
          ),
        ),
      );

      await tester.tap(find.textContaining('海外客户'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey('finance-ar-ap-unified-search')),
                matching: find.byType(TextField),
              ),
            )
            .controller
            ?.text,
        'C-002',
      );
      expect(
        api.reportQueries.last,
        allOf(
          containsPair('keyword', 'C-002'),
          containsPair('categoryType', 'CLIENT'),
          containsPair('categoryId', 'overseas'),
        ),
      );
    },
  );

  testWidgets('category-only code search shows the whole selected category', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _OverviewApi();
    await _pumpPage(tester, prefs: prefs, api: api);

    await tester.enterText(
      find.byKey(const ValueKey('finance-ar-ap-unified-search')),
      'SEA-001',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.selectedIds, {'southeast-asia'});
    expect(api.reportQueries.last['categoryType'], 'CLIENT');
    expect(api.reportQueries.last['categoryId'], 'southeast-asia');
    expect(api.reportQueries.last, isNot(contains('keyword')));
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('finance-ar-ap-unified-search')),
              matching: find.byType(TextField),
            ),
          )
          .controller
          ?.text,
      'SEA-001',
    );
  });

  testWidgets('stale report response cannot replace the latest search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _OverviewApi(delayFirstSearch: true);
    await _pumpPage(tester, prefs: prefs, api: api);

    final search = find.byKey(const ValueKey('finance-ar-ap-unified-search'));
    await tester.enterText(search, 'C-002');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.enterText(search, 'C-003');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('latest-C-003'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('stale-C-002'), findsNothing);
    expect(find.text('latest-C-003'), findsOneWidget);
  });

  testWidgets('no category and no party match does not show unfiltered rows', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _OverviewApi();
    await _pumpPage(tester, prefs: prefs, api: api);
    final initialReportCalls = api.reportQueries.length;

    await tester.enterText(
      find.byKey(const ValueKey('finance-ar-ap-unified-search')),
      'NO-SUCH-PARTY',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('未找到匹配「NO-SUCH-PARTY」的分类或往来单位'), findsOneWidget);
    expect(api.reportQueries.length, initialReportCalls);
  });

  testWidgets('manual tree choice wins over an in-flight locator', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _OverviewApi(delayLocationKeyword: 'OVER');
    await _pumpPage(tester, prefs: prefs, api: api);

    await tester.enterText(
      find.byKey(const ValueKey('finance-ar-ap-unified-search')),
      'OVER',
    );
    await tester.pump(const Duration(milliseconds: 320));
    await tester.tap(find.textContaining('海外客户'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.selectedIds, {'overseas'});
    expect(api.reportQueries.last['categoryId'], 'overseas');
  });

  testWidgets(
    'failed locator clears a superseded in-flight report loading state',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(tester, prefs: prefs, api: api);

      api.holdNextReport();
      await tester.tap(find.widgetWithText(FilledButton, '查询'));
      await tester.pump();
      expect(api.heldReport, isNotNull);
      expect(
        tester
            .widget<MasterDataTableView<Map<String, dynamic>>>(
              find.byType(MasterDataTableView<Map<String, dynamic>>),
            )
            .isLoading,
        isTrue,
      );

      final search = find.descendant(
        of: find.byKey(const ValueKey('finance-ar-ap-unified-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, 'LOCATOR-FAIL');
      await tester.pump();
      expect(
        tester
            .widget<MasterDataTableView<Map<String, dynamic>>>(
              find.byType(MasterDataTableView<Map<String, dynamic>>),
            )
            .isLoading,
        isFalse,
      );

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.textContaining('往来单位搜索失败'), findsOneWidget);
      expect(
        tester
            .widget<MasterDataTableView<Map<String, dynamic>>>(
              find.byType(MasterDataTableView<Map<String, dynamic>>),
            )
            .isLoading,
        isFalse,
      );

      api.completeHeldReport('stale-held-report');
      await tester.pump();
      expect(find.text('stale-held-report'), findsNothing);
      expect(find.text('initial'), findsOneWidget);
    },
  );
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required _OverviewApi api,
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

class _ClientCategoryRepo implements ClientCategoryRepository {
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
