import '../../../../shared/providers/master_name_provider.dart';

/// 发料来源仓滑窗用的仓库元数据 (ADR-147, GET /workshop-material/settings/source-warehouses)。
///
/// 只有层级与能不能选: 编号、名称、上级、状态、是不是不良品仓、能不能选 (服务端按
/// fn_warehouse_is_good_stock_leaf 算好)。不含库存、负责人、位置等仓库管理字段, 所以开通设置
/// 与仓库发料不需要仓库资料或库存查看权限也能选仓。
class WmSourceWarehouse {
  const WmSourceWarehouse({
    required this.id,
    required this.name,
    this.code,
    this.parentId,
    this.status,
    this.defective = false,
    this.selectable = false,
    this.selectableDefective = false,
  });

  final String id;
  final String name;
  final String? code;
  final String? parentId;
  final String? status;
  final bool defective;
  final bool selectable;

  /// 启用中的不良品子仓: 良品用途的滑窗里照常列出 (带「不良品」标签) 但置灰不可选。
  final bool selectableDefective;

  factory WmSourceWarehouse.fromJson(Map<String, dynamic> json) =>
      WmSourceWarehouse(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['code'] as String? ?? '',
        code: json['code'] as String?,
        parentId: json['parentId'] as String?,
        status: json['status'] as String?,
        defective: json['defective'] as bool? ?? false,
        selectable: json['selectable'] as bool? ?? false,
        selectableDefective: json['selectableDefective'] as bool? ?? false,
      );

  /// 交给全站仓库滑窗 (showUtenWarehousePickerPanel) 的字典行: 能不能选只认服务端的 [selectable]。
  WarehouseDictEntry toDictEntry() => WarehouseDictEntry(
    id: id,
    name: name,
    code: code,
    parentId: parentId,
    status: status,
    isDefective: defective,
    selectableForNew: selectable,
    selectableDefective: selectableDefective,
  );
}
