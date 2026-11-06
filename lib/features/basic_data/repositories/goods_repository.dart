// 货品主档仓库：分类（子树）下分页列表（动态筛选）+ 字段 facets + 详情。
//
// 仿 DioProductCategoryRepository，端点走 ApiEndpoints.goods 系列；
// 分页结果复用 PagedResult（对应后端 PageResponse）。
// filters 中值 == kMasterFilterNullValue 的字段名收集进 nullFields（空值筛选）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/paged_read_intent.dart';
import '../../../shared/paging/versioned_summary_read.dart';
import '../models/goods_node.dart';
import '../models/master_facet.dart';

/// Stable table keys retain saved layouts while relation filters use UUID-aware API references.
String goodsFacetField(String field) => switch (field) {
  'colorLegacyId' => 'colorRef',
  'unitLegacyId' => 'unitRef',
  _ => field,
};

Map<String, dynamic> goodsFilterQueryParams(Map<String, String?> filters) =>
    masterFilterQueryParams({
      for (final entry in filters.entries)
        (entry.key.startsWith('search.')
                ? entry.key
                : goodsFacetField(entry.key)):
            entry.value,
    });

const _maxGoodsCategoryRootsInUrl = 32;
const _maxGoodsCategoryRoots = 4096;

List<String> goodsSearchCategoryRoots(Set<String> rawIds) {
  final normalized = <String>{};
  for (final rawId in rawIds) {
    final id = rawId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(
        rawIds,
        'categoryRootIds',
        'category root id must not be blank',
      );
    }
    normalized.add(id);
  }
  final ids = normalized.toList(growable: false)..sort();
  if (ids.length > _maxGoodsCategoryRoots) {
    throw ArgumentError.value(
      rawIds.length,
      'categoryRootIds',
      'too many roots',
    );
  }
  return ids;
}

/// The JSON read contract uses the same filter as the GET endpoint. Column
/// keyword predicates are a map, while exact UUID references remain scalar.
Map<String, dynamic> goodsSearchReadBody(Map<String, dynamic> query) {
  final filter = <String, dynamic>{};
  final columns = <String, String>{};
  for (final entry in query.entries) {
    if (const {'page', 'size', 'sort', 'order'}.contains(entry.key)) continue;
    if (entry.key.startsWith('search.')) {
      if (entry.value != null) {
        columns[entry.key.substring(7)] = entry.value.toString();
      }
    } else {
      filter[entry.key] = entry.value;
    }
  }
  if (columns.isNotEmpty) filter['columnSearch'] = columns;
  return {
    'filter': filter,
    for (final key in const ['page', 'size', 'sort', 'order'])
      if (query.containsKey(key)) key: query[key],
  };
}

abstract interface class GoodsRepository {
  /// 某分类（子树）下的货品分页。
  ///
  /// [keyword] 模糊匹配名称/编号/型号/规格/系列；[filters] 字段精确筛选，
  /// 值为 [kMasterFilterNullValue] 表示筛该字段为空。page 从 1 起。
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
  });

  /// 某分类（子树）下的字段 facet（各字段可选值 + 空值计数）。
  Future<GoodsFacets> facets(
    String categoryId, {
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  });

  /// 全局（或 [categoryRootIds] 限定的多根范围）字段 facet；滑窗搜索态与
  /// 列表口径共用，桶随当前查询上下文刷新。
  Future<GoodsFacets> globalFacets({
    String? categoryId,
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
    Set<String> categoryRootIds = const {},
  });

  /// 全局搜货品（组装信息「添加组件」选择器用；不限分类，按编号/名称/型号/规格/系列模糊）。
  ///
  /// [sort]/[order] 与 [list] 同一套服务端排序白名单（code/price）；
  /// 不传时保持服务端默认（编号升序及稳定 id）。
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    Set<String> categoryRootIds = const {},
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
    String? sort,
    String? order,
  });

  /// 返回受 [categoryRootIds] 约束的关键词命中货品所属分类 id（去重）。
  ///
  /// 选择器用它一次定位完整分类路径，避免为收集 categoryId 下载全部货品分页。
  Future<Set<String>> searchCategoryIds(
    String keyword, {
    required Set<String> categoryRootIds,
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
  });

  Future<GoodsDetail> detail(String id);

  /// 新建货品：后端 POST /master/goods 返回新建的 GoodsDetail（含 id+自动生成 code），
  /// 供新增弹窗 create→edit 同弹窗切换拿 id 用。
  Future<GoodsDetail> create(Map<String, dynamic> body);

  Future<void> update(String id, Map<String, dynamic> body);

  Future<void> delete(String id);
}

/// Optional complete-summary capability. Existing references and test
/// repositories keep their original list API; no failed new API falls back.
abstract interface class GoodsSummaryReadGateway {
  bool get supportsCompleteGoodsSummaries;
  Future<PagedResult<GoodsListItem>> completeList(
    String? categoryId, {
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool excludeDisabled = false,
    bool excludeStub = false,
    bool disabledOnly = false,
    bool stubOnly = false,
    bool includeRelated = false,
  });
}

