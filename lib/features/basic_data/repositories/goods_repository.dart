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
  });

  /// 某分类（子树）下的字段 facet（各字段可选值 + 空值计数）。
  Future<GoodsFacets> facets(String categoryId);

  /// 全局搜货品（组装信息「添加组件」选择器用；不限分类，按编号/名称/型号/规格/系列模糊）。
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    Set<String> categoryRootIds = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  });

  /// 返回受 [categoryRootIds] 约束的关键词命中货品所属分类 id（去重）。
  ///
  /// 选择器用它一次定位完整分类路径，避免为收集 categoryId 下载全部货品分页。
  Future<Set<String>> searchCategoryIds(
    String keyword, {
    required Set<String> categoryRootIds,
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

class DioGoodsRepository implements GoodsRepository {
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
    };
    // 哨兵值 → nullFields（Dio 把 List 序列化成重复 param，Spring Set<String> 绑定）；
    // 其余按 字段=值 发送。
    final nullFields = <String>[];
    filters.forEach((k, v) {
      if (v == kMasterFilterNullValue) {
        nullFields.add(k);
      } else {
        query[k] = v;
      }
    });
    if (nullFields.isNotEmpty) query['nullFields'] = nullFields;

    final json = await api.get(ApiEndpoints.goods, query: query);
    return PagedResult.fromJson(json, GoodsListItem.fromJson);
  }

  @override
  Future<GoodsFacets> facets(String categoryId) async {
    final json = await api.get(
      ApiEndpoints.goodsFacets,
      query: {'categoryId': categoryId},
    );
    return GoodsFacets.fromJson(json);
  }

  @override
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    Set<String> categoryRootIds = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async {
    final rootBatches = _goodsCategoryRootBatches(categoryRootIds);
    if (rootBatches.length > 1) {
      return _searchAcrossRootBatches(
        keyword,
        page: page,
        size: size,
        rootBatches: rootBatches,
        excludeDisabled: excludeDisabled,
        excludeStub: excludeStub,
      );
    }
    return _searchPage(
      keyword,
      page: page,
      size: size,
      categoryRootIds: rootBatches.isEmpty ? const [] : rootBatches.single,
      excludeDisabled: excludeDisabled,
      excludeStub: excludeStub,
    );
  }

  Future<PagedResult<GoodsListItem>> _searchPage(
    String keyword, {
    required int page,
    required int size,
    required List<String> categoryRootIds,
    required bool excludeDisabled,
    required bool excludeStub,
  }) async {
    // categoryRootIds 为空时不传，保留调用方明确使用的全库搜索语义。
    final json = await api.get(
      ApiEndpoints.goods,
      query: {
        'page': page,
        'size': size,
        if (categoryRootIds.isNotEmpty) 'categoryRootIds': categoryRootIds,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        if (excludeDisabled) 'excludeDisabled': true,
        if (excludeStub) 'excludeStub': true,
      },
    );
    final result = PagedResult.fromJson(json, GoodsListItem.fromJson);
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
  Future<PagedResult<GoodsListItem>> _searchAcrossRootBatches(
    String keyword, {
    required int page,
    required int size,
    required List<List<String>> rootBatches,
    required bool excludeDisabled,
    required bool excludeStub,
  }) async {
    final uniqueItems = <String, GoodsListItem>{};
    for (final roots in rootBatches) {
      var backendPage = 1;
      var backendTotalPages = 1;
      while (backendPage <= backendTotalPages) {
        final result = await _searchPage(
          keyword,
          page: backendPage,
          size: _goodsSearchMergeFetchSize,
          categoryRootIds: roots,
          excludeDisabled: excludeDisabled,
          excludeStub: excludeStub,
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
          'categoryRootIds': roots,
          if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
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
