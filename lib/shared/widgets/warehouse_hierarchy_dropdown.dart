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
// 聚合语义（allowParent=true）：父仓可选，选中 = 自身 + 全部子仓聚合
// （服务端 WarehouseScopeService 展开）；「含不良品仓」等聚合口径开关在父仓下仍生效。
// 运营页父仓不可选——单据/收发存只能落到具体仓库；历史已保存的父仓值仍能回显。
import 'package:flutter/material.dart';

import '../../components/inputs/uten_dropdown_field.dart';
import '../providers/master_name_provider.dart';
import 'warehouse_selection.dart';

class WarehouseHierarchyDropdown extends StatelessWidget {
  const WarehouseHierarchyDropdown({
    super.key,
    required this.entries,
    required this.value,
    required this.onChanged,
    this.labelText = '仓库',
    this.includeAll = false,
    this.allowParent = false,
    this.enabled = true,
    this.contentPadding,
  });

  /// 层级有序仓库列表（names.warehouseHierarchy）。
  final List<WarehouseDictEntry> entries;
  final String? value;
  final ValueChanged<String?> onChanged;

  final String labelText;
  final bool includeAll;

  /// true = 允许选父仓（查询聚合语义）；false = 父仓只作分组标题。
  final bool allowParent;
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
      allowParent: allowParent,
      currentValue: value,
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

/// 层级仓库下拉的 UtenDropdownField 选项：顶层仓在前，子仓缩进跟随。
/// allowParent=false（运营默认）时父仓=置灰分组标题（不可点，仍参与值回显）。
List<UtenDropdownItem> warehouseHierarchyItems(
  List<WarehouseDictEntry> hierarchy, {
  bool allowParent = false,
  String? currentValue,
}) {
  final selection = WarehouseSelection(hierarchy);
  final ids = hierarchy.map((e) => e.id).toSet();
  final parentIds = hierarchy
      .map((e) => e.parentId)
      .whereType<String>()
      .where(ids.contains)
      .toSet();
  return [
    for (final e in hierarchy)
      if (allowParent ||
          selection.visibleIds.contains(e.id) ||
          currentValue == e.id)
        UtenDropdownItem(
          value: e.id,
          label: e.name,
          enabled: allowParent || selection.selectableIds.contains(e.id),
          visible: allowParent || selection.visibleIds.contains(e.id),
          indent: e.parentId != null && parentIds.contains(e.parentId) ? 16 : 0,
        ),
  ];
}
