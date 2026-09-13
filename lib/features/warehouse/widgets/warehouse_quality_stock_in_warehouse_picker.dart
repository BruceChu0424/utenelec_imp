import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import 'warehouse_quality_slice_table.dart';

/// 只有实际点击选仓才加载仓库字典；不拉全量货品、员工等无关主档。
Future<WarehousePickerResult?> pickWarehouseQualityStockInWarehouse(
  BuildContext context,
  WidgetRef ref,
  WarehouseQualitySliceDraft draft,
) async {
  final dictionary = ref.read(masterNameServiceProvider);
  await dictionary.ensureWarehousesLoaded();
  if (!context.mounted) return null;
  final hierarchy = dictionary.warehouseHierarchy;
  if (WarehouseSelection(hierarchy).selectableIds.isEmpty) {
    context.appWarning('未能取得可用的记账叶仓，请刷新仓库资料后重试');
    return null;
  }
  return showUtenWarehousePickerPanel(
    context,
    hierarchy: hierarchy,
    initialWarehouseId: draft.warehouseId,
    title: '选择目标叶仓 · ${draft.goodsLabel}',
  );
}
