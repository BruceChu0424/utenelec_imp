import 'package:flutter/material.dart';

import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';

/// Warehouse staff choose the real normal storage location. Origin is traceability.
Future<String?> showProductionMaterialReturnReceiveDialog(
  BuildContext context, {
  required List<WarehouseDictEntry> hierarchy,
  required String? mainWarehouseId,
  String? initialWarehouseId,
}) {
  final eligible = WarehouseSelection(hierarchy).selectableIds;
  final scoped = hierarchy
      .where(
        (entry) =>
            mainWarehouseId != null &&
            warehousesShareMain(hierarchy, mainWarehouseId, entry.id),
      )
      .toList();
  final allowed = scoped
      .map((entry) => entry.id)
      .where(eligible.contains)
      .toSet();
  String? selected = allowed.contains(initialWarehouseId)
      ? initialWarehouseId
      : null;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('确认余料收仓'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const UtenReviewerResponsibilityNotice(actionLabel: '余料收仓'),
                const SizedBox(height: UtenSpacing.s12),
                const Text(
                  '请核对当前车间送来的物料、单位和数量，选择实物实际存放的正常仓库。数量不符时请由车间撤回更正后再确认。',
                ),
                const SizedBox(height: UtenSpacing.s16),
                UtenDropdownField(
                  key: const ValueKey('material-return-receiving-warehouse'),
                  label: '实际收料仓库',
                  required: true,
                  allowClear: false,
                  value: selected,
                  items: warehouseHierarchyItems(scoped),
                  info: '来源记录用于追溯；本次库存进入这里选择的正常仓库。',
                  errorMessage: mainWarehouseId == null
                      ? '来源主仓尚未读取，请刷新单据'
                      : allowed.isEmpty
                      ? '此主仓下暂无有效正常收料仓库'
                      : null,
                  onChanged: (value) => setState(
                    () => selected = allowed.contains(value) ? value : null,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: allowed.contains(selected)
                ? () => Navigator.pop(context, selected)
                : null,
            child: const Text('确认收料'),
          ),
        ],
      ),
    ),
  );
}
