import 'dart:convert';
import 'package:flutter/material.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_sales_outbound.dart';
import 'warehouse_sales_picking_fields.dart';

/// One physical line, retaining its document and actual warehouse identity.
class WarehouseSalesOutboundTableRow {
  const WarehouseSalesOutboundTableRow(this.detail, this.line);

  final WarehouseSalesOutboundDetail detail;
  final WarehouseSalesOutboundLine line;
  String get key => '${detail.header.id}:${line.id}';
}

/// 服务端 `allowedWarehouseTargets` 才是权威：待出库任务只提供「确认出库」一个动作。
WarehouseSalesOutboundAction? warehouseSalesOutboundPrimaryAction(
  WarehouseSalesOutboundSummary item,
) {
  const action = WarehouseSalesOutboundAction.confirmShipment;
  return item.allows(action) ? action : null;
}

String warehouseSalesOutboundActionLabel(
  AppLocalizations l10n,
  WarehouseSalesOutboundAction action,
) => switch (action) {
  WarehouseSalesOutboundAction.confirmShipment =>
    l10n.warehouseOutboundConfirmShipment,
};

/// The API has no optimistic version token. Re-read before sending a command
/// and compare the physical facts the operator reviewed. Server locking and
/// allowed-target validation remain authoritative for the transition itself.
String warehouseSalesOutboundReviewSnapshot(WarehouseSalesOutboundDetail d) =>
    jsonEncode([
      d.header.id,
      d.header.warehouseWorkStatus,
      d.header.warehouseId,
      d.warehouseWorkUpdatedAt,
      d.shipAddress,
      d.contactPhone,
      d.logisticsNo,
      d.parcelCount,
      for (final line in d.lines)
        [
          line.id,
          line.warehouseId,
          line.suggestedWarehouseId,
          for (final choice in line.warehouseChoices)
            [
              choice.warehouseId,
              choice.availableQty,
              choice.requiredQty,
              choice.canFulfill,
            ],
          line.lineNumber,
          line.goodsId,
          line.goodsCode,
          line.goodsName,
          line.currentStockPlaceHint,
          line.actualStockPlace,
          line.colorId,
          line.unitId,
          line.unitName,
          line.quantity,
          line.weight,
          line.parcelQuantity,
          line.cartonCount,
          line.clientProductCode,
          line.clientModel,
          line.sourceDocumentNo,
        ],
    ]);

