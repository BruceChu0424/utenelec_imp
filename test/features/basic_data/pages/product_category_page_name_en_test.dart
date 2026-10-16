import 'dart:async';
// ADR-134 goods list: the 英文名称 column sits right after 货品名称 and the
// search hint tells users the keyword also matches English names.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('英文名称 column follows 货品名称 and shows the learned value', (
    tester,
  ) async {
    final goods = _FakeGoodsRepository();
    await _pumpPage(tester, goods);

    await tester.tap(find.text('成品类'));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<GoodsListItem>>(
      find.byType(MasterDataTableView<GoodsListItem>),
    );
    final keys = table.columns.map((c) => c.key).toList();
    expect(keys.indexOf('nameEn'), keys.indexOf('name') + 1);
    final column = table.columns.firstWhere((c) => c.key == 'nameEn');
    expect(column.label, '英文名称');
    expect(column.info, contains('自动记住'));
    expect(find.text('DOUBLE 3 PIN SOCKET WITH SWITCH'), findsOneWidget);
    expect(find.text('搜索货品(名称/英文名称/编号/型号/规格/系列)'), findsWidgets);
    // Price columns still follow their own permission (none here).
    expect(keys, isNot(contains('price')));
    expect(tester.takeException(), isNull);
  });
  testWidgets('搜索展示全部匹配分类的扁平结果并保留服务端相关度，清空恢复原浏览分类', (tester) async {
    final goods = _FakeGoodsRepository(rankedSearch: true);
    await _pumpPage(tester, goods, rankedSearch: true);
    await tester.tap(find.text('近似分区'));
    await tester.pumpAndSettle();
    final tree = find.byType(UtenCategoryTreeView<ProductCategoryNode>);
    await tester.enterText(
      find.descendant(of: tree, matching: find.byType(EditableText)),
      'PART-001',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenCategoryTreeView<ProductCategoryNode>>(tree)
          .selectedIds,
      {_approximateCategory},
    );
    expect(goods.listCalls.last, (null, 'PART-001'));
    expect(find.text('精确货品'), findsOneWidget);
    expect(find.text('近似货品'), findsOneWidget);
    expect(find.text('PART-001'), findsWidgets);
    final table = tester.widget<MasterDataTableView<GoodsListItem>>(
      find.byType(MasterDataTableView<GoodsListItem>),
    );
    expect(table.items.map((row) => row.id), [
      'name-item',
      'exact-item',
      'approximate-item',
    ]);
    expect(table.leadingGroups, isEmpty);
    final callsBeforeTap = goods.listCalls.length;
    await tester.tap(find.text('精确分区'));
    await tester.pumpAndSettle();
    expect(goods.listCalls.length, callsBeforeTap, reason: '分类树只提示，不能截断右侧全局结果');
    await tester.enterText(
      find.descendant(of: tree, matching: find.byType(EditableText)),
      '',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(goods.listCalls.last, (_approximateCategory, null));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'new input immediately hides old export and rejects a late list response during debounce',
    (tester) async {
      final goods = _FakeGoodsRepository(
        rankedSearch: true,
        delayedKeyword: '旧关键词',
      );
      await _pumpPage(tester, goods, rankedSearch: true);
      final tree = find.byType(UtenCategoryTreeView<ProductCategoryNode>);
      final search = find.descendant(
        of: tree,
        matching: find.byType(EditableText),
      );
      await tester.enterText(search, '旧关键词');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump();
      expect(goods.listCalls.last, (null, '旧关键词'));
      await tester.enterText(search, 'PART-001');
      await tester.pump(const Duration(milliseconds: 50));
      final pane =
          tester.state(
                find.byType(MasterEntityDetailPane<GoodsListItem, GoodsDetail>),
              )
              as MasterEntityPaneController<GoodsListItem, GoodsDetail>;
      final callsBeforePendingRefresh = goods.listCalls.length;
      await pane.reload();
      expect(
        goods.listCalls.length,
        callsBeforePendingRefresh,
        reason: '防抖期间外部reload不得派发旧关键词请求',
      );
      await tester.binding.setSurfaceSize(const Size(375, 812));
      await tester.pump();
      goods.delayed.complete(
        const PagedResult(
          items: [GoodsListItem(id: 'old', name: '迟到旧行')],
          page: 1,
          size: 20,
          total: 1,
          totalPages: 1,
        ),
      );
      await tester.pump();
      expect(find.text('迟到旧行'), findsNothing);
      expect(find.byType(UtenExportButton), findsNothing);
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(goods.listCalls.last, (null, 'PART-001'));
      expect(find.text('迟到旧行'), findsNothing);
      final table = tester.widget<MasterDataTableView<GoodsListItem>>(
        find.byType(MasterDataTableView<GoodsListItem>),
      );
      expect(table.facets['series']!.single.value, '全球系列');
      expect(goods.globalFacetCalls, greaterThanOrEqualTo(1));
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(export.queryParams, isNot(contains('categoryId')));
      expect(export.queryParams['keyword'], 'PART-001');
      expect(export.queryParams['excludeDisabled'], isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'empty authorized category tree does not block global master search',
    (tester) async {
      final goods = _FakeGoodsRepository(rankedSearch: true);
      await _pumpPage(tester, goods, rankedSearch: true, emptyTree: true);
      await tester.enterText(find.byType(EditableText), 'PART-001');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(goods.listCalls.last, (null, 'PART-001'));
      final table = tester.widget<MasterDataTableView<GoodsListItem>>(
        find.byType(MasterDataTableView<GoodsListItem>),
      );
      expect(table.items.map((row) => row.id), [
        'name-item',
        'exact-item',
        'approximate-item',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}

const _exactCategory = 'ffffffff-ffff-ffff-ffff-fffffffffff1';
const _approximateCategory = '00000000-0000-0000-0000-000000000001';

Future<void> _pumpPage(
  WidgetTester tester,
  _FakeGoodsRepository goods, {
  bool rankedSearch = false,
  bool emptyTree = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        currentPermissionsProvider.overrideWithValue({Perm.goodsView}),
        isSuperAdminProvider.overrideWithValue(false),
        productCategoryRepositoryProvider.overrideWithValue(
          _FakeCategoryRepository(
            rankedSearch: rankedSearch,
            emptyTree: emptyTree,
          ),
        ),
        goodsRepositoryProvider.overrideWithValue(goods),
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
}

class _FakeCategoryRepository implements ProductCategoryRepository {
  _FakeCategoryRepository({this.rankedSearch = false, this.emptyTree = false});
  final bool emptyTree;
  final bool rankedSearch;
  @override
  Future<List<ProductCategoryNode>> tree() async => emptyTree
      ? []
      : rankedSearch
      ? [
          ProductCategoryNode(
            id: _approximateCategory,
            code: 'A',
            name: '近似分区',
            level: 0,
            children: const [],
          ),
          ProductCategoryNode(
            id: _exactCategory,
            code: 'Z',
            name: '精确分区',
            level: 0,
            children: const [],
          ),
        ]
      : [
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
  Future<ProductCategoryDetail> detail(String id) async => rankedSearch
      ? ProductCategoryDetail(
          id: id,
          code: id == _exactCategory ? 'Z' : 'A',
          name: id == _exactCategory ? '精确分区' : '近似分区',
          level: 0,
          path: '分区',
          childCount: 0,
          codePrefix: 'CP',
          effectivePrefix: 'CP',
        )
      : const ProductCategoryDetail(
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

class _FakeGoodsRepository implements GoodsRepository {
  _FakeGoodsRepository({this.rankedSearch = false, this.delayedKeyword});
  final String? delayedKeyword;
  final delayed = Completer<PagedResult<GoodsListItem>>();
  int globalFacetCalls = 0;
  final bool rankedSearch;
  final listCalls = <(String?, String?)>[];

  @override
  Future<Set<String>> searchCategoryIds(
    String keyword, {
    required Set<String> categoryRootIds,
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async => {_exactCategory, _approximateCategory};

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
  }) async {
    if (!disabledOnly && !stubOnly) listCalls.add((categoryId, keyword));
    if (keyword == delayedKeyword && keyword != null) return delayed.future;
    final items = disabledOnly || stubOnly
        ? const <GoodsListItem>[]
        : rankedSearch
        ? [
            if (categoryId == null)
              const GoodsListItem(
                id: 'name-item',
                code: 'NAME-OTHER',
                name: 'PART-001',
                categoryId: _approximateCategory,
                searchRank: 0,
              ),
            if (categoryId == _exactCategory || categoryId == null)
              const GoodsListItem(
                id: 'exact-item',
                code: 'PART-001',
                name: '精确货品',
                categoryId: _exactCategory,
                searchRank: 0,
              ),
            if (categoryId == _approximateCategory || categoryId == null)
              const GoodsListItem(
                id: 'approximate-item',
                code: 'OTHER',
                name: '近似货品',
                paper: '参考PART-001',
                categoryId: _approximateCategory,
                searchRank: 15,
              ),
          ]
        : const [
            GoodsListItem(
              id: 'goods-1',
              code: '280235165',
              name: '两开多功能三极插座',
              nameEn: 'DOUBLE 3 PIN SOCKET WITH SWITCH',
              nameEnSource: GoodsNameEnSource.learned,
              categoryId: 'finished',
              status: '使用',
            ),
          ];
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: items.isEmpty ? 0 : 1,
    );
  }

  @override
  Future<GoodsFacets> globalFacets() async {
    globalFacetCalls++;
    return const GoodsFacets(
      fields: {
        'series': [MasterFacetBucket(value: '全球系列', count: 300)],
      },
      nullCounts: {},
    );
  }

  @override
  Future<GoodsFacets> facets(String categoryId) async =>
      const GoodsFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
