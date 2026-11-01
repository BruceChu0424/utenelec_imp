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

/// 解析服务端 facets 响应里某列的桶数组（空安全：缺失/非列表返回空）。
/// 全站 /facets 端点与内嵌 facets 字段的统一解析口——各仓库不要再手写循环。
/// （2026-09-25 单号列统一批次收口。）
List<MasterFacetBucket> parseFacetBuckets(dynamic json, String key) {
  final buckets = json is Map ? json[key] : null;
  if (buckets is! List) return const [];
  return [
    for (final b in buckets)
      if (b is Map<String, dynamic>) MasterFacetBucket.fromJson(b),
  ];
}
