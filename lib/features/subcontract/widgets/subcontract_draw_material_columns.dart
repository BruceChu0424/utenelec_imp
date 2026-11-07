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
    String title, {
    String? info,
  }) => MasterColumnDef(
    key: key,
    label: title,
    info: info,
    width: quantityWidth,
    type: 'number',
    sortable: true,
    exactValueOf: (row) => row.quantityText(key),
    value: (row) => formatExactQtyWithUnit(row.quantityText(key), row.unitName),
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
    quantity('perUnitQty', '每套备料上限', info: '每套基础用料加冻结损耗额度。'),
    quantity('requiredQty', '备料上限'),
    quantity('sentQty', '已发外'),
    quantity('pendingQty', '待仓库发'),
    quantity('availableQty', '仓库可用'),
    quantity('drawableQty', '本次可领'),
    quantity('shortQty', '备料差额', info: '与含损耗备料上限的差额。成品的基础用料覆盖按冻结基础单耗核对。'),
    const MasterColumnDef(
      key: 'supplySources',
      label: '供应来源',
      width: 240,
      sortable: true,
      value: subcontractDrawSupplyText,
    ),
  ];
}
