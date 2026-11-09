import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;
import 'package:uten_imp/shared/paging/complete_summary_stream.dart'
    show kProgressiveSummaryStreamSize;
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../../support/complete_read_plan_batches.dart';
import '../../../support/pump_until.dart';
import '../../../support/uten_test_actions.dart';

typedef _Batch = ({int page, int size});

typedef _Call = ({
  String category,
  String kind,
  int attempt,
  int page,
  int size,
  String? revision,
  bool Function()? current,
});

_Batch _batchOf(_Call call) => (page: call.page, size: call.size);

class _GoodsApi extends ApiClient {
  _GoodsApi({this.normalCount = 10001})
    : super(Dio(BaseOptions(baseUrl: 'https://goods.fixture/api')));
  final int normalCount;
  static const disabledCount = 2414;
  final calls = <_Call>[];
  final summaryRequests = <String, int>{};
  final attempts = <String, int>{};
  final active = <String, int>{}, peak = <String, int>{};
  final gates = <(String, int, _Batch), Completer<void>>{};
  final hold = <(String, int, _Batch)>{};
  int generation = 0, businessWrites = 0;
  // The first disabled read fails on its third internal batch (a tail).
  bool failDisabledThird = false;
  static const exactQty = '90071992547409.123456789012345678901234';
  @override
  Future<T> postSummaryStream<T>(
    String path, {
    required Object body,
    required Future<T> Function(Stream<Map<String, dynamic>>) consume,
  }) {
    final input = Map<String, dynamic>.from(body as Map);
    final filter = input['filter'] as Map;
    final category = filter['categoryId'] as String? ?? 'goods-root';
    final kind = filter['disabledOnly'] == true
        ? 'disabled'
        : filter['stubOnly'] == true
        ? 'stub'
        : 'normal';
    final key = '$category/$kind';
    summaryRequests[key] = (summaryRequests[key] ?? 0) + 1;
    // The request size selects the server's frame plan exactly as
    // MasterSummaryReadSupport does: kProgressiveSummaryStreamSize serves the
    // progressive ladder, 100 the original fixed frames, nothing else.
    final requested = input['size'];
    if (input['page'] != 1 ||
        (requested != 100 && requested != kProgressiveSummaryStreamSize)) {
      throw StateError('Expected one complete summary from its first batch');
    }
    final plan = requested == kProgressiveSummaryStreamSize
        ? CompleteReadBatchPlan.progressive
        : const CompleteReadBatchPlan.fixed(100);
    Stream<Map<String, dynamic>> frames() async* {
      Map<String, dynamic>? first;
      var offset = 0;
      do {
        final size = plan.sizeAt(offset);
        final value = await post(
          path,
          body: {...input, 'page': offset ~/ size + 1, 'size': size},
          query: first == null
              ? null
              : {'readSnapshotRevision': first['readSnapshotRevision']},
        );
        first ??= value;
        yield {'type': 'page', 'value': value};
        offset += size;
      } while (offset < (first['total'] as int));
      yield {
        'type': 'complete',
        for (final key in [
          'total',
          'readScopeVersion',
          'readSnapshotRevision',
          'readDataVersion',
        ])
          key: first[key],
      };
    }

    return consume(frames());
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.endsWith('/summaries')
      ? <String, dynamic>{
          'items': <Map<String, dynamic>>[],
          'page': query?['page'] ?? 1,
          'size': query?['size'] ?? 1000,
          'total': 0,
          'totalPages': 0,
          'readScopeVersion': 'a' * 64,
          'readSnapshotRevision': 'b' * 64,
          'readDataVersion': 'c' * 64,
        }
      : <String, dynamic>{};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    if (!path.contains('/preferences/')) businessWrites++;
    return {};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    if (path != '/master/goods/summaries') {
      if (!path.contains('/preferences/')) businessWrites++;
      return {};
    }
    final input = body! as Map, filter = input['filter'] as Map;
    final category = filter['categoryId'] as String? ?? 'goods-root';
    final kind = filter['disabledOnly'] == true
        ? 'disabled'
        : filter['stubOnly'] == true
        ? 'stub'
        : 'normal';
    final page = input['page'] as int, size = input['size'] as int;
    final key = '$category/$kind';
    if (page == 1) attempts[key] = (attempts[key] ?? 0) + 1;
    final attempt = attempts[key]!, sourceGeneration = generation;
    calls.add((
      category: category,
      kind: kind,
      attempt: attempt,
      page: page,
      size: size,
      revision: query?['readSnapshotRevision'] as String?,
      current: PagedReadIntent.currentRead,
    ));
    active[key] = (active[key] ?? 0) + 1;
    if (active[key]! > (peak[key] ?? 0)) peak[key] = active[key]!;
    final batch = (page: page, size: size);
    final gateKey = (kind, attempt, batch);
    try {
      if (hold.contains(gateKey)) {
        await gates.putIfAbsent(gateKey, Completer<void>.new).future;
      }
      await Future<void>.delayed(Duration.zero);
      if (kind == 'disabled' &&
          attempt == 1 &&
          batch == completeReadPlanBatches(disabledCount)[2] &&
          failDisabledThird) {
        throw ApiException('NETWORK', '禁用货品尾批未完整读取', httpStatus: 503);
      }
      final total = category == 'other-root' || sourceGeneration > 0
          ? (kind == 'normal' ? 1 : 0)
          : kind == 'disabled'
          ? disabledCount
          : kind == 'stub'
          ? 0
          : normalCount;
      final revision =
          (kind == 'disabled'
              ? 'd'
              : kind == 'stub'
              ? 'e'
              : 'b') *
          64;
      return <String, dynamic>{
        'page': page,
        'size': size,
        'total': total,
        'totalPages': (total + size - 1) ~/ size,
        'scope': 'all',
        'readScopeVersion': (sourceGeneration == 0 ? 'a' : 'f') * 64,
        'readSnapshotRevision': revision,
        'readDataVersion': 'c' * 64,
        'items': <Map<String, dynamic>>[
          for (var i = (page - 1) * size; i < page * size && i < total; i++)
            <String, dynamic>{
              'id': 'g$sourceGeneration-$category-$kind-$i',
              'code': 'HP-${i.toString().padLeft(6, '0')}',
              'name': '${sourceGeneration == 0 ? '原文' : '新域'}货品-$kind-$i',
              'status': kind == 'disabled' ? '禁用' : '使用',
              'categoryId': category,
              'stockQty': 1,
              'stockQtyDisplayText': exactQty,
              'unitName': '件',
              'priceDisplayText': '1234567890.1234567890123456789',
              'currencyCode': 'USD',
              'version': 7,
              'writable': false,
            },
        ],
      };
    } finally {
      active[key] = active[key]! - 1;
    }
  }