/// Optional column-aware query contract; dedicated business pickers retain their own APIs.
abstract interface class GoodsColumnSearchGateway {
  Future<PagedResult<GoodsListItem>> searchColumns(
    String keyword, {
    required Map<String, String?> filters,
    int page = 1,
    int size = 20,
    Set<String> categoryRootIds = const {},
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
    String? sort,
    String? order,
  });
  Future<Set<String>> searchColumnCategoryIds(
    String keyword, {
    required Map<String, String?> filters,
    required Set<String> categoryRootIds,
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
  });
}

class DioGoodsRepository
    implements
        GoodsRepository,
        GoodsColumnSearchGateway,
        GoodsSummaryReadGateway {
  DioGoodsRepository(this.api, {this.queryBasePath = ApiEndpoints.goods});
  final ApiClient api;

  /// Query configuration only. Detail and all CRUD keep their master endpoints.
  final String queryBasePath;

  @override
  bool get supportsCompleteGoodsSummaries =>
      queryBasePath == ApiEndpoints.goods;

  @override
  Future<PagedResult<GoodsListItem>> completeList(
    String? categoryId, {
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
    if (!supportsCompleteGoodsSummaries) {
      throw StateError('This goods reference does not expose master summaries');
    }
    final parent = PagedReadIntent.currentRead;
    final owner = await api.captureRequestScope(
      isCurrent: () => parent?.call() ?? true,
    );
    final query = <String, dynamic>{
      'categoryId': ?categoryId,
      if (keyword?.trim().isNotEmpty == true) 'keyword': keyword!.trim(),
      if (sort?.isNotEmpty == true) 'sort': sort,
      if (order?.isNotEmpty == true) 'order': order,
      if (excludeDisabled) 'excludeDisabled': true,
      if (excludeStub) 'excludeStub': true,
      if (disabledOnly) 'disabledOnly': true,
      if (stubOnly) 'stubOnly': true,
      if (includeRelated && keyword?.trim().isNotEmpty == true)
        'includeRelated': true,
      ...goodsFilterQueryParams(filters),
    };
    return owner.run(() async {
      final snapshot = await readVersionedSummarySnapshot<GoodsListItem>(
        isCurrent: () => owner.isCurrent,
        maxConcurrentPages: 4,
        idOf: (row) => row.id,
        decode: GoodsListItem.fromJson,
        loadPage: (page, size, revision) => api.post(
          '${ApiEndpoints.goods}/summaries',
          body: goodsSearchReadBody({...query, 'page': page, 'size': size}),
          query: {'readSnapshotRevision': ?revision},
        ),
      );
      return snapshot.page;
    });
  }

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
    final query = <String, dynamic>{
      'categoryId': ?categoryId,
      'page': page,
      'size': size,
      if (keyword != null && keyword.trim().isNotEmpty)
        'keyword': keyword.trim(),
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
      if (excludeDisabled) 'excludeDisabled': true,
      if (excludeStub) 'excludeStub': true,
      if (disabledOnly) 'disabledOnly': true,
      if (stubOnly) 'stubOnly': true,
      if (includeRelated && keyword?.trim().isNotEmpty == true)
        'includeRelated': true,
    };
    query.addAll(goodsFilterQueryParams(filters));

    final json = await api.get(queryBasePath, query: query);
    return PagedResult.fromJsonResponsive(json, GoodsListItem.fromJson);
  }

  @override
  Future<GoodsFacets> facets(
    String categoryId, {
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) => _facets(
    categoryId: categoryId,
    keyword: keyword,
    includeRelated: includeRelated,
    filters: filters,
    excludeDisabled: excludeDisabled,
    excludeStub: excludeStub,
  );

  @override
  Future<GoodsFacets> globalFacets({
    String? categoryId,
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
    Set<String> categoryRootIds = const {},
  }) => _facets(
    categoryId: categoryId,
    keyword: keyword,
    includeRelated: includeRelated,
    filters: filters,
    excludeDisabled: excludeDisabled,
    excludeStub: excludeStub,
    categoryRootIds: categoryRootIds,
  );

  Future<GoodsFacets> _facets({
    String? categoryId,
    String? keyword,
    required bool includeRelated,
    required Map<String, String?> filters,
    required bool excludeDisabled,
    required bool excludeStub,
    Set<String> categoryRootIds = const {},
  }) async {
    final roots = goodsSearchCategoryRoots(categoryRootIds);
    final query = <String, dynamic>{
      'categoryId': ?categoryId,
      if (roots.isNotEmpty) 'categoryRootIds': roots,
      if (keyword?.trim().isNotEmpty == true) 'keyword': keyword!.trim(),
      if (includeRelated && keyword?.trim().isNotEmpty == true)
        'includeRelated': true,
      if (excludeDisabled) 'excludeDisabled': true,
      if (excludeStub) 'excludeStub': true,
      ...goodsFilterQueryParams(filters),
    };
    final json = roots.length > _maxGoodsCategoryRootsInUrl
        ? await api.post(
            '$queryBasePath/facets',
            body: goodsSearchReadBody(query),
          )
        : await api.get('$queryBasePath/facets', query: query);
    return GoodsFacets.fromJson(json);
  }

  @override
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    Set<String> categoryRootIds = const {},
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
    String? sort,
    String? order,
  }) => searchColumns(
    keyword,
    filters: const {},
    page: page,
    size: size,
    categoryRootIds: categoryRootIds,
    categoryId: categoryId,
    includeRelated: includeRelated,
    excludeDisabled: excludeDisabled,
    excludeStub: excludeStub,
    sort: sort,
    order: order,
  );

  @override
  Future<PagedResult<GoodsListItem>> searchColumns(
    String keyword, {
    required Map<String, String?> filters,
    int page = 1,
    int size = 20,
    Set<String> categoryRootIds = const {},
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
    String? sort,
    String? order,
  }) async {
    final roots = goodsSearchCategoryRoots(categoryRootIds);
    return _searchPage(
      keyword,
      page: page,
      size: size,
      categoryRootIds: roots,
      filters: filters,
      categoryId: categoryId,
      includeRelated: includeRelated,
      excludeDisabled: excludeDisabled,
      excludeStub: excludeStub,
      sort: sort,
      order: order,
    );
  }

  Future<PagedResult<GoodsListItem>> _searchPage(
    String keyword, {
    required Map<String, String?> filters,
    required int page,
    required int size,
    required List<String> categoryRootIds,
    required String? categoryId,
    required bool includeRelated,
    required bool excludeDisabled,
    required bool excludeStub,
    String? sort,
    String? order,
  }) async {
    // categoryRootIds 为空时不传，保留调用方明确使用的全库搜索语义。
    final query = <String, dynamic>{
      ...goodsFilterQueryParams(filters),
      'page': page,
      'size': size,
      if (categoryRootIds.isNotEmpty) 'categoryRootIds': categoryRootIds,
      'categoryId': ?categoryId,
      if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      if (includeRelated && keyword.trim().isNotEmpty) 'includeRelated': true,
      if (excludeDisabled) 'excludeDisabled': true,
      if (excludeStub) 'excludeStub': true,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
    final json = categoryRootIds.length > _maxGoodsCategoryRootsInUrl
        ? await api.post(
            '$queryBasePath/search',
            body: goodsSearchReadBody(query),
          )
        : await api.get(queryBasePath, query: query);
    final result = await PagedResult.fromJsonResponsive(
      json,
      GoodsListItem.fromJson,
    );
    if (categoryRootIds.isNotEmpty &&
        result.items.any(
          (item) => item.categoryId == null || item.categoryId!.trim().isEmpty,
        )) {
      throw StateError(
        'scoped goods search returned an item without categoryId',
      );
    }
    return result;
  }

  @override
  Future<Set<String>> searchCategoryIds(
    String keyword, {
    required Set<String> categoryRootIds,
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) => searchColumnCategoryIds(
    keyword,
    filters: const {},
    categoryRootIds: categoryRootIds,
    categoryId: categoryId,
    includeRelated: includeRelated,
    excludeDisabled: excludeDisabled,
    excludeStub: excludeStub,
  );

  @override
  Future<Set<String>> searchColumnCategoryIds(
    String keyword, {
    required Map<String, String?> filters,
    required Set<String> categoryRootIds,
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async {
    final roots = goodsSearchCategoryRoots(categoryRootIds);
    if (roots.isEmpty) return <String>{};
    final query = <String, dynamic>{
      ...goodsFilterQueryParams(filters),
      'categoryRootIds': roots,
      'categoryId': ?categoryId,
      if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      if (includeRelated && keyword.trim().isNotEmpty) 'includeRelated': true,
      if (excludeDisabled) 'excludeDisabled': true,
      if (excludeStub) 'excludeStub': true,
    };
    final ids = roots.length > _maxGoodsCategoryRootsInUrl
        ? await api.postStringList(
            '$queryBasePath/search-category-ids',
            body: goodsSearchReadBody(query),
          )
        : await api.getStringList(
            '$queryBasePath/search-category-ids',
            query: query,
          );
    final result = <String>{};
    for (final rawId in ids) {
      final id = rawId.trim();
      if (id.isEmpty) {
        throw StateError(
          'scoped goods location search returned a blank category id',
        );
      }
      result.add(id);
    }
    return result;
  }

  @override
  Future<GoodsDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.good(id));
    return GoodsDetail.fromJson(json);
  }

  @override
  Future<GoodsDetail> create(Map<String, dynamic> body) async {
    final json = await api.post(ApiEndpoints.goods, body: body);
    return GoodsDetail.fromJson(json);
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    await api.put(ApiEndpoints.good(id), body: body);
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.good(id));
  }
}

final goodsRepositoryProvider = Provider<GoodsRepository>(
  (ref) => DioGoodsRepository(ref.watch(apiClientProvider)),
);
