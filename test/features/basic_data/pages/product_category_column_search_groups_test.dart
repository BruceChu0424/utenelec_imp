import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
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
  testWidgets(
    'column terms and sorting also constrain disabled and unknown goods groups',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _GoodsWithGroups();
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
              _OrphanCategory(),
            ),
            goodsRepositoryProvider.overrideWithValue(repository),
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
      await tester.tap(find.text('未分类'));
      await tester.pumpAndSettle();
      MasterDataTableView<GoodsListItem> table() =>
          tester.widget(find.byType(MasterDataTableView<GoodsListItem>));
      expect(table().leadingGroups!.map((group) => group.total), [2, 2]);
      table().onFilterChanged('search.name', '开关');
      await tester.pumpAndSettle();
      table().onSortChange!('code', false);
      await tester.pumpAndSettle();

      final filtered = table();
      expect(filtered.items.map((item) => item.id), ['normal-switch']);
      expect(filtered.items.single.stockQty, 33);
      final disabled = filtered.leadingGroups!.singleWhere(
        (group) => group.id == 'disabled',
      );
      final unknown = filtered.leadingGroups!.singleWhere(
        (group) => group.id == 'stub',
      );
      expect(disabled.total, 1);
      expect(disabled.items.map((item) => item.id), ['disabled-switch']);
      expect(disabled.items.single.stockQty, 11);
      expect(unknown.total, 1);
      expect(unknown.items.map((item) => item.id), ['stub-switch']);
      expect(unknown.items.single.stockQty, 22);
      final currentCalls = repository.calls.where(
        (call) => call.filters['search.name'] == '开关' && call.order == 'desc',
      );
      final disabledCall = currentCalls.lastWhere((call) => call.disabled);
      final unknownCall = currentCalls.lastWhere((call) => call.stub);
      expect(disabledCall.categoryId, 'orphan');
      expect(unknownCall.categoryId, isNull);
      expect(disabledCall.sort, 'code');
      expect(unknownCall.sort, 'code');
      expect(disabledCall.filters, {'search.name': '开关'});
      expect(unknownCall.filters, {'search.name': '开关'});
      expect(tester.takeException(), isNull);
    },
  );
}

class _OrphanCategory implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'orphan',
      code: 'FL-ORPHAN',
      name: '未分类',
      level: 0,
      children: const [],
      systemManaged: true,
    ),
  ];
  @override
  Future<ProductCategoryDetail> detail(String id) async =>
      const ProductCategoryDetail(
        id: 'orphan',
        code: 'FL-ORPHAN',
        name: '未分类',
        level: 0,
        path: '未分类',
        childCount: 0,
        systemManaged: true,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Read = ({
  String? categoryId,
  Map<String, String?> filters,
  String? sort,
  String? order,
  bool disabled,
  bool stub,
});

class _GoodsWithGroups implements GoodsRepository {
  final calls = <_Read>[];
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
    calls.add((
      categoryId: categoryId,
      filters: {...filters},
      sort: sort,
      order: order,
      disabled: disabledOnly,
      stub: stubOnly,
    ));
    final kind = disabledOnly
        ? 'disabled'
        : stubOnly
        ? 'stub'
        : 'normal';
    final qty = disabledOnly
        ? 11.0
        : stubOnly
        ? 22.0
        : 33.0;
    final rows =
        [
              GoodsListItem(
                id: '$kind-switch',
                code: 'A-$kind',
                name: '单联开关',
                stockQty: qty,
                status: disabledOnly ? '禁用' : '使用',
              ),
              GoodsListItem(
                id: '$kind-socket',
                code: 'B-$kind',
                name: '三极插座',
                stockQty: 99,
                status: disabledOnly ? '禁用' : '使用',
              ),
            ]
            .where(
              (row) =>
                  filters['search.name'] == null ||
                  row.name!.contains(filters['search.name']!),
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
  }) async => const GoodsFacets(fields: {}, nullCounts: {});
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
