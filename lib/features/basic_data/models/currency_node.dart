// 币种主档模型（对应后端 CurrencyListItem / CurrencyDetail / CurrencyFacets）。
//
// 扁平主档（无分类树），业务字段：编号/名称/参考汇率/状态 + legacy_id（老库溯源）。
// 数值字段走 (json['x'] as num?)，避免后端 BigDecimal 序列化成 String/null 时 cast 崩溃。

import 'master_facet.dart';

/// 币种列表项。
class CurrencyListItem {
  const CurrencyListItem({
    required this.id,
    this.code,
    this.name,
    this.exchangeRate,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? code;
  final String? name;
  final double? exchangeRate;
  final String? status;
  final int? legacyId;

  factory CurrencyListItem.fromJson(Map<String, dynamic> json) =>
      CurrencyListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

/// 币种详情（与列表项同字段，保留独立模型与基础资料范式对齐）。
class CurrencyDetail {
  const CurrencyDetail({
    required this.id,
    this.code,
    this.name,
    this.exchangeRate,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? code;
  final String? name;
  final double? exchangeRate;
  final String? status;
  final int? legacyId;

  factory CurrencyDetail.fromJson(Map<String, dynamic> json) => CurrencyDetail(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
  );
}

/// 字段 facet 结果：各筛选字段（编号/名称/状态）的可选值桶 + 各字段空值计数。
/// exchange_rate 为数字字段，不进 facet（仅列表/详情展示）。
class CurrencyFacets {
  const CurrencyFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = ['code', 'name', 'status'];

  factory CurrencyFacets.fromJson(Map<String, dynamic> json) {
    final fields = <String, List<MasterFacetBucket>>{};
    for (final k in _keys) {
      final list = json[k];
      fields[k] = list is List
          ? list
                .map(
                  (e) => MasterFacetBucket.fromJson(e as Map<String, dynamic>),
                )
                .toList()
          : const [];
    }
    final ncRaw = json['nullCounts'];
    final nullCounts = <String, int>{};
    if (ncRaw is Map) {
      ncRaw.forEach((k, v) {
        nullCounts[k.toString()] = (v is num ? v.toInt() : 0);
      });
    }
    return CurrencyFacets(fields: fields, nullCounts: nullCounts);
  }
}
