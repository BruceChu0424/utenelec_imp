import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_goods_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import '../../../support/filter_segment_tap.dart';

void main() {
  testWidgets('货品主档默认主体、展开相关同表，facet导出与分类范围同源', (tester) async {
    final api = _GoodsApi();
    await _pump(tester, api);
    await tester.tap(find.text('原材料'));
    await tester.pumpAndSettle();
    await _search(tester, '螺丝');
    expect(_ids(tester), ['a', 'b']);
    expect(find.text('搜索范围：全部分类'), findsOneWidget);
    expect(_tree(tester).selectedIds, isEmpty);
    expect(tester.widget<CheckboxListTile>(_related).value, isFalse);
    final oldExport = tester.widget<UtenExportButton>(
      find.byType(UtenExportButton),
    );
    final exportContext = await oldExport.prepareExport!();
    expect(exportContext!.stillCurrent!(), isTrue);
    await tester.tap(_related);
    await tester.pumpAndSettle();
    expect(exportContext.stillCurrent!(), isFalse);
    expect(_ids(tester), ['a', 'b', 'r']);
    expect(find.text('相关'), findsOneWidget);
    final facets = api.requests.lastWhere(
      (r) => r.path.endsWith('/goods/facets'),
    );
    expect(facets.queryParameters['includeRelated'], isTrue);
    expect(facets.queryParameters['keyword'], '螺丝');
    expect(
      tester
          .widget<UtenExportButton>(find.byType(UtenExportButton))
          .queryParams['includeRelated'],
      isTrue,
    );
    _table(tester).onPageChange!(2);
    await tester.pumpAndSettle();
    expect(api.lastList.queryParameters['page'], 2);
    await tester.tap(find.text('成品'));
    await tester.pumpAndSettle();
    expect(api.lastList.queryParameters['categoryId'], 'cat-b');
    expect(api.lastList.queryParameters['includeRelated'], isTrue);
    expect(
      api.requests.any(
        (request) =>
            request.path == '/master/goods' &&
            request.queryParameters['categoryId'] == 'cat-b' &&
            request.queryParameters['page'] == 1,
      ),
      isTrue,
      reason: '分类切换从第一页开始；邻页预取不是当前浏览页',
    );
    expect(_ids(tester), ['b', 'r']);
    expect(_tree(tester).selectedIds, {'cat-b'});
    await tester.tap(find.byTooltip('清除分类范围，搜索全部分类'));
    await tester.pumpAndSettle();
    expect(api.lastList.queryParameters, isNot(contains('categoryId')));
    expect(_ids(tester), ['a', 'b', 'r']);
    await _search(tester, '');
    expect(_related.hitTestable(), findsNothing);
    expect(tester.widget<CheckboxListTile>(_related).value, isFalse);
    expect(api.lastList.queryParameters['categoryId'], 'cat-a');
    await _search(tester, '螺丝');
    expect(tester.widget<CheckboxListTile>(_related).value, isFalse);
    expect(api.lastList.queryParameters, isNot(contains('includeRelated')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('相关模式ABA旧响应不能覆盖新同模式结果', (tester) async {
    final api = _GoodsApi();
    await _pump(tester, api);
    await _search(tester, '螺丝');
    api.holdRelated = true;
    await tester.tap(_related);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<CheckboxListTile>(_related).value, isTrue);
    await tester.tap(_related);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(_related).value, isFalse);
    await tester.tap(_related);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.widget<CheckboxListTile>(_related).value, isTrue);
    expect(api.held.length, greaterThanOrEqualTo(2));
    final latest = api.held.length - 1;
    api.release(latest, 'new');
    await tester.pumpAndSettle();
    expect(_ids(tester), ['new']);
    // Resolving the new page may prepare an adjacent page. Only retire the
    // captured old cohort, never resolve the new response handler twice.
    for (var i = 0; i < latest; i++) {
      api.release(i, 'old');
    }
    await tester.pumpAndSettle();
    expect(_ids(tester), ['new']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通选择器展开相关与明确分类保持业务根和筛选，旧确认回调失效', (tester) async {
    final api = _GoodsApi();
    final selected = <GoodsListItem?>[];
    await _pump(tester, api, picker: true, selected: selected);
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await _search(tester, '螺丝');
    expect(find.byKey(const ValueKey('goods-picker-item-r')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('goods-picker-item-a')));
    await tester.pump();
    final oldConfirm = tester
        .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
        .onConfirm;
    await tester.tap(_related);
    await tester.pumpAndSettle();
    oldConfirm!();
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.byKey(const Key('goods-picker-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('goods-picker-item-r')), findsOneWidget);
    expect(find.text('相关结果'), findsOneWidget);
    await tester.tap(find.text('成品'));
    await tester.pumpAndSettle();
    expect(api.lastList.queryParameters['categoryId'], 'cat-b');
    expect(api.lastList.queryParameters['categoryRootIds'], [
      'cat-a',
      'cat-b',
      'cat-c',
    ]);
    expect(api.lastList.queryParameters['excludeDisabled'], isTrue);
    expect(api.lastList.queryParameters['excludeStub'], isTrue);
    final location = api.requests.lastWhere(
      (r) => r.path.endsWith('search-category-ids'),
    );
    expect(location.queryParameters['categoryId'], 'cat-b');
    expect(location.queryParameters['includeRelated'], isTrue);
    expect(find.byKey(const ValueKey('goods-picker-item-a')), findsNothing);
    await tester.tap(find.byTooltip('清除分类范围，搜索全部分类'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goods-picker-item-a')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('BOM组件范围默认保留，显式全部可选货品能找到新增自定义根', (tester) async {
    final api = _GoodsApi();
    await _pump(tester, api, picker: true, bom: true);
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await _search(tester, '自定义');
    expect(api.lastList.queryParameters['categoryRootIds'], ['cat-a']);
    expect(find.byKey(const ValueKey('goods-picker-item-c')), findsNothing);
    await selectFilterSegment(tester, '全部可选货品');
    await tester.pumpAndSettle();
    expect(api.lastList.queryParameters, isNot(contains('categoryRootIds')));
    expect(find.byKey(const ValueKey('goods-picker-item-c')), findsOneWidget);
    expect(api.lastList.queryParameters['excludeDisabled'], isTrue);
    expect(api.lastList.queryParameters['excludeStub'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('专用候选源不显示相关开关、不调用master，显式分类仍走专用list', (tester) async {
    final api = _GoodsApi();
    final source = _DedicatedSource();
    await _pump(tester, api, picker: true, source: source);
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await _search(tester, '螺丝');
    expect(_related, findsNothing);
    expect(source.searches, ['螺丝']);
    await tester.tap(find.text('成品'));
    await tester.pumpAndSettle();
    expect(source.lists, [('cat-b', '螺丝')]);
    expect(api.requests, isEmpty);
    expect(find.byKey(const ValueKey('goods-picker-item-b')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空组件范围不会退化成全库请求，显式展开才查询新增根', (tester) async {
    final api = _GoodsApi()..noComponents = true;
    await _pump(tester, api, picker: true, bom: true);
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await _search(tester, '自定义');
    expect(api.requests.where((r) => r.path == '/master/goods'), isEmpty);
    await selectFilterSegment(tester, '全部可选货品');
    await tester.pumpAndSettle();
    expect(api.lastList.queryParameters, isNot(contains('categoryRootIds')));
    expect(find.byKey(const ValueKey('goods-picker-item-c')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final failLocation in [false, true]) {
    testWidgets('显式全部可选搜索可确认未分类货品并保留单位，定位失败=$failLocation', (tester) async {
      final api = _GoodsApi()..failLocation = failLocation;
      final results = <List<GoodsListItem>>[];
      await _pump(tester, api, picker: true, bom: true, selectedMulti: results);
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();
      await _search(tester, '4*50');
      expect(api.lastList.queryParameters['categoryRootIds'], ['cat-a']);
      expect(_uncategorizedTile, findsNothing);

      await selectFilterSegment(tester, '全部可选货品');
      await tester.pumpAndSettle();
      expect(api.lastList.queryParameters, isNot(contains('categoryRootIds')));
      expect(api.lastList.queryParameters, isNot(contains('categoryId')));
      expect(api.lastList.queryParameters['excludeDisabled'], isTrue);
      expect(api.lastList.queryParameters['excludeStub'], isTrue);
      expect(_uncategorizedTile, findsOneWidget);
      final location = api.requests.lastWhere(
        (r) => r.path.endsWith('search-category-ids'),
      );
      expect(location.queryParameters['categoryRootIds'], [
        'cat-a',
        'cat-b',
        'cat-c',
      ]);
      expect(find.text('未找到匹配「4*50」的分类'), findsOneWidget);
      await tester.tap(_uncategorizedTile);
      await tester.pump();
      expect(_confirmBar(tester).selectedCount, 1);
      await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
      await tester.pumpAndSettle();
      expect(results, hasLength(1));
      final goods = results.single.single;
      expect(goods.id, _uncategorizedId);
      expect(goods.code, '280333062');
      expect(goods.name, '螺丝');
      expect(goods.spec, '4*50');
      expect(goods.unitId, _uncategorizedUnitId);
      expect(goods.unitName, '只');
      expect(goods.categoryId, isNull);
      expect(goods.autoCreated, isFalse);
      expect(goods.status, '使用');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('全部可选手选分类恢复根范围，服务端漏出的未分类行与旧确认被拒绝', (tester) async {
    final api = _GoodsApi();
    final results = <List<GoodsListItem>>[];
    await _pump(tester, api, picker: true, bom: true, selectedMulti: results);
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await _search(tester, '4*50');
    await selectFilterSegment(tester, '全部可选货品');
    await tester.pumpAndSettle();
    await tester.tap(_uncategorizedTile);
    await tester.pump();
    final oldConfirm = _confirmBar(tester).onConfirm!;

    await _search(tester, '螺丝');
    api.leakUncategorized = true;
    await tester.tap(find.text('原材料'));
    await tester.pumpAndSettle();
    expect(api.lastList.queryParameters['categoryId'], 'cat-a');
    expect(api.lastList.queryParameters['categoryRootIds'], [
      'cat-a',
      'cat-b',
      'cat-c',
    ]);
    expect(_uncategorizedTile, findsNothing);
    expect(_confirmBar(tester).selectedCount, 0);
    oldConfirm();
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(find.byKey(const Key('goods-picker-sheet')), findsOneWidget);
    expect(find.text('搜索货品失败，请稍后重试'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部可选模式仍拒绝未知非空分类，不把服务端越界行当作未分类', (tester) async {
    final api = _GoodsApi()..unknownCategory = true;
    await _pump(tester, api, picker: true, bom: true);
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await _search(tester, '4*50');
    await selectFilterSegment(tester, '全部可选货品');
    await tester.pumpAndSettle();
    expect(api.lastList.queryParameters, isNot(contains('categoryRootIds')));
    expect(_uncategorizedTile, findsNothing);
    expect(
      find.byKey(const ValueKey('goods-picker-item-unknown')),
      findsNothing,
    );
    expect(find.text('搜索货品失败，请稍后重试'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('范围及相关开关ABA均使未分类货品的旧确认失效', (tester) async {
    final api = _GoodsApi();
    final results = <List<GoodsListItem>>[];
    await _pump(tester, api, picker: true, bom: true, selectedMulti: results);
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await _search(tester, '4*50');
    await selectFilterSegment(tester, '全部可选货品');
    await tester.pumpAndSettle();
    await tester.tap(_uncategorizedTile);
    await tester.pump();
    final oldScopeConfirm = _confirmBar(tester).onConfirm!;
    await selectFilterSegment(tester, '当前组件范围');
    await tester.pumpAndSettle();
    expect(api.lastList.queryParameters['categoryRootIds'], ['cat-a']);
    expect(_uncategorizedTile, findsNothing);
    await selectFilterSegment(tester, '全部可选货品');
    await tester.pumpAndSettle();
    oldScopeConfirm();
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(_confirmBar(tester).selectedCount, 0);

    await tester.tap(_uncategorizedTile);
    await tester.pump();
    final oldRelatedConfirm = _confirmBar(tester).onConfirm!;
    await tester.tap(_related);
    await tester.pumpAndSettle();
    await tester.tap(_related);
    await tester.pumpAndSettle();
    oldRelatedConfirm();
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(_confirmBar(tester).selectedCount, 0);
    expect(find.byKey(const Key('goods-picker-sheet')), findsOneWidget);
    await tester.tap(_uncategorizedTile);
    await tester.pump();
    await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
    await tester.pumpAndSettle();
    expect(results.single.single.id, _uncategorizedId);
    expect(tester.takeException(), isNull);
  });

  for (final dedicated in [false, true]) {
    testWidgets('非显式全部模式继续拒绝未分类货品，专用候选=$dedicated', (tester) async {
      final api = _GoodsApi()..leakUncategorized = true;
      await _pump(
        tester,
        api,
        picker: true,
        bom: dedicated,
        source: dedicated ? _DedicatedSource(uncategorized: true) : null,
      );
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();
      await _search(tester, '4*50');
      expect(_uncategorizedTile, findsNothing);
      expect(find.text('全部可选货品'), findsNothing);
      expect(find.text('搜索货品失败，请稍后重试'), findsWidgets);
      if (dedicated) {
        expect(api.requests, isEmpty);
      } else {
        expect(api.lastList.queryParameters['categoryRootIds'], [
          'cat-a',
          'cat-b',
          'cat-c',
        ]);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final failTree in [false, true]) {
    testWidgets('分类树空或失败不能自动开启全库搜索，失败=$failTree', (tester) async {
      final api = _GoodsApi()
        ..emptyTree = !failTree
        ..failTree = failTree;
      final results = <List<GoodsListItem>>[];
      await _pump(tester, api, picker: true, bom: true, selectedMulti: results);
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-picker-sheet')), findsNothing);
      expect(api.requests.where((r) => r.path == '/master/goods'), isEmpty);
      expect(results.single, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('选择器相关模式ABA拒绝旧同模式响应', (tester) async {
    final api = _GoodsApi();
    await _pump(tester, api, picker: true);
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await _search(tester, '螺丝');
    api.holdRelated = true;
    await tester.tap(_related);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(_related);
    await tester.pumpAndSettle();
    await tester.tap(_related);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(api.held.length, greaterThanOrEqualTo(2));
    final latest = api.held.length - 1;
    api.release(latest, 'new');
    await tester.pumpAndSettle();
    for (var i = 0; i < latest; i++) {
      api.release(i, 'old');
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goods-picker-item-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('goods-picker-item-old')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字的范围提示和相关开关可用且不溢出', (tester) async {
    final api = _GoodsApi();
    await _pump(tester, api, size: const Size(390, 900), scale: 1.8);
    await _search(tester, '螺丝');
    await tester.tap(_related);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(_related).value, isTrue);
    expect(find.text('搜索范围：全部分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择器窄屏大字可展开相关，查询范围提示保持可见', (tester) async {
    final api = _GoodsApi();
    await _pump(
      tester,
      api,
      picker: true,
      size: const Size(390, 900),
      scale: 1.8,
    );
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await _search(tester, '螺丝');
    await tester.tap(_related);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(_related).value, isTrue);
    expect(find.text('搜索范围：全部分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Finder get _related => find.byKey(const ValueKey('goods-search-related'));
const _uncategorizedId = 'e2e3edd0-708a-480c-a5d1-93d902a70ece';
const _uncategorizedUnitId = 'f42621ad-93f4-497a-a281-6f94f318d219';
Finder get _uncategorizedTile =>
    find.byKey(const ValueKey('goods-picker-item-$_uncategorizedId'));
UtenPickerConfirmBar _confirmBar(WidgetTester tester) =>
    tester.widget(find.byType(UtenPickerConfirmBar));
MasterDataTableView<GoodsListItem> _table(WidgetTester t) =>
    t.widget(find.byType(MasterDataTableView<GoodsListItem>));
List<String> _ids(WidgetTester t) => _table(t).items.map((r) => r.id).toList();
UtenCategoryTreeView<ProductCategoryNode> _tree(WidgetTester t) =>
    t.widget(find.byType(UtenCategoryTreeView<ProductCategoryNode>));
Future<void> _search(WidgetTester t, String text) async {
  final search = find.descendant(
    of: find.byType(UtenSearchBar).first,
    matching: find.byType(TextField),
  );
  await t.enterText(search, text);
  await t.pump(const Duration(milliseconds: 350));
  await t.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester t,
  _GoodsApi api, {
  bool picker = false,
  bool bom = false,
  UtenGoodsPickerDataSource? source,
  List<GoodsListItem?>? selected,
  List<List<GoodsListItem>>? selectedMulti,
  Size size = const Size(1800, 1000),
  double scale = 1,
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(api.dio)),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsExport,
          Perm.materialCategoryView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: picker
            ? Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: ElevatedButton(
                    onPressed: () async {
                      if (bom) {
                        final result = await showUtenGoodsPickerMulti(
                          context,
                          ref,
                          dataSource: source,
                          allowScopeExpansion: true,
                        );
                        selectedMulti?.add(result);
                      } else {
                        final result = await showUtenGoodsPicker(
                          context,
                          ref,
                          scope: UtenGoodsPickerScope.all,
                          dataSource: source,
                        );
                        selected?.add(result);
                      }
                    },
                    child: const Text('打开选择器'),
                  ),
                ),
              )
            : const ProductCategoryPage(),
      ),
    ),
  );
  await t.pumpAndSettle();
}

class _DedicatedSource extends UtenGoodsPickerDataSource {
  _DedicatedSource({this.uncategorized = false});
  final bool uncategorized;
  final searches = <String>[];
  final lists = <(String, String?)>[];
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode.fromJson(_category('cat-a', '原材料')),
    ProductCategoryNode.fromJson(_category('cat-b', '成品')),
  ];
  @override
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    required int page,
  }) async {
    searches.add(keyword);
    if (uncategorized) {
      return PagedResult(
        items: [GoodsListItem.fromJson(_uncategorizedRow())],
        page: page,
        size: 20,
        total: 1,
        totalPages: 1,
      );
    }
    return _rows(page, ['a', 'b']);
  }

  @override
  Future<PagedResult<GoodsListItem>> list(
    String categoryId, {
    required int page,
    String? keyword,
  }) async {
    lists.add((categoryId, keyword));
    return _rows(page, [categoryId == 'cat-a' ? 'a' : 'b']);
  }

  @override
  Future<Set<String>> searchCategoryIds(String keyword) async => {
    'cat-a',
    'cat-b',
  };
  PagedResult<GoodsListItem> _rows(int page, List<String> ids) => PagedResult(
    items: [
      for (final id in ids)
        GoodsListItem(id: id, name: '专用物料$id', categoryId: 'cat-$id'),
    ],
    page: page,
    size: 20,
    total: ids.length,
    totalPages: 1,
  );
}

class _GoodsApi {
  _GoodsApi() {
    dio.interceptors.add(InterceptorsWrapper(onRequest: _request));
  }
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  final requests = <RequestOptions>[];
  final held = <(RequestOptions, RequestInterceptorHandler)>[];
  bool holdRelated = false;
  bool noComponents = false;
  bool failLocation = false;
  bool leakUncategorized = false;
  bool unknownCategory = false;
  bool emptyTree = false;
  bool failTree = false;
  RequestOptions get lastList =>
      requests.lastWhere((r) => r.path == '/master/goods');
  void release(int index, String id) {
    final (r, h) = held[index];
    h.resolve(
      Response(
        requestOptions: r,
        statusCode: 200,
        data: _page([_row(id, '最新结果', 'cat-a')], 1),
      ),
    );
  }

  void _request(RequestOptions r, RequestInterceptorHandler h) {
    requests.add(r);
    final q = r.queryParameters;
    Object data = <String, dynamic>{};
    if (r.path == '/master/material-categories/tree') {
      if (failTree) {
        h.reject(DioException(requestOptions: r));
        return;
      }
      data = [
        _category(
          'cat-a',
          noComponents ? '独立零件' : '原材料',
          legacy: noComponents ? null : 2113,
        ),
        _category('cat-b', '成品'),
        _category('cat-c', '新增自定义根'),
      ];
      if (emptyTree) data = <Object>[];
    } else if (r.path.startsWith('/master/material-categories/')) {
      final id = r.path.split('/').last;
      data = _category(
        id,
        id == 'cat-a'
            ? '原材料'
            : id == 'cat-b'
            ? '成品'
            : '新增自定义根',
      );
    } else if (r.path.endsWith('/search-category-ids')) {
      if (failLocation) {
        h.reject(DioException(requestOptions: r));
        return;
      }
      data = ['cat-a', 'cat-b'];
      if ((q['keyword'] as String?) == '自定义') data = ['cat-c'];
      if ((q['keyword'] as String?) == '4*50') data = <String>[];
      final roots = q['categoryRootIds'] as List?;
      data = (data as List)
          .where(
            (id) =>
                (roots == null || roots.contains(id)) &&
                (q['categoryId'] == null || q['categoryId'] == id),
          )
          .toList();
    } else if (r.path == '/master/goods') {
      if (holdRelated && q['includeRelated'] == true) {
        held.add((r, h));
        return;
      }
      final keyword = q['keyword'] as String? ?? '';
      var rows = keyword == '自定义'
          ? [_row('c', '自定义货品', 'cat-c')]
          : keyword == '4*50'
          ? [_uncategorizedRow()]
          : [
              _row('a', '螺丝', 'cat-a'),
              _row('b', '螺丝配件', 'cat-b'),
              if (q['includeRelated'] == true)
                _row('r', '插座', 'cat-b', related: true),
            ];
      final roots = q['categoryRootIds'] as List?;
      rows = rows
          .where(
            (row) =>
                (roots == null || roots.contains(row['categoryId'])) &&
                (q['categoryId'] == null ||
                    q['categoryId'] == row['categoryId']),
          )
          .toList();
      if (leakUncategorized) rows.add(_uncategorizedRow());
      if (unknownCategory && roots == null) {
        rows.add(_row('unknown', '未知分类货品', 'unknown-category'));
      }
      data = _page(rows, (q['page'] as int?) ?? 1);
    }
    h.resolve(Response(requestOptions: r, statusCode: 200, data: data));
  }
}

Map<String, dynamic> _category(String id, String name, {int? legacy}) => {
  'id': id,
  'name': name,
  'code': id,
  'level': 0,
  'path': '/$id/',
  'childCount': 0,
  'children': <Object>[],
  'legacyId': legacy,
  'version': 0,
};
Map<String, dynamic> _row(
  String id,
  String name,
  String? category, {
  bool related = false,
}) => {
  'id': id,
  'name': name,
  'code': id,
  'categoryId': category,
  'status': '使用',
  'version': 0,
  'searchMatchKind': related ? 'RELATED' : 'PRIMARY',
  'searchRank': related ? 100 : 0,
};
Map<String, dynamic> _uncategorizedRow() => {
  ..._row(_uncategorizedId, '螺丝', null),
  'code': '280333062',
  'spec': '4*50',
  'unitId': _uncategorizedUnitId,
  'unitName': '只',
  'autoCreated': false,
};
Map<String, dynamic> _page(List<Map<String, dynamic>> rows, int page) => {
  'items': rows,
  'page': page,
  'size': 20,
  'total': rows.length + 20,
  'totalPages': 2,
};
