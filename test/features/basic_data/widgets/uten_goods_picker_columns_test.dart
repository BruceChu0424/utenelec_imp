import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_goods_picker.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../../support/filter_segment_tap.dart';

void main() {
  test(
    'column filters survive every bounded root batch for both rows and category location',
    () async {
      final api = _ColumnApi();
      final repository = DioGoodsRepository(api);
      final roots = {for (var index = 0; index < 33; index++) 'root-$index'};
      const filters = {'search.series': '5m', 'search.name': '开关'};
      final result = await repository.searchColumns(
        '开关',
        filters: filters,
        categoryRootIds: roots,
        excludeDisabled: true,
        excludeStub: true,
        sort: 'code',
        order: 'asc',
      );
      await repository.searchColumnCategoryIds(
        '开关',
        filters: filters,
        categoryRootIds: roots,
        excludeDisabled: true,
        excludeStub: true,
      );
      expect(result.total, 0);
      expect(api.reads, hasLength(2));
      expect(api.locations, hasLength(2));
      for (final request in [...api.reads, ...api.locations]) {
        expect(request['search.series'], '5m');
        expect(request['search.name'], '开关');
        expect(
          (request['categoryRootIds'] as List).length,
          inInclusiveRange(1, 32),
        );
        expect(request['excludeDisabled'], isTrue);
        expect(request['excludeStub'], isTrue);
      }
      expect(
        api.reads.expand((query) => query['categoryRootIds'] as List).toSet(),
        roots,
      );
      expect(
        api.locations
            .expand((query) => query['categoryRootIds'] as List)
            .toSet(),
        roots,
      );
    },
  );
  testWidgets(
    'series and name headers AND on the server inside the component scope, retaining color identities',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(2000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final api = _ColumnApi();
      final selected = <GoodsListItem>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            productCategoryRepositoryProvider.overrideWithValue(_Categories()),
            sharedPreferencesProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () async => selected.addAll(
                    await showUtenGoodsPickerMulti(
                      context,
                      ref,
                      allowScopeExpansion: true,
                      initialKeyword: '开关',
                    ),
                  ),
                  child: const Text('添加组件'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('添加组件'));
      await tester.pumpAndSettle();
      MasterDataTableView<GoodsListItem> table() =>
          tester.widget(find.byKey(const Key('goods-picker-paged-list')));
      expect(table().columns.map((column) => column.key), [
        'name',
        'code',
        'series',
        'model',
        'spec',
        'colorLegacyId',
        'unitLegacyId',
      ]);
      expect(table().serverColumnSearch, isTrue);
      table().onFilterChanged('search.series', '5m');
      await tester.pumpAndSettle();
      table().onFilterChanged('search.name', '开关');
      await tester.pumpAndSettle();
      expect(table().items.map((item) => item.id).toSet(), {'black', 'white'});
      expect(table().items.map((item) => item.colorName).toSet(), {'黑色', '白色'});
      expect(table().items.map((item) => item.colorId).toSet(), {
        'color-black',
        'color-white',
      });
      final query = api.reads.last;
      expect(query['categoryRootIds'], ['material']);
      expect(query['search.series'], '5m');
      expect(query['search.name'], '开关');
      expect(query['excludeDisabled'], isTrue);
      expect(query['excludeStub'], isTrue);
      expect(api.locations.last['search.series'], '5m');
      expect(api.locations.last['search.name'], '开关');
      await selectFilterSegment(tester, '全部可选货品');
      await tester.pumpAndSettle();
      expect(table().items.map((item) => item.id).toSet(), {
        'black',
        'white',
        'outside',
      });
      expect(api.reads.last.containsKey('categoryRootIds'), isFalse);
      expect(api.reads.last['search.series'], '5m');
      expect(api.reads.last['search.name'], '开关');
      await selectFilterSegment(tester, '当前组件范围');
      await tester.pumpAndSettle();
      expect(table().items.map((item) => item.id).toSet(), {'black', 'white'});
      expect(api.reads.last['categoryRootIds'], ['material']);
      await tester.tap(find.byKey(const ValueKey('goods-picker-item-black')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('goods-picker-item-white')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
      await tester.pumpAndSettle();
      expect(selected.map((item) => item.id).toSet(), {'black', 'white'});
      expect(selected.map((item) => item.unitId).toSet(), {'unit-piece'});
    },
  );

  testWidgets(
    'approximate component suggestions use the same restricted roots and eligibility',
    (tester) async {
      final api = _ColumnApi();
      final results = <GoodsListItem>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            productCategoryRepositoryProvider.overrideWithValue(_Categories()),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async => results.addAll(
                  await loadUtenGoodsPickerSuggestions(ref, '开关'),
                ),
                child: const Text('候选'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('候选'));
      await tester.pumpAndSettle();
      expect(results.every((goods) => goods.categoryId == 'material'), isTrue);
      expect(results.map((goods) => goods.id), isNot(contains('outside')));
      expect(api.reads.single['categoryRootIds'], ['material']);
      expect(api.reads.single['excludeDisabled'], isTrue);
      expect(api.reads.single['excludeStub'], isTrue);
      expect(api.reads.single['size'], 8);
    },
  );
}

class _Categories implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'material',
      code: 'RAW',
      name: '原材料',
      level: 0,
      legacyId: 2113,
      children: const [],
    ),
    ProductCategoryNode(
      id: 'finished',
      code: 'FIN',
      name: '成品',
      level: 0,
      children: const [],
    ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ColumnApi extends ApiClient {
  _ColumnApi() : super(Dio());
  final reads = <Map<String, dynamic>>[];
  final locations = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _rows(Map<String, dynamic> query) =>
      [
        _row('black', '5M', '开关', '黑色'),
        _row('white', '5M', '开关', '白色'),
        _row('other-series', '7M', '开关', '黑色'),
        _row('socket', '5M', '插座', '黑色'),
        _row('outside', '5M', '开关', '黑色', category: 'finished'),
      ].where((row) {
        final roots = query['categoryRootIds'] as List?;
        if (roots != null && !roots.contains(row['categoryId'])) return false;
        if (query['categoryId'] != null &&
            query['categoryId'] != row['categoryId']) {
          return false;
        }
        if (query['keyword'] != null &&
            !row['goodsSearch'].toString().contains(
              query['keyword'].toString(),
            )) {
          return false;
        }
        for (final field in ['series', 'name']) {
          final search = query['search.$field'];
          if (search != null &&
              !row[field].toString().toLowerCase().contains(
                search.toString().toLowerCase(),
              )) {
            return false;
          }
        }
        return true;
      }).toList();
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add({...?query});
    final rows = _rows(query ?? {});
    return {
      'items': rows,
      'page': 1,
      'size': query?['size'] ?? 20,
      'total': rows.length,
      'totalPages': 1,
    };
  }

  @override
  Future<List<String>> getStringList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    locations.add({...?query});
    return _rows(
      query ?? {},
    ).map((row) => row['categoryId'] as String).toSet().toList();
  }

  static Map<String, dynamic> _row(
    String id,
    String series,
    String name,
    String color, {
    String category = 'material',
  }) => {
    'id': id,
    'code': 'G-$id',
    'series': series,
    'name': name,
    'goodsSearch': '$series$name',
    'categoryId': category,
    'colorName': color,
    'colorId': color == '白色' ? 'color-white' : 'color-black',
    'unitName': '个',
    'unitId': 'unit-piece',
    'status': '使用',
    'spec': '250V',
  };
}
