import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../models/subcontract_draw.dart';
import 'subcontract_draw_status.dart';

/// The same server-authored material facts in task details and order progress.
/// Each measure keeps its own unit; these columns never add a cross-unit total.
List<MasterColumnDef<SubcontractDrawMaterial>> subcontractDrawMaterialColumns({
  double quantityWidth = 96,
}) {
  String label(String? value) =>
      value?.trim().isNotEmpty == true ? value!.trim() : '—';
  MasterColumnDef<SubcontractDrawMaterial> quantity(
    String key,
    String title,
    double Function(SubcontractDrawMaterial) value,
  ) => MasterColumnDef(
    key: key,
    label: title,
    width: quantityWidth,
    type: 'number',
    sortable: true,
    exactValueOf: (row) => value(row).toString(),
    value: (row) => formatQtyWithUnit(value(row), row.unitName),
  );
  return [
    MasterColumnDef(
      key: 'state',
      label: '状态',
      width: 72,
      filterFromRows: true,
      value: subcontractDrawMaterialStateLabel,
      cellColor: (context, row) => subcontractDrawMaterialCellColor(row),
    ),
    MasterColumnDef(
      key: 'goodsName',
      label: '物料名称',
      width: 180,
      sortable: true,
      value: (row) => label(row.goodsName),
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      sortable: true,
      value: (row) => label(row.goodsCode),
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 90,
      sortable: true,
      filterFromRows: true,
      value: (row) => label(row.colorName),
    ),
    quantity('perUnitQty', '每套用量', (row) => row.perUnitQty),
    quantity('requiredQty', '需求', (row) => row.requiredQty),
    quantity('sentQty', '已发外', (row) => row.sentQty),
    quantity('pendingQty', '待仓库发', (row) => row.pendingQty),
    quantity('availableQty', '仓库可用', (row) => row.availableQty),
    quantity('drawableQty', '本次可领', (row) => row.drawableQty),
    quantity('shortQty', '还缺', (row) => row.shortQty),
    const MasterColumnDef(
      key: 'supplySources',
      label: '供应来源',
      width: 240,
      sortable: true,
      value: subcontractDrawSupplyText,
    ),
  ];
}
