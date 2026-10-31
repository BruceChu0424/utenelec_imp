import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import 'warehouse_quality_slice_table.dart';

/// 只有实际点击选仓才加载仓库字典；不拉全量货品、员工等无关主档。
Future<WarehousePickerResult?> pickWarehouseQualityStockInWarehouse(
  BuildContext context,
  WidgetRef ref,
  WarehouseQualitySliceDraft draft,
) => pickWarehouseLeafForStockIn(
  context,
  ref,
  initialWarehouseId: draft.warehouseId,
  title: '选择目标叶仓 · ${draft.goodsLabel}',
);

/// 确认入库 / 先入库上架共用当前会话字典面板，统一加载、失败与重试。
Future<WarehousePickerResult?> pickWarehouseLeafForStockIn(
  BuildContext context,
  WidgetRef ref, {
  String? initialWarehouseId,
  String title = '选择入库仓库',
}) {
  return showUtenWarehouseDictionaryPickerPanel(
    context,
    initialWarehouseId: initialWarehouseId,
    title: title,
    use: WarehouseUse.goodIn,
  );
}
