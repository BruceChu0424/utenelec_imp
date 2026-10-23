// 货品主档仓库：分类（子树）下分页列表（动态筛选）+ 字段 facets + 详情。
//
// 仿 DioProductCategoryRepository，端点走 ApiEndpoints.goods 系列；
// 分页结果复用 PagedResult（对应后端 PageResponse）。
// filters 中值 == kMasterFilterNullValue 的字段名收集进 nullFields（空值筛选）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
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

const _maxGoodsCategoryRootsPerRequest = 32;
const _goodsSearchMergeFetchSize = 100;

List<List<String>> _goodsCategoryRootBatches(Set<String> rawIds) {
  if (rawIds.isEmpty) return const <List<String>>[];
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
  return [
    for (
      var offset = 0;
      offset < ids.length;
      offset += _maxGoodsCategoryRootsPerRequest
    )
      ids.sublist(
        offset,
        offset + _maxGoodsCategoryRootsPerRequest < ids.length
            ? offset + _maxGoodsCategoryRootsPerRequest
            : ids.length,
      ),
  ];
}

/// 跨批合并结果的客户端排序（见 _searchAcrossRootBatches 注释）。
/// 只覆盖服务端排序白名单键（code/price）；asc 空值排尾、desc 取反后空值排头，
/// 与 PostgreSQL 默认 NULLS 口径一致。同值按同方向的 id 稳定排序。
Comparator<GoodsListItem>? _searchMergeComparator(String? sort, String? order) {
  int compareNullable<T extends Comparable<T>>(T? a, T? b) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  int Function(GoodsListItem, GoodsListItem)? byKey;
  switch (sort) {
    case 'code':
      byKey = (a, b) => compareNullable(a.code, b.code);
    case 'price':
      byKey = (a, b) => compareNullable(a.price, b.price);
  }
  if (byKey == null) return null;
  final asc = order?.toLowerCase() != 'desc';
  return (a, b) {
    final compared = byKey!(a, b);
    final stable = compared != 0 ? compared : a.id.compareTo(b.id);
    return asc ? stable : -stable;
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

class DioGoodsRepository implements GoodsRepository, GoodsColumnSearchGateway {
  DioGoodsRepository(this.api);
  final ApiClient api;

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

    final json = await api.get(ApiEndpoints.goods, query: query);
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
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
    Set<String> categoryRootIds = const {},
  }) => _facets(
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
    final json = await api.get(
      ApiEndpoints.goodsFacets,
      query: {
        'categoryId': ?categoryId,
        if (categoryRootIds.isNotEmpty)
          'categoryRootIds': categoryRootIds.toList(),
        if (keyword?.trim().isNotEmpty == true) 'keyword': keyword!.trim(),
        if (includeRelated && keyword?.trim().isNotEmpty == true)
          'includeRelated': true,
        if (excludeDisabled) 'excludeDisabled': true,
        if (excludeStub) 'excludeStub': true,
        ...goodsFilterQueryParams(filters),
      },
    );
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
    final rootBatches = _goodsCategoryRootBatches(categoryRootIds);
    if (rootBatches.length > 1) {
      return _searchAcrossRootBatches(
        keyword,
        page: page,
        size: size,
        rootBatches: rootBatches,
        filters: filters,
        categoryId: categoryId,
        includeRelated: includeRelated,
        excludeDisabled: excludeDisabled,
        excludeStub: excludeStub,
        sort: sort,
        order: order,
      );
    }
    return _searchPage(
      keyword,
      page: page,
      size: size,
      categoryRootIds: rootBatches.isEmpty ? const [] : rootBatches.single,
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
    final json = await api.get(
      ApiEndpoints.goods,
      query: {
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
      },
    );
    final result = await PagedResult.fromJsonResponsive(json, GoodsListItem.fromJson);
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

  /// 后端单次最多接受 32 个分类根。超过上限时按已排序根分批拉完各批结果，
  /// 以货品 id 去重后再切调用方请求页；任一批失败都会整体抛错，不返回部分结果。
  ///
  /// 批与批的拼接会破坏服务端排序（批1全部+批2全部），传了 [sort] 时在合并后
  /// 按同一键客户端重排一次，保证与单批路径同序。
  Future<PagedResult<GoodsListItem>> _searchAcrossRootBatches(
    String keyword, {
    required Map<String, String?> filters,
    required int page,
    required int size,
    required List<List<String>> rootBatches,
    required String? categoryId,
    required bool includeRelated,
    required bool excludeDisabled,
    required bool excludeStub,
    String? sort,
    String? order,
  }) async {
    final uniqueItems = <String, GoodsListItem>{};
    for (final roots in rootBatches) {
      var backendPage = 1;
      var backendTotalPages = 1;
      while (backendPage <= backendTotalPages) {
        final result = await _searchPage(
          keyword,
          filters: filters,
          page: backendPage,
          size: _goodsSearchMergeFetchSize,
          categoryRootIds: roots,
          categoryId: categoryId,
          includeRelated: includeRelated,
          excludeDisabled: excludeDisabled,
          excludeStub: excludeStub,
          sort: sort,
          order: order,
        );
        for (final item in result.items) {
          uniqueItems.putIfAbsent(item.id, () => item);
        }
        if (result.totalPages > backendTotalPages) {
          backendTotalPages = result.totalPages;
        }
        backendPage++;
      }
    }

    final normalizedPage = page < 1 ? 1 : page;
    final normalizedSize = size.clamp(1, _goodsSearchMergeFetchSize);
    final merged = uniqueItems.values.toList(growable: false);
    final comparator =
        _searchMergeComparator(sort, order) ??
        _searchMergeComparator('code', 'asc')!;
    merged.sort((a, b) {
      final relevance = (a.searchRank ?? 0).compareTo(b.searchRank ?? 0);
      if (relevance != 0) return relevance;
      final requested = comparator(a, b);
      return requested != 0 ? requested : a.id.compareTo(b.id);
    });
    final total = merged.length;
    final totalPages = total == 0
        ? 0
        : (total + normalizedSize - 1) ~/ normalizedSize;
    final start = (normalizedPage - 1) * normalizedSize;
    final items = start >= total
        ? const <GoodsListItem>[]
        : merged.sublist(
            start,
            start + normalizedSize < total ? start + normalizedSize : total,
          );
    return PagedResult(
      items: items,
      page: normalizedPage,
      size: normalizedSize,
      total: total,
      totalPages: totalPages,
    );
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
    final rootBatches = _goodsCategoryRootBatches(categoryRootIds);
    if (rootBatches.isEmpty) return <String>{};

    final merged = <String>{};
    for (final roots in rootBatches) {
      final ids = await api.getStringList(
        ApiEndpoints.goodsSearchCategoryIds,
        query: {
          ...goodsFilterQueryParams(filters),
          'categoryRootIds': roots,
          'categoryId': ?categoryId,
          if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
          if (includeRelated && keyword.trim().isNotEmpty)
            'includeRelated': true,
          if (excludeDisabled) 'excludeDisabled': true,
          if (excludeStub) 'excludeStub': true,
        },
      );
      for (final rawId in ids) {
        final id = rawId.trim();
        if (id.isEmpty) {
          throw StateError(
            'scoped goods location search returned a blank category id',
          );
        }
        merged.add(id);
      }
    }
    return merged;
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
