import '../../../support/pump_until.dart';
import '../../../support/master_summary_stream_fixture.dart';
import 'package:uten_imp/features/basic_data/repositories/business_reference_repository.dart';
import 'dart:async';
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
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import '../../../support/filter_segment_tap.dart';

void main() {
  testWidgets('suggestion responses cannot revive after read owner ABA', (
    tester,
  ) async {
    final api = _HeldColumnApi();
    final epoch = _SuggestionEpoch();
    Object? rejected;
    final results = <GoodsListItem>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          exportContextEpochProvider.overrideWith(() => epoch),
          businessGoodsCategoryRepositoryProvider.overrideWithValue(
            _Categories(),
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async {
                try {
                  results.addAll(
                    await loadUtenGoodsPickerSuggestions(ref, '开关'),
                  );
                } catch (error) {
                  rejected = error;
                }
              },
              child: const Text('候选'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('候选'));
    await pumpAndSettleWithIo(tester);
    expect(api.started, isTrue);
    epoch.advance();
    await tester.pump();
    epoch.advance();
    api.pending.complete();
    await pumpAndSettleWithIo(tester);
    expect(results, isEmpty);
    expect(rejected, isStateError);
    expect(tester.takeException(), isNull);
  });

  test(
    'large column-search scopes use one full-root POST page and small scopes retain GET',
    () async {
      final requests = <RequestOptions>[];
      final data = _ColumnApi();
      final dio = Dio(BaseOptions(baseUrl: 'https://goods.test/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            final query = <String, dynamic>{...request.queryParameters};
            if (request.method == 'POST') {
              final body = Map<String, dynamic>.from(request.data as Map);
              final filter = Map<String, dynamic>.from(body['filter'] as Map);
              final columns = Map<String, dynamic>.from(
                filter.remove('columnSearch') as Map,
              );
              query.addAll(filter);
              for (final entry in columns.entries) {
                query['search.${entry.key}'] = entry.value;
              }
              for (final key in ['page', 'size', 'sort', 'order']) {
                if (body.containsKey(key)) query[key] = body[key];
              }
            }
            final rows = data._rows(query);
            if (request.path.endsWith('/summaries')) {
              handler.resolve(
                masterSummaryStreamTestInterceptResponse(rows, request),
              );
              return;
            }
            final page = query['page'] as int? ?? 1;
            final size = query['size'] as int? ?? 100;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: request.path.endsWith('/search-category-ids')
                    ? rows
                          .map((row) => row['categoryId'] as String)
                          .toSet()
                          .toList()
                    : {
                        'items': rows
                            .skip((page - 1) * size)
                            .take(size)
                            .toList(),
                        'page': page,
                        'size': size,
                        'total': rows.length,
                        'totalPages': (rows.length / size).ceil(),
                      },
              ),
            );
          },
        ),
      );
      final repository = DioGoodsRepository(ApiClient(dio));
      final roots = {
        'material',
        for (var index = 0; index < 32; index++) 'root-$index',
      };
      const filters = {'search.series': '5m', 'search.name': '开关'};
      final result = await repository.searchColumns(
        '开关',
        filters: filters,
        categoryRootIds: roots,
        page: 2,
        size: 1,
        excludeDisabled: true,
        excludeStub: true,
        sort: 'code',
        order: 'asc',
      );
      final locations = await repository.searchColumnCategoryIds(
        '开关',
        filters: filters,
        categoryRootIds: roots,
        excludeDisabled: true,
        excludeStub: true,
      );
      expect(requests, hasLength(2));
      expect(requests.map((request) => request.method), everyElement('POST'));
      expect(requests.map((request) => request.path), [
        '/master/goods/search',
        '/master/goods/search-category-ids',
      ]);
      for (final request in requests) {
        expect(request.queryParameters, isEmpty);
        final filter = Map<String, dynamic>.from(
          (request.data as Map)['filter'] as Map,
        );
        expect(filter['columnSearch'], {'series': '5m', 'name': '开关'});
        expect(filter['categoryRootIds'], roots.toList()..sort());
        expect(filter['excludeDisabled'], true);
        expect(filter['excludeStub'], true);
      }
      expect((requests.first.data as Map)['page'], 2);
      expect((requests.first.data as Map)['size'], 1);
      expect((requests.first.data as Map)['sort'], 'code');
      expect((requests.first.data as Map)['order'], 'asc');
      expect(result.items.single.id, 'white');
      expect(result.page, 2);
      expect(result.total, 2);
      expect(result.totalPages, 2);
      expect(locations, {'material'});
      final small = await repository.searchColumns(
        '开关',
        filters: filters,
        categoryRootIds: {'material'},
        size: 1,
        sort: 'code',
        order: 'asc',
      );
      await repository.searchColumnCategoryIds(
        '开关',
        filters: filters,
        categoryRootIds: {'material'},
      );
      expect(requests, hasLength(4));
      expect(
        requests.skip(2).map((request) => request.method),
        everyElement('GET'),
      );
      expect(requests[2].path, '/master/goods');
      expect(requests[2].queryParameters['categoryRootIds'], ['material']);
      expect(requests[2].queryParameters['search.series'], '5m');
      expect(requests[2].queryParameters['search.name'], '开关');
      expect(small.items.single.id, 'black');
      dio.close(force: true);
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
            businessGoodsCategoryRepositoryProvider.overrideWithValue(
              _Categories(),
            ),
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
      await pumpAndSettleWithIo(tester);
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
        'stockQty',
      ]);
      final stockColumn = table().columns.singleWhere(
        (column) => column.key == 'stockQty',
      );
      expect(stockColumn.label, '即时库存');
      expect(stockColumn.columnSearchEnabled, isFalse);
      expect(stockColumn.value(table().items.first), '9007199254740993.123456');
      expect(
        stockColumn.value(const GoodsListItem(id: 'no-stock-authority')),
        isNull,
      );
      expect(table().serverColumnSearch, isTrue);
      table().onFilterChanged('search.series', '5m');
      await pumpAndSettleWithIo(tester);
      table().onFilterChanged('search.name', '开关');
      await pumpAndSettleWithIo(tester);
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
      await pumpAndSettleWithIo(tester);
      expect(table().items.map((item) => item.id).toSet(), {
        'black',
        'white',
        'outside',
      });
      expect(api.reads.last.containsKey('categoryRootIds'), isFalse);
      expect(api.reads.last['search.series'], '5m');
      expect(api.reads.last['search.name'], '开关');
      await selectFilterSegment(tester, '当前组件范围');
      await pumpAndSettleWithIo(tester);
      expect(table().items.map((item) => item.id).toSet(), {'black', 'white'});
      expect(api.reads.last['categoryRootIds'], ['material']);
      await tester.tapAt(
        tester.getTopLeft(
              find.byKey(const ValueKey('goods-picker-item-black')),
            ) +
            const Offset(16, 20),
      );
      await tester.pump();
      await tester.tapAt(
        tester.getTopLeft(
              find.byKey(const ValueKey('goods-picker-item-white')),
            ) +
            const Offset(16, 20),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
      await pumpAndSettleWithIo(tester);
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
            businessGoodsCategoryRepositoryProvider.overrideWithValue(
              _Categories(),
            ),
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
      await pumpAndSettleWithIo(tester);
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

class _ColumnApi extends MasterSummaryStreamTestApi {
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
  FutureOr<List<Map<String, dynamic>>> masterSummaryRows(
    RequestOptions request,
  ) {
    final path = request.path;
    if (path != '/business-references/goods/summaries' &&
        path != '/master/goods/summaries') {
      throw StateError('Unexpected business command in goods-column fixture');
    }
    final parameters = masterSummaryTestParameters(request);
    reads.add(parameters);
    return _rows(parameters);
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
    'stockQtyDisplayText': '9007199254740993.123456',
    'spec': '250V',
  };
}

class _HeldColumnApi extends _ColumnApi {
  final pending = Completer<void>();
  bool started = false;
  @override
  Future<List<Map<String, dynamic>>> masterSummaryRows(
    RequestOptions request,
  ) async {
    started = true;
    await pending.future;
    return super.masterSummaryRows(request);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    started = true;
    await pending.future;
    return super.get(path, query: query);
  }
}

class _SuggestionEpoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void advance() => state++;
}