List<MasterColumnDef<WarehouseSalesOutboundTableRow>>
warehouseSalesOutboundTableColumns({
  required AppLocalizations l10n,
  required List<WarehouseSalesOutboundTableRow> rows,
  bool includeShipment = false,
  String Function(WarehouseSalesOutboundTableRow)? resultOf,
  TextEditingController? Function(WarehouseSalesOutboundTableRow)?
  stockPlaceControllerOf,

  /// V631：给出本行所属单据的核对草稿时，「发出仓」列变成逐行下拉(预填建议仓，
  /// 选项带可发量，不足的禁选)；不给时只读显示已落定的行仓或表头仓。
  WarehouseSalesPickingDraft? Function(WarehouseSalesOutboundTableRow)? draftOf,
  VoidCallback? onDraftChanged,
  bool editingEnabled = true,
}) {
  String? warehouseText(WarehouseSalesOutboundTableRow row) {
    final draft = draftOf?.call(row);
    if (draft != null && draft.selectable) {
      return draft.warehouseNameOf(row.line.id);
    }
    return row.line.warehouseName ?? row.detail.header.warehouseName;
  }

  bool has(String? Function(WarehouseSalesOutboundLine) value) =>
      rows.any((row) => value(row.line)?.trim().isNotEmpty == true);
  MasterColumnDef<WarehouseSalesOutboundTableRow> column(
    String key,
    String label,
    double width,
    String? Function(WarehouseSalesOutboundTableRow) value, {
    String type = 'text',
    String? info,
  }) => MasterColumnDef(
    key: key,
    label: label,
    width: width,
    type: type,
    info: info,
    value: (row) => value(row) ?? '—',
  );

  return [
    if (includeShipment) ...[
      column(
        'billNo',
        l10n.warehouseOutboundBillNo,
        170,
        (r) => r.detail.header.billNo,
        info: l10n.warehouseOutboundBatchHint,
      ),
      if (resultOf != null)
        column('result', l10n.warehouseOutboundBatchResult, 210, resultOf),
      column(
        'client',
        l10n.warehouseOutboundClient,
        150,
        (r) => r.detail.header.clientName,
      ),
    ],
    column(
      'lineNumber',
      l10n.warehouseOutboundLineNo,
      64,
      (r) => r.line.lineNumber?.toString(),
      type: 'number',
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 → 编号 → 颜色 紧邻排布。
    column(
      'goodsName',
      l10n.warehouseOutboundGoodsName,
      210,
      (r) => r.line.goodsName,
    ),
    column(
      'goodsCode',
      l10n.warehouseOutboundGoodsCode,
      126,
      (r) => r.line.goodsCode,
    ),
    column(
      'colorName',
      l10n.warehouseOutboundColor,
      96,
      (r) => r.line.colorName,
    ),
    column(
      'quantity',
      l10n.warehouseOutboundQuantity,
      108,
      (r) => r.line.quantity,
      type: 'number',
    ),
    column('unitName', l10n.warehouseOutboundUnit, 80, (r) => r.line.unitName),
    if (draftOf != null)
      MasterColumnDef(
        key: 'warehouse',
        label: l10n.warehouseSubcontractOutboundWarehouse,
        width: 240,
        info: '已预填建议发出仓(表头仓能发则表头仓，否则首个能发出本行的仓)；各行可分别从不同仓发出，可发量已扣安全库存与其它预留。',
        value: (row) => warehouseText(row) ?? '—',
        cellBuilder: (context, row) {
          final draft = draftOf(row);
          if (draft == null || !draft.selectable) {
            return Text(warehouseText(row) ?? '—');
          }
          final selected = draft.warehouses[row.line.id];
          final choices = row.line.warehouseChoices;
          return UtenDropdownField(
            key: ValueKey('sales-picking-warehouse-line-${row.line.id}'),
            dense: true,
            value: selected,
            allowClear: false,
            enabled: editingEnabled,
            hintText: choices.isEmpty ? '暂无可供货仓库' : '选择发出仓',
            errorMessage: draft.lineErrors[row.line.id],
            items: [
              for (final choice in choices)
                UtenDropdownItem(
                  value: choice.warehouseId,
                  label: choice.label,
                  enabled: choice.canFulfill,
                ),
              if (selected != null &&
                  !choices.any((choice) => choice.warehouseId == selected))
                UtenDropdownItem(
                  value: selected,
                  label:
                      '${draft.warehouseNameOf(row.line.id) ?? '当前仓'} · 无本行可发库存',
                  enabled: false,
                ),
            ],
            onChanged: (value) {
              draft.changeWarehouse(row.line.id, value);
              onDraftChanged?.call();
            },
          );
        },
      )
    else
      column(
        'warehouse',
        l10n.warehouseSubcontractOutboundWarehouse,
        150,
        warehouseText,
      ),
    column(
      'currentStockPlaceHint',
      l10n.warehouseOutboundPlaceHint,
      126,
      (r) => r.line.currentStockPlaceHint,
    ),
    if (stockPlaceControllerOf != null)
      MasterColumnDef(
        key: 'actualStockPlace',
        label: '实际库位号',
        width: 170,
        value: (row) =>
            stockPlaceControllerOf(row)?.text ??
            row.line.actualStockPlace ??
            '',
        cellBuilder: (context, row) {
          final controller = stockPlaceControllerOf(row);
          if (controller == null) return Text(row.line.actualStockPlace ?? '—');
          return TextField(
            key: ValueKey('sales-picking-place-${row.line.id}'),
            controller: controller,
            enabled: editingEnabled,
            maxLength: 200,
            decoration: const UtenInputDecoration(
              InputDecoration(
                isDense: true,
                labelText: '实际库位号',
                hintText: '按本次实际填写',
                counterText: '',
              ),
              info: '已按主档建议库位预填；请按本次实际位置修改，无固定库位可清空。',
            ),
          );
        },
      )
    else if (has((line) => line.actualStockPlace))
      column(
        'actualStockPlace',
        '实际库位号',
        150,
        (row) => row.line.actualStockPlace,
      ),
    if (has((line) => line.weight))
      column(
        'weight',
        l10n.warehouseOutboundWeight,
        96,
        (r) => r.line.weight,
        type: 'number',
      ),
    if (has((line) => line.parcelQuantity))
      column(
        'parcelQuantity',
        l10n.warehouseOutboundParcelQuantity,
        90,
        (r) => r.line.parcelQuantity,
        type: 'number',
      ),
    if (rows.any((r) => r.line.cartonCount != null))
      column(
        'cartonCount',
        l10n.warehouseOutboundCartonCount,
        90,
        (r) => r.line.cartonCount?.toString(),
        type: 'number',
      ),
    if (has((line) => line.clientProductCode))
      column(
        'clientProductCode',
        l10n.warehouseOutboundClientProductCode,
        140,
        (r) => r.line.clientProductCode,
      ),
    if (has((line) => line.clientModel))
      column(
        'clientModel',
        l10n.warehouseOutboundClientModel,
        130,
        (r) => r.line.clientModel,
      ),
    if (has((line) => line.sourceDocumentNo))
      column(
        'sourceDocumentNo',
        l10n.warehouseOutboundSourceOrder,
        170,
        (r) => r.line.sourceDocumentNo,
      ),
    if (includeShipment)
      column(
        'warehouseWorkStatus',
        l10n.warehouseOutboundStatus,
        170,
        (r) => r.detail.header.statusLabel,
      ),
    if (!includeShipment && resultOf != null)
      column('result', l10n.warehouseOutboundBatchResult, 210, resultOf),
  ];
}