  void release(String kind, int attempt, _Batch batch) {
    final gate = gates[(kind, attempt, batch)];
    if (gate != null && !gate.isCompleted) gate.complete();
  }
}

class _Categories implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    for (final (id, name) in [('goods-root', '货品总类'), ('other-root', '其他分类')])
      ProductCategoryNode(
        id: id,
        code: id == 'goods-root' ? 'GOODS' : 'OTHER',
        name: name,
        level: 0,
        children: const [],
      ),
  ];
  @override
  Future<ProductCategoryDetail> detail(String id) async =>
      ProductCategoryDetail(
        id: id,
        code: id == 'goods-root' ? 'GOODS' : 'OTHER',
        name: id == 'goods-root' ? '货品总类' : '其他分类',
        level: 0,
        path: '/$id/',
        childCount: 0,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder get _table => find.byType(MasterDataTableView<GoodsListItem>);
MasterDataTableView<GoodsListItem> _view(WidgetTester tester) =>
    tester.widget(_table);
Future<ProviderContainer> _mount(WidgetTester tester, _GoodsApi api) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await setUtenTestSurfaceSize(tester, const Size(1600, 1000));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://goods.fixture/api'),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.materialCategoryView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'goods-reader'),
        ),
        productCategoryRepositoryProvider.overrideWithValue(_Categories()),
        goodsRepositoryProvider.overrideWithValue(DioGoodsRepository(api)),
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
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ProductCategoryPage)),
  );
  await tester.tap(find.text('货品总类'));
  await tester.pump();
  return container;
}

