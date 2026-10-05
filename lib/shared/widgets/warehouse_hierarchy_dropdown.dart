// 仓库层级下拉（V476 主/子层级统一呈现）——全站仓库选择入口共用。
//
// 数据：MasterDictionaryService.warehouseHierarchy（顶层仓在前、子仓紧随其后，
// parentId 悬空按顶层处理；旧后端未返回 parentId 时自动退化为平铺列表）。
//
// 两种呈现（都只服务「单据表单里的一格」——2026-09-11 起查询页的仓库筛选
// 一律改用 showUtenWarehousePickerPanel 侧滑面板 + UtenFilterPickerField 字段，
// 表单内保留下拉是因为它在 UtenFormGrid 里与日期/文本各格同节奏，录单时就地
// 点选比拉面板少一步）：
// - [WarehouseHierarchyDropdown]：UtenDropdownField 形态（2026-09-16 全站下拉统一，
//   原 Material DropdownButtonFormField 裸实现已下线）；
// - [warehouseHierarchyItems]：UtenDropdownField 选项列表（编辑页/登记页用），
//   父仓在运营口径（allowParent=false）下渲染为置灰分组标题。
//
// 必填的用途 [WarehouseUse] 决定口径(ADR-146)：查询口径(WarehouseUse.query)父仓可选，选中 = 自身
// + 全部子仓聚合(服务端 WarehouseScopeService 展开)；「含不良品仓」等聚合口径开关在父仓下仍生效；
// 已停用的仓默认不列(ADR-145)。运营口径(良品入/良品出/转入不良/不良转出/处置出库/调拨/盘点)只认
// 服务端算好的可选标记，主仓只作分组标题——单据/收发存只能落到可选子仓；不良品仓名称后带「不良品」，
// 良品用途下置灰不可选；历史已保存的值仍能回显。
import 'package:flutter/material.dart';

import '../../components/inputs/uten_dropdown_field.dart';
import '../providers/master_name_provider.dart';
import 'warehouse_defective_tag.dart';
import 'warehouse_selection.dart';

class WarehouseHierarchyDropdown extends StatelessWidget {
  const WarehouseHierarchyDropdown({
    super.key,
    required this.entries,
    required this.value,
    required this.onChanged,
    required this.use,
    this.labelText = '仓库',
    this.includeAll = false,
    this.sameClassAs,
    this.enabled = true,
    this.contentPadding,
  });

  /// 层级有序仓库列表（names.warehouseHierarchy）。
  final List<WarehouseDictEntry> entries;
  final String? value;
  final ValueChanged<String?> onChanged;

  /// 字段浮动标签。表格单元格里列头已表意，传 null 即不画标签
  /// （2026-09-27 表格小字清理口径）；表单里照旧传文字。
  final String? labelText;
  final bool includeAll;

  /// 选仓用途(ADR-146)：query = 允许选父仓(查询聚合语义)；其余 = 父仓只作分组标题。
  final WarehouseUse use;

  /// 普通调拨的调入仓：只列与这个调出仓同类(良品/不良品)的仓。
  final String? sameClassAs;
  final bool enabled;

  /// 历史参数（Material 形态时用于与 UtenSearchBar 等高）：UtenDropdownField
  /// 统一形态下不再生效，仅为 API 兼容保留，调用方已不再传。
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    // includeAll 口径：null = 全部。UtenDropdownField 的 null=清空不能当选项值，
    // 在包装层用空串哨兵互转，对外 API 语义不变。
    final items = warehouseHierarchyItems(
      entries,
      use: use,
      currentValue: value,
      sameClassAs: sameClassAs,
      // 只有字典里真有不良品仓时才取文案(没挂本地化的轻量宿主也能用这个下拉)。
      defectiveTag: entries.any((entry) => entry.isDefective)
          ? warehouseL10n(context).warehouseDefectiveTag
          : null,
    );
    return UtenDropdownField(
      label: labelText,
      value: includeAll && value == null ? '' : value,
      allowClear: false,
      enabled: enabled,
      items: [
        if (includeAll) const UtenDropdownItem(value: '', label: '全部'),
        ...items,
      ],
      onChanged: (v) => onChanged(includeAll && v == '' ? null : v),
    );
  }
}

/// 层级仓库下拉的 UtenDropdownField 选项：主仓在前，子仓缩进跟随。
/// 运营口径时主仓=置灰分组标题(不可点，仍参与值回显)；查询口径(WarehouseUse.query)时
/// 任意层级可选、已停用的仓不列。当前值总能回显。[defectiveTag] 给出时不良品仓名称后加
/// 「(不良品)」(ADR-146)。
List<UtenDropdownItem> warehouseHierarchyItems(
  List<WarehouseDictEntry> hierarchy, {
  required WarehouseUse use,
  String? currentValue,
  String? sameClassAs,
  String? defectiveTag,
}) {
  final selection = WarehouseSelection(
    hierarchy,
    use: use,
    sameClassAs: sameClassAs,
  );
  final ids = hierarchy.map((e) => e.id).toSet();
  final parentIds = hierarchy
      .map((e) => e.parentId)
      .whereType<String>()
      .where(ids.contains)
      .toSet();
  return [
    for (final e in hierarchy)
      if (selection.visibleIds.contains(e.id) || currentValue == e.id)
        UtenDropdownItem(
          value: e.id,
          label: e.isDefective && defectiveTag != null
              ? '${e.name} ($defectiveTag)'
              : e.name,
          enabled: selection.selectableIds.contains(e.id),
          visible: selection.visibleIds.contains(e.id),
          indent: e.parentId != null && parentIds.contains(e.parentId) ? 16 : 0,
        ),
  ];
}
