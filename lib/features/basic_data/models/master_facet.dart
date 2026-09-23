// 基础资料主档通用 facet 数据契约（货品/模具/客户/供应商 共用）。

/// facet 单个可选值（值 + 命中数 + 展示标签）。value 统一字符串化（颜色/单位 legacy id 也转字符串）。
///
/// [label] 为下拉展示文案，后端对颜色/单位桶填解析名（如 345→"白色"）；筛选仍按 [value]
/// （legacy id）回传后端。[display] 为展示用：label 非空取 label，否则取 value（向后兼容）。
class MasterFacetBucket {
  const MasterFacetBucket({
    required this.value,
    required this.count,
    this.label,
  });

  final String value;
  final int count;
  final String? label;

  String get display => (label != null && label!.isNotEmpty) ? label! : value;

  factory MasterFacetBucket.fromJson(Map<String, dynamic> json) =>
      MasterFacetBucket(
        value: json['value']?.toString() ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
        label: json['label'] as String?,
      );
}

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
};

/// 取出要放进请求体的敏感检索值：搜索框关键字 + 敏感列筛选值。
/// 「筛为空」哨兵只暴露字段名，仍随 nullFields 走查询串。
Map<String, String> contactSensitiveFilterBody(
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
};

/// 去掉敏感筛选值后的筛选表 (敏感字段的「筛为空」哨兵保留)。
Map<String, String?> withoutContactSensitiveValues(
  Map<String, String?> filters,
) => {
  for (final entry in filters.entries)
    if (!kContactSensitiveFilterKeys.contains(entry.key) ||
        entry.value == kMasterFilterNullValue)
      entry.key: entry.value,
};
