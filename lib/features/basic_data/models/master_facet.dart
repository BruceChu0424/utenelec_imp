// 基础资料主档通用 facet 数据契约（货品/模具/客户/供应商 共用）。

/// facet 单个可选值（值 + 命中数 + 展示标签）。value 统一字符串化（颜色/单位 legacy id 也转字符串）。
///
/// [label] 为下拉展示文案，后端对颜色/单位桶填解析名（如 345→"白色"）；筛选仍按 [value]
/// （legacy id）回传后端。[display] 为展示用：label 非空取 label，否则取 value（向后兼容）。
class MasterFacetBucket {
  const MasterFacetBucket({required this.value, required this.count, this.label});

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