void registerGoodsCompleteFirstOpenTests() {
  testWidgets(
    'Goods real page completes normal10001 and disabled2414 with exact tail, local scroll and no writes',
    (tester) async {
      final api = _GoodsApi();
      await _mount(tester, api);
      await pumpUntil(
        tester,
        () =>
            _table.evaluate().length == 1 &&
            _view(tester).items.length == 10001 &&
            (_view(tester).leadingGroups?.any(
                  (g) => g.id == 'disabled' && g.items.length == 2414,
                ) ??
                false),
        reason:
            'Normal and disabled complete snapshots did not reach the real page',
        timeout: const Duration(seconds: 10),
      );
      await tester.pumpAndSettle();
      final table = _view(tester),
          disabled = _view(
            tester,
          ).leadingGroups!.singleWhere((g) => g.id == 'disabled');
      expect(table.items.last.id, 'g0-goods-root-normal-10000');
      expect(table.items.last.name, '原文货品-normal-10000');
      expect(table.items.last.stockQtyDisplayText, _GoodsApi.exactQty);
      expect(table.items.last.version, 7);
      expect(table.items.last.writable, isFalse);
      expect(disabled.total, 2414);
      expect(disabled.items.last.id, 'g0-goods-root-disabled-2413');
      expect(disabled.items.last.stockQtyDisplayText, _GoodsApi.exactQty);
      // One HTTP stream per kind; the server reads it internally in the
      // shared plan's bounded batches, exactly once and one at a time.
      expect(
        api.calls.where((c) => c.kind == 'normal').map(_batchOf),
        completeReadPlanBatches(10001),
      );
      expect(
        api.calls.where((c) => c.kind == 'disabled').map(_batchOf),
        completeReadPlanBatches(_GoodsApi.disabledCount),
      );
      expect(api.peak.values.every((v) => v == 1), isTrue);
      expect(api.summaryRequests['goods-root/normal'], 1);
      expect(api.summaryRequests['goods-root/disabled'], 1);
      for (final kind in ['normal', 'disabled']) {
        final calls = api.calls.where((c) => c.kind == kind).toList();
        expect(calls.first.revision, isNull);
        expect(
          calls
              .skip(1)
              .every((c) => c.revision == (kind == 'normal' ? 'b' : 'd') * 64),
          isTrue,
        );
      }
      final reads = api.calls.length;
      final controller = utenTestTableBodyController(tester, _table);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(reads));
      expect(api.businessWrites, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Goods disabled tail failure is local error with real retry and no prefix while normal remains usable',
    (tester) async {
      final api = _GoodsApi(normalCount: 201)..failDisabledThird = true;
      // The retry's last internal batch (the disabled tail) is held.
      final tail = completeReadPlanBatches(_GoodsApi.disabledCount).last;
      api.hold.add(('disabled', 2, tail));
      await _mount(tester, api);
      await pumpUntil(
        tester,
        () =>
            _table.evaluate().length == 1 &&
            _view(tester).items.length == 201 &&
            (_view(tester).leadingGroups?.any((g) => g.error != null) ?? false),
        reason: 'Group failure was hidden or blocked the normal table',
      );
      expect(
        _view(tester).leadingGroups!.any((g) => g.id == 'disabled'),
        isFalse,
      );
      final retry = find.byKey(
        const ValueKey(
          'master-table-group-complete-group-read-error-read-retry',
        ),
      );
      expect(retry, findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await pumpUntil(
        tester,
        () => api.calls.any(
          (c) => c.kind == 'disabled' && c.attempt == 2 && _batchOf(c) == tail,
        ),
        reason: 'Explicit retry did not reach full disabled tail',
      );
      await pumpUntil(
        tester,
        () => find.byType(UtenBusyOverlayCard).evaluate().isNotEmpty,
        reason: 'Group retry did not own its real wait overlay',
      );
      expect(_view(tester).items, hasLength(201));
      expect(
        _view(tester).leadingGroups!.any((g) => g.id == 'disabled'),
        isFalse,
      );
      api.release('disabled', 2, tail);
      await pumpUntil(
        tester,
        () => _view(tester).leadingGroups!.any(
          (g) => g.id == 'disabled' && g.items.length == 2414,
        ),
        reason: 'Retry did not publish a complete disabled group',
      );
      api.release(
        'disabled',
        1,
        completeReadPlanBatches(_GoodsApi.disabledCount)[1],
      );
      await tester.pumpAndSettle();
      expect(
        _view(
          tester,
        ).leadingGroups!.singleWhere((g) => g.id == 'disabled').items.last.id,
        'g0-goods-root-disabled-2413',
      );
      expect(
        api.calls.where((c) => c.kind == 'disabled' && c.attempt == 1).length,
        lessThanOrEqualTo(5),
      );
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(api.businessWrites, 0);
      expect(tester.takeException(), isNull);
    },
  );
  for (final transition in ['category', 'scope']) {
    testWidgets(
      'Goods group held tail retires on $transition and cannot publish or keep reading',
      (tester) async {
        final api = _GoodsApi(normalCount: 201);
        // The disabled group's second internal batch (its tail) is held.
        final held = completeReadPlanBatches(_GoodsApi.disabledCount)[1];
        api.hold.add(('disabled', 1, held));
        final container = await _mount(tester, api);
        await pumpUntil(
          tester,
          () =>
              api.calls
                  .where((c) => c.kind == 'disabled' && c.attempt == 1)
                  .length ==
              2,
          reason: 'Group did not start its bounded tail',
        );
        final old = api.calls
            .where((c) => c.kind == 'disabled' && c.attempt == 1)
            .toList();
        if (transition == 'category') {
          await tester.tap(find.text('其他分类'));
        } else {
          api.generation = 1;
          container.read(readScopeRevisionProvider.notifier).state++;
        }
        await pumpUntil(
          tester,
          () =>
              _table.evaluate().length == 1 && _view(tester).items.length == 1,
          reason: 'New owner did not replace the old table',
        );
        expect(old.every((c) => c.current!() == false), isTrue);
        api.release('disabled', 1, held);
        await tester.pumpAndSettle();
        expect(_view(tester).items, hasLength(1));
        expect(_view(tester).leadingGroups, isEmpty);
        expect(
          api.calls.where(
            (c) =>
                c.kind == 'disabled' &&
                c.category == 'goods-root' &&
                c.attempt == 1,
          ),
          hasLength(2),
        );
        expect(api.businessWrites, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
