import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/goods_node.dart';
import '../models/product_category_node.dart';
import '../repositories/goods_repository.dart';
import '../repositories/product_category_repository.dart';
import 'uten_goods_picker.dart';

final bomComponentPickerProvider =
    Provider<Future<List<GoodsListItem>> Function(BuildContext, WidgetRef)>(
      (ref) =>
          (context, ref) => showUtenGoodsPickerMulti(
            context,
            ref,
            allowScopeExpansion: true,
            readBoundary: ref.read(sensitiveReadBoundaryProvider),
          ),
    );

final bomComponentSuggestionsProvider =
    Provider<Future<List<GoodsListItem>> Function(WidgetRef, String)>(
      (ref) =>
          (widgetRef, query) =>
              loadUtenGoodsPickerSuggestions(widgetRef, query),
    );

/// Removal may legitimately identify an inactive component already present in a recipe.
final bomComponentRemovalPickerProvider =
    Provider<Future<List<GoodsListItem>> Function(BuildContext, WidgetRef)>(
      (ref) =>
          (context, ref) => showUtenGoodsPickerMulti(
            context,
            ref,
            scope: UtenGoodsPickerScope.all,
            dataSource: _RemovalSource(
              ref.read(goodsRepositoryProvider),
              ref.read(productCategoryRepositoryProvider),
            ),
            readBoundary: ref.read(sensitiveReadBoundaryProvider),
          ),
    );

class _RemovalSource extends UtenGoodsPickerDataSource {
  _RemovalSource(this.goods, this.categories);
  final GoodsRepository goods;
  final ProductCategoryRepository categories;
  @override
  bool get supportsRelatedSearch => true;
  @override
  Future<List<ProductCategoryNode>> tree() => categories.tree();
  @override
  Future<PagedResult<GoodsListItem>> list(
    String categoryId, {
    required int page,
    String? keyword,
  }) => goods.list(
    categoryId,
    page: page,
    size: 100,
    keyword: keyword,
    excludeStub: true,
    sort: 'code',
    order: 'asc',
  );
  @override
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    required int page,
  }) => searchWithOptions(keyword, page: page);
  @override
  Future<PagedResult<GoodsListItem>> searchWithOptions(
    String keyword, {
    required int page,
    String? categoryId,
    bool includeRelated = false,
  }) => goods.search(
    keyword,
    page: page,
    size: 100,
    categoryId: categoryId,
    includeRelated: includeRelated,
    excludeStub: true,
    sort: 'code',
    order: 'asc',
  );
  @override
  Future<Set<String>> searchCategoryIds(String keyword) =>
      searchCategoryIdsWithOptions(keyword);
  @override
  Future<Set<String>> searchCategoryIdsWithOptions(
    String keyword, {
    String? categoryId,
    bool includeRelated = false,
  }) => goods.searchCategoryIds(
    keyword,
    categoryRootIds: const {},
    categoryId: categoryId,
    includeRelated: includeRelated,
    excludeStub: true,
  );
}
