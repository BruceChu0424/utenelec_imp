// 独立称重计数页契约 (ADR-135 §6.4):
//  1. 没选货品时只有选货品入口; 没有称样权限时明确提示「抽样不会保存」;
//  2. 选货品 (统一货品选择器) 后面板按该货品取单重参数, 称重即折算件数;
//  3. 有称样权限时「保存抽样」= POST samples, 页面显示重算后的单重并清空面板开始下一次称重;
//  4. 本页从不调用任何库存过账接口。
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_weigh_count_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _MemoryWeightUnitsPrefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();

  @override
  void persist() {}
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  final posts = <(String, Object?)>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path, body));
    if (path == '/stock/weight/params') {
      return {
        'items': [
          {
            'goodsId': 'g-w1',
            'basis': 'LEARNED',
            'evidence': 'REFERENCE',
            'logMean': math.log(0.00231),
            'lotPrior': 3.869930380683166e-05,
            'df': 15,
            'tier': 'YELLOW',
            'nInliers': 12,
            'tolerancePct': 3,
            'baseUnitDimension': 'COUNT',
          },
        ],
      };
    }
    if (path.endsWith('/samples')) {
      return {
        'goodsId': 'g-w1',
        'resolved': {
          'basis': 'LEARNED',
          'evidence': 'REFERENCE',
          'unitWeightKg': 0.00231,
          'tier': 'GREEN',
          'nInliers': 13,
        },
      };
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {};

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async =>
      const {};
}

class _FakeCategoryRepository extends Fake
    implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'hw',
      code: 'HW',
      name: '五金',
      level: 0,
      children: const [],
    ),
  ];

  @override
  Future<List<ProductCategoryNode>> treeWithGoodsCounts() => tree();
}

class _FakeGoodsRepository extends Fake implements GoodsRepository {
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
  }) async => PagedResult(
    items: const [_washer],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );
}

const _washer = GoodsListItem(
  id: 'g-w1',
  code: 'SC-009',
  name: '垫片M5',
  unitName: '个',
  categoryId: 'hw',
);

late SharedPreferences _preferences;

Future<_FakeApi> _open(WidgetTester tester, Set<String> permissions) async {
  tester.view.physicalSize = const Size(1400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _FakeApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_preferences),
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        warehouseWeightUnitsPrefsProvider.overrideWith(
          _MemoryWeightUnitsPrefs.new,
        ),
        productCategoryRepositoryProvider.overrideWithValue(
          _FakeCategoryRepository(),
        ),
        goodsRepositoryProvider.overrideWithValue(_FakeGoodsRepository()),
      ],
      child: const MaterialApp(home: WarehouseWeighCountPage()),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Future<void> _pickWasher(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('weigh-count-pick-goods')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('五金(HW)'));
  await tester.pumpAndSettle();
  // 2026-09-29 货品选择器选项=名称主行，点名称行。
  await tester.tap(find.text('垫片M5'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  testWidgets('without goods only the picker entry shows; no-sample notice', (
    tester,
  ) async {
    await _open(tester, const {Perm.stockView});
    expect(find.text('先选要称的货品'), findsOneWidget);
    expect(find.text('选择货品'), findsOneWidget);
    expect(find.byKey(const Key('weigh-count-gross-0')), findsNothing);
    expect(
      find.byKey(const Key('weigh-count-no-sample-permission')),
      findsOneWidget,
    );
  });

  testWidgets('weighs a picked goods and saves a lot sample', (tester) async {
    final api = await _open(tester, const {
      Perm.stockView,
      Perm.warehouseInboundStockIn,
    });
    expect(
      find.byKey(const Key('weigh-count-no-sample-permission')),
      findsNothing,
    );

    await _pickWasher(tester);
    expect(find.text('垫片M5 SC-009'), findsOneWidget);
    expect(api.posts.first.$1, '/stock/weight/params');

    await _type(tester, 'weigh-count-gross-0', '11.55');
    expect(find.textContaining('约 5,000个'), findsOneWidget);
    // 没录抽样时「保存抽样」不可点 (独立页只算数, 不过账)。
    final save = find.byKey(const ValueKey('weigh-count-primary'));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(api.posts.where((p) => p.$1.endsWith('/samples')), isEmpty);

    await _type(tester, 'weigh-count-sample-qty', '20');
    await _type(tester, 'weigh-count-sample-weight', '46.2');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final samples = api.posts.where((p) => p.$1.endsWith('/samples')).toList();
    expect(samples, hasLength(1));
    expect(samples.single.$1, '/stock/weight/goods/g-w1/samples');
    final body = samples.single.$2! as Map<String, Object?>;
    expect(body['qty'], 20);
    expect(body['weight'], 46.2);
    expect(body['weightUnit'], 'G');
    // 只动了单重参数与称样两个接口, 没有任何库存过账请求。
    expect(api.posts.map((p) => p.$1).toSet(), {
      '/stock/weight/params',
      '/stock/weight/goods/g-w1/samples',
    });

    expect(find.byKey(const Key('weigh-count-latest')), findsOneWidget);
    expect(find.textContaining('当前单重 2.31 g/个'), findsWidgets);
    // 面板清空, 下一次称重从空白开始。
    final gross = tester.widget<TextField>(
      find.byKey(const ValueKey('weigh-count-gross-0')),
    );
    expect(gross.controller?.text, isEmpty);
  });
}
