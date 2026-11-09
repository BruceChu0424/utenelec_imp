import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_facet_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

/// The server's two assembly buckets (GoodsService#bomPresenceBuckets).
const _serverBuckets = <Map<String, dynamic>>[
  {'value': 'true', 'count': 2, 'label': '有组装信息'},
  {'value': 'false', 'count': 1, 'label': '无组装信息'},
];

void main() {
  // remote=false: the /facets buckets feed the header directly.
  // remote=true: a header key present in facets reads /facet-values, so the
  // server must answer field=hasBom (otherwise the menu shows a load failure).
  for (final remote in [false, true]) {
    testWidgets(
      'assembly header lists present/absent server buckets and filters through hasBom '
      '(${remote ? 'facet-values' : 'facets'})',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repository = _GoodsWithAssembly();
        final api = _FacetValuesApi();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(
                await SharedPreferences.getInstance(),
              ),
              currentPermissionsProvider.overrideWithValue({
                Perm.goodsView,
                Perm.materialCategoryView,
              }),
              productCategoryRepositoryProvider.overrideWithValue(
                _FinishedCategory(),
              ),
              goodsRepositoryProvider.overrideWithValue(repository),
              goodsFacetRepositoryProvider.overrideWithValue(
                remote ? GoodsFacetRepository(api) : null,
              ),
            ],
            child: const MaterialApp(
              locale: Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: ProductCategoryPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('成品类'));
        await tester.pumpAndSettle();

        MasterDataTableView<GoodsListItem> table() =>
            tester.widget(find.byType(MasterDataTableView<GoodsListItem>));
        final column = table().columns.singleWhere(
          (column) => column.key == 'hasBom',
        );
        // Not a text column: no keyword search (search.hasBom is rejected by
        // the server) and no row-local filter on a paged table.
        expect(column.columnSearchEnabled, isFalse);
        expect(column.supportsKeywordSearch, isFalse);
        expect(column.filterFromRows, isFalse);
        expect(table().facets['hasBom']!.map((bucket) => bucket.value), [
          'true',
          'false',
        ]);
        expect(table().facets['hasBom']!.map((bucket) => bucket.display), [
          '有组装信息',
          '无组装信息',
        ]);

        final header = find.byKey(
          const ValueKey('master-column-filter-hasBom'),
        );
        Future<void> openHeader() async {
          await tester.ensureVisible(header.first);
          await tester.pumpAndSettle();
          await tester.tap(header.first);
          await tester.pumpAndSettle();
        }

        await openHeader();
        expect(find.text('有组装信息 (2)'), findsOneWidget);
        expect(find.text('无组装信息 (1)'), findsOneWidget);
        expect(
          find.byKey(const Key('uten-column-keyword-search')),
          findsNothing,
        );
        if (remote) {
          expect(api.facetQueries, isNotEmpty);
          expect(api.facetQueries.last['field'], 'hasBom');
          expect(api.facetQueries.last['categoryId'], 'finished');
          expect(api.facetQueries.last.containsKey('hasBom'), isFalse);
        }

        await tester.tap(find.text('有组装信息 (2)'));
        await tester.pumpAndSettle();
        var current = repository.mainCalls.last;
        expect(current.filters, {'hasBom': 'true'});
        expect(table().filters['hasBom'], 'true');
        expect(table().items.map((item) => item.id), ['with-bom']);
        expect(
          find.descendant(of: header.first, matching: find.text('有组装信息')),
          findsOneWidget,
        );

        await openHeader();
        if (remote) {
          // The menu's own selection is released for its candidates while the
          // other active conditions stay in scope.
          expect(api.facetQueries.last['field'], 'hasBom');
          expect(api.facetQueries.last['hasBom'], 'true');
        }
        await tester.tap(find.text('无组装信息 (1)'));
        await tester.pumpAndSettle();
        current = repository.mainCalls.last;
        expect(current.filters, {'hasBom': 'false'});
        expect(table().items.map((item) => item.id), ['without-bom']);

        await openHeader();
        await tester.tap(find.text('所有'));
        await tester.pumpAndSettle();
        current = repository.mainCalls.last;
        expect(current.filters, isEmpty);
        expect(table().items.map((item) => item.id), [
          'with-bom',
          'without-bom',
        ]);
        expect(
          repository.calls.any(
            (call) => call.filters.keys.any((key) => key.startsWith('search.')),
          ),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _FinishedCategory implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'finished',
      code: 'C-FIN',
      name: '成品类',
      level: 0,
      codePrefix: 'CP',
      children: const [],
    ),
  ];

  @override
  Future<ProductCategoryDetail> detail(String id) async =>
      const ProductCategoryDetail(
        id: 'finished',
        code: 'C-FIN',
        name: '成品类',
        level: 0,
        path: '成品类',
        childCount: 0,
        codePrefix: 'CP',
        effectivePrefix: 'CP',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Read = ({Map<String, String?> filters, bool disabled, bool stub});

class _GoodsWithAssembly implements GoodsRepository {
  final calls = <_Read>[];
  Iterable<_Read> get mainCalls =>
      calls.where((call) => !call.disabled && !call.stub);

  @override
  Future<PagedResult<GoodsListItem>> list(
    String? categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool excludeDisabled = false,
    bool excludeStub = false,
    bool disabledOnly = false,
    bool stubOnly = false,
    bool includeRelated = false,
  }) async {
    calls.add((filters: {...filters}, disabled: disabledOnly, stub: stubOnly));
    // Mirrors the server: hasBom=true/false is the authoritative predicate.
    final rows = disabledOnly || stubOnly
        ? const <GoodsListItem>[]
        : [
                const GoodsListItem(
                  id: 'with-bom',
                  code: 'CP-001',
                  name: '组装成品',
                  hasBom: true,
                  status: '使用',
                ),
                const GoodsListItem(
                  id: 'without-bom',
                  code: 'CP-002',
                  name: '散件',
                  status: '使用',
                ),
              ]
              .where(
                (row) =>
                    filters['hasBom'] == null ||
                    row.hasBom == (filters['hasBom'] == 'true'),
              )
              .toList();
    return PagedResult(
      items: rows,
      page: page,
      size: size,
      total: rows.length,
      totalPages: 1,
    );
  }

  @override
  Future<GoodsFacets> facets(
    String categoryId, {
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async => GoodsFacets.fromJson({
    'hasBom': _serverBuckets,
    'nullCounts': <String, dynamic>{},
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FacetValuesApi extends ApiClient {
  _FacetValuesApi() : super(Dio());
  final facetQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.endsWith('/facet-values')) {
      throw StateError('Unexpected request: $path');
    }
    facetQueries.add({...?query});
    return {'items': _serverBuckets, 'hasMore': false};
  }
}
