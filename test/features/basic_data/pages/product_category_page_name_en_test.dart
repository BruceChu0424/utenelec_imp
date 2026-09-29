// ADR-134 goods list: the 英文名称 column sits right after 货品名称 and the
// search hint tells users the keyword also matches English names.
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
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('英文名称 column follows 货品名称 and shows the learned value', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final goods = _FakeGoodsRepository();
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
            _FakeCategoryRepository(),
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

    await tester.tap(find.text('成品类(C-FIN)'));
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
}

class _FakeCategoryRepository implements ProductCategoryRepository {
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

class _FakeGoodsRepository implements GoodsRepository {
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
    final items = disabledOnly || stubOnly
        ? const <GoodsListItem>[]
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
  Future<GoodsFacets> facets(String categoryId) async =>
      const GoodsFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
