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
    expect(api.lastList.queryParameters['page'], 1);
    expect(_ids(tester), ['b', 'r']);
    expect(_tree(tester).selectedIds, {'cat-b'});
    await tester.tap(find.byTooltip('清除分类范围，搜索全部分类'));
    await tester.pumpAndSettle();
    expect(api.lastList.queryParameters, isNot(contains('categoryId')));
    expect(_ids(tester), ['a', 'b', 'r']);
    await _search(tester, '');
    expect(_related, findsNothing);
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
    api.release(api.held.length - 1, 'new');
    await tester.pumpAndSettle();
    expect(_ids(tester), ['new']);
    for (var i = 0; i < api.held.length - 1; i++) {
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
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('goods-picker-item-r')),
        matching: find.textContaining('相关结果'),
      ),
      findsOneWidget,
    );
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
    expect(api.lastList.queryParameters['categoryRootIds'], [
      'cat-a',
      'cat-b',
      'cat-c',
    ]);
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
    expect(api.lastList.queryParameters['categoryRootIds'], [
      'cat-a',
      'cat-b',
      'cat-c',
    ]);
    expect(find.byKey(const ValueKey('goods-picker-item-c')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
    api.release(api.held.length - 1, 'new');
    await tester.pumpAndSettle();
    for (var i = 0; i < api.held.length - 1; i++) {
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
                        await showUtenGoodsPickerMulti(
                          context,
                          ref,
                          allowScopeExpansion: true,
                        );
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
      data = [
        _category(
          'cat-a',
          noComponents ? '独立零件' : '原材料',
          legacy: noComponents ? null : 2113,
        ),
        _category('cat-b', '成品'),
        _category('cat-c', '新增自定义根'),
      ];
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
      data = ['cat-a', 'cat-b'];
      if ((q['keyword'] as String?) == '自定义') data = ['cat-c'];
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
  String category, {
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
Map<String, dynamic> _page(List<Map<String, dynamic>> rows, int page) => {
  'items': rows,
  'page': page,
  'size': 20,
  'total': rows.length + 20,
  'totalPages': 2,
};
