// 仓库主档模型（对应后端 WarehouseListItem / WarehouseDetail / WarehouseFacets）。
//
// ADR-145 单主仓：只有主仓(编号 001)没有上级，其余仓都是它的直属子仓。
// 编号/名称/位置/备注/是否核算/所属车间 UUID/状态/仓库用途 + 服务端算好的 selectableForNew。
// legacyOperatorId 是 B_Storage.WorkID -> Sys_Operator.ID 的只读迁移快照。

import 'master_facet.dart';

class WarehouseWorkshopOption {
  const WarehouseWorkshopOption({
    required this.id,
    required this.code,
    required this.name,
  });

  final String id;
  final String code;
  final String name;

  factory WarehouseWorkshopOption.fromJson(Map<String, dynamic> json) =>
      WarehouseWorkshopOption(
        id: json['id'] as String,
        code: json['code'] as String,
        name: json['name'] as String,
      );
}

class WarehouseListItem {
  const WarehouseListItem({
    required this.id,
    this.code,
    this.name,
    this.location,
    this.remark,
    this.accountable = true,
    this.workshopDepartmentId,
    this.workshopDepartmentName,
    this.legacyOperatorId,
    this.status,
    this.legacyId,
    this.parentId,
    this.parentName,
    this.lineSide = false,
    this.defective = false,
    this.selectableForNew = false,
  });

  final String id;
  final String? code;
  final String? name;
  final String? location;
  final String? remark;
  final bool accountable;
  final String? workshopDepartmentId;
  final String? workshopDepartmentName;

  /// B_Storage.WorkID -> Sys_Operator.ID compatibility snapshot.
  final int? legacyOperatorId;
  final String? status;
  final int? legacyId;

  /// 上级仓库(ADR-145)；只有主仓为 null。
  final String? parentId;

  /// 上级仓库名称（列表列展示用）。
  final String? parentName;

  /// 线边仓（V584 车间内部直送）：车间自己的料架，直送产出先进它再投给上层工单。
  final bool lineSide;

  /// 仓库用途(ADR-145)：true = 不良品仓。
  final bool defective;

  /// 新单能不能选它(ADR-145，服务端只算一次)。
  final bool selectableForNew;

  /// 主仓：唯一没有上级的仓，只作汇总、负责人范围和导航。
  bool get isMain => parentId == null || parentId!.isEmpty;

  factory WarehouseListItem.fromJson(Map<String, dynamic> json) =>
      WarehouseListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        location: json['location'] as String?,
        remark: json['remark'] as String?,
        accountable: (json['accountable'] as bool?) ?? true,
        workshopDepartmentId: json['workshopDepartmentId'] as String?,
        workshopDepartmentName: json['workshopDepartmentName'] as String?,
        legacyOperatorId:
            ((json['legacyOperatorId'] ?? json['workshopLegacyId']) as num?)
                ?.toInt(),
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        parentId: json['parentId'] as String?,
        parentName: json['parentName'] as String?,
        lineSide: (json['lineSide'] as bool?) ?? false,
        defective: (json['defective'] as bool?) ?? false,
        selectableForNew: (json['selectableForNew'] as bool?) ?? false,
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
    this.workshopDepartmentId,
    this.workshopDepartmentName,
    this.legacyOperatorId,
    this.status,
    this.legacyId,
    this.parentId,
    this.lineSide = false,
    this.defective = false,
    this.selectableForNew = false,
  });

  final String id;
  final String? code;
  final String? name;
  final String? location;
  final String? remark;
  final bool accountable;
  final String? workshopDepartmentId;
  final String? workshopDepartmentName;

  /// B_Storage.WorkID -> Sys_Operator.ID compatibility snapshot.
  final int? legacyOperatorId;
  final String? status;
  final int? legacyId;

  /// 上级仓库(ADR-145)；只有主仓为 null。
  final String? parentId;

  /// 线边仓（V584 车间内部直送）。
  final bool lineSide;

  /// 仓库用途(ADR-145)：true = 不良品仓。
  final bool defective;

  /// 新单能不能选它(ADR-145，服务端只算一次)。
  final bool selectableForNew;

  /// 主仓：唯一没有上级的仓。
  bool get isMain => parentId == null || parentId!.isEmpty;

  factory WarehouseDetail.fromJson(Map<String, dynamic> json) =>
      WarehouseDetail(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        location: json['location'] as String?,
        remark: json['remark'] as String?,
        accountable: (json['accountable'] as bool?) ?? true,
        workshopDepartmentId: json['workshopDepartmentId'] as String?,
        workshopDepartmentName: json['workshopDepartmentName'] as String?,
        legacyOperatorId:
            ((json['legacyOperatorId'] ?? json['workshopLegacyId']) as num?)
                ?.toInt(),
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        parentId: json['parentId'] as String?,
        lineSide: (json['lineSide'] as bool?) ?? false,
        defective: (json['defective'] as bool?) ?? false,
        selectableForNew: (json['selectableForNew'] as bool?) ?? false,
      );
}

class WarehouseFacets {
  const WarehouseFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = [
    'code',
    'name',
    'status',
    'parent',
    'accountable',
    'defective',
  ];

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
