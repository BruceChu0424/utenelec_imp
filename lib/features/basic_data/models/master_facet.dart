// 基础资料主档通用 facet 数据契约（货品/模具/客户/供应商 共用）。

import '../../../shared/models/master_facet_bucket.dart';

export '../../../shared/models/master_facet_bucket.dart';

/// A bounded page of distinct candidates queried over the full authorized row
/// scope. Selecting an item still applies the existing exact-value filter.
class MasterFacetPage {
  const MasterFacetPage({
    required this.items,
    required this.hasMore,
    this.page,
    this.size,
  });
  final List<MasterFacetBucket> items;
  final bool hasMore;
  final int? page;
  final int? size;

  factory MasterFacetPage.fromJson(Map<String, dynamic> json) =>
      MasterFacetPage(
        items: [
          for (final item in (json['items'] as List? ?? const []))
            MasterFacetBucket.fromJson(Map<String, dynamic>.from(item as Map)),
        ],
        hasMore: json['hasMore'] == true,
        page: (json['page'] as num?)?.toInt(),
        size: (json['size'] as num?)?.toInt(),
      );
}

typedef MasterFacetPageLoader =
    Future<MasterFacetPage> Function(String column, String keyword, int page);

/// A full candidate source owned by one column; unrelated local facets keep their existing behavior.
typedef MasterFacetColumnLoader =
    Future<MasterFacetPage> Function(String keyword, int page);

/// 空值筛选哨兵：filters 中某字段值等于它表示"筛该字段为空的记录"。
/// repository 据此把字段名收集进 nullFields 请求参数。
const String kMasterFilterNullValue = '__null__';

/// 把主档 dict 端点的映射（id → 名称，如供应商/仓库/客户/币种/展平后的部门树）
/// 转成表头筛选桶：按名称排序、count=0（不强调计数）。
/// [MasterFacetBucket.value] 为字典项 id（UUID），与各列表 repository 的
/// 筛选参数（supplierId/warehouseId/...）类型一致。
List<MasterFacetBucket> masterDictionaryFacets(Map<String, String> entries) {
  final sorted = entries.entries.toList(growable: false)
    ..sort((a, b) => a.value.compareTo(b.value));
  return [
    for (final entry in sorted)
      MasterFacetBucket(value: entry.key, label: entry.value, count: 0),
  ];
}

/// 把主档页的 [filters]（key→value，value 可能为 [kMasterFilterNullValue]）
/// 拆成导出/列表用的 query 参数：常规值 → 字段=值；哨兵值 → 收集进 nullFields。
///
/// 用于 UtenExportButton.queryParams（与列表 repository.list 构造一致，不含 page/size）：
/// ```
/// final q = <String, dynamic>{
///   'categoryId': nodeId,
///   if (kw != null) 'keyword': kw,
///   ...masterFilterQueryParams(_filters),
///   if (_sortKey != null) 'sort': _sortKey,
///   if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
/// };
/// ```
Map<String, dynamic> masterFilterQueryParams(Map<String, String?> filters) {
  // 客户/供应商的手机、电话、银行账号筛选值只走请求体 (见 contactSensitiveFilterBody)。
  filters = withoutContactSensitiveValues(filters);
  final query = <String, dynamic>{};
  final nullFields = <String>[];
  filters.forEach((k, v) {
    if (v == kMasterFilterNullValue) {
      nullFields.add(k);
    } else {
      query[k] = v;
    }
  });
  if (nullFields.isNotEmpty) query['nullFields'] = nullFields;
  return query;
}

/// 客户/供应商列表里的手机、电话、银行账号筛选值属于个人/资金敏感信息：
/// 只能放在 POST 请求体里，不能进 URL 查询串 (反向代理访问日志会整行记下查询串)。
/// 搜索框关键字会匹配手机号，同样只走请求体 (见 [contactSensitiveFilterBody] 的 keyword)。
const Set<String> kContactSensitiveFilterKeys = {
  'mobile',
  'phone',
  'phone2',
  'bankAccount',
  'bankAccountNo',
};

/// 取出要放进请求体的敏感检索值：搜索框关键字 + 敏感列筛选值。
/// 「筛为空」哨兵只暴露字段名，仍随 nullFields 走查询串。
Map<String, dynamic> contactSensitiveFilterBody(
  Map<String, String?> filters, {
  String? keyword,
}) => {
  if (keyword != null && keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
  for (final entry in filters.entries)
    if (kContactSensitiveFilterKeys.contains(entry.key) &&
        entry.value != null &&
        entry.value != kMasterFilterNullValue &&
        entry.value!.trim().isNotEmpty)
      entry.key: entry.value!,
  if (filters.entries.any(
    (entry) =>
        entry.key.startsWith('search.') &&
        kContactSensitiveFilterKeys.contains(entry.key.substring(7)) &&
        entry.value != null &&
        entry.value!.trim().isNotEmpty,
  ))
    'columnSearch': {
      for (final entry in filters.entries)
        if (entry.key.startsWith('search.') &&
            kContactSensitiveFilterKeys.contains(entry.key.substring(7)) &&
            entry.value != null &&
            entry.value!.trim().isNotEmpty)
          entry.key.substring(7): entry.value!,
    },
};

/// 去掉敏感筛选值后的筛选表 (敏感字段的「筛为空」哨兵保留)。
Map<String, String?> withoutContactSensitiveValues(
  Map<String, String?> filters,
) => {
  for (final entry in filters.entries)
    if ((!kContactSensitiveFilterKeys.contains(entry.key) &&
            !(entry.key.startsWith('search.') &&
                kContactSensitiveFilterKeys.contains(
                  entry.key.substring(7),
                ))) ||
        entry.value == kMasterFilterNullValue)
      entry.key: entry.value,
};
