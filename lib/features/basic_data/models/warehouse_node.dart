// 仓库主档模型（对应后端 WarehouseListItem / WarehouseDetail / WarehouseFacets）。
//
// 扁平主档（无分类树）：编号/名称/位置/备注/是否核算/所属车间 legacy/状态 + legacy_id。
// accountable 为 bool；workshopLegacyId 为老库车间主键（暂不 FK，显示用）。

import 'master_facet.dart';

class WarehouseListItem {
  const WarehouseListItem({
    required this.id,
    this.code,
    this.name,
    this.location,
    this.remark,
    this.accountable = true,
    this.workshopLegacyId,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? code;
  final String? name;
  final String? location;
  final String? remark;
  final bool accountable;
  final int? workshopLegacyId;
  final String? status;
  final int? legacyId;

  factory WarehouseListItem.fromJson(Map<String, dynamic> json) =>
      WarehouseListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        location: json['location'] as String?,
        remark: json['remark'] as String?,
        accountable: (json['accountable'] as bool?) ?? true,
        workshopLegacyId: (json['workshopLegacyId'] as num?)?.toInt(),
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

class WarehouseDetail {
  const WarehouseDetail({
    required this.id,
    this.code,
    this.name,
    this.location,
    this.remark,
    this.accountable = true,
    this.workshopLegacyId,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? code;
  final String? name;
  final String? location;
  final String? remark;
  final bool accountable;
  final int? workshopLegacyId;
  final String? status;
  final int? legacyId;

  factory WarehouseDetail.fromJson(Map<String, dynamic> json) =>
      WarehouseDetail(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        location: json['location'] as String?,
        remark: json['remark'] as String?,
        accountable: (json['accountable'] as bool?) ?? true,
        workshopLegacyId: (json['workshopLegacyId'] as num?)?.toInt(),
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

class WarehouseFacets {
  const WarehouseFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = ['code', 'name', 'status'];

  factory WarehouseFacets.fromJson(Map<String, dynamic> json) {
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
    return WarehouseFacets(fields: fields, nullCounts: nullCounts);
  }
}
