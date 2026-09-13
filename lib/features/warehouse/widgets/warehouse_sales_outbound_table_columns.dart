import 'dart:convert';
import 'package:flutter/material.dart';

import '../../../components/inputs/uten_input_decoration.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_sales_outbound.dart';

/// One physical line, retaining its document and actual warehouse identity.
class WarehouseSalesOutboundTableRow {
  const WarehouseSalesOutboundTableRow(this.detail, this.line);

  final WarehouseSalesOutboundDetail detail;
  final WarehouseSalesOutboundLine line;
  String get key => '${detail.header.id}:${line.id}';
}

WarehouseSalesOutboundAction? warehouseSalesOutboundPrimaryAction(
  WarehouseSalesOutboundSummary item,
) {
  final action = switch (item.warehouseWorkStatus) {
    WarehouseSalesOutboundStatus.pendingPick =>
      WarehouseSalesOutboundAction.startPicking,
    WarehouseSalesOutboundStatus.picking =>
      WarehouseSalesOutboundAction.finishPicking,
    WarehouseSalesOutboundStatus.picked =>
      WarehouseSalesOutboundAction.handOver,
    WarehouseSalesOutboundStatus.exception =>
      WarehouseSalesOutboundAction.restorePending,
    _ => null,
  };
  return action != null && item.allows(action) ? action : null;
}

String warehouseSalesOutboundActionLabel(
  AppLocalizations l10n,
  WarehouseSalesOutboundAction action,
) => switch (action) {
  WarehouseSalesOutboundAction.startPicking =>
    l10n.warehouseOutboundStartPicking,
  WarehouseSalesOutboundAction.finishPicking =>
    l10n.warehouseOutboundFinishPicking,
  WarehouseSalesOutboundAction.handOver => l10n.warehouseOutboundHandOver,
  WarehouseSalesOutboundAction.restorePending =>
    l10n.warehouseOutboundRestorePending,
  WarehouseSalesOutboundAction.reportException => action.label,
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
      d.canSelectWarehouse,
      for (final option in d.warehouseOptions)
        [
          option.warehouseId,
          option.canFulfill,
          for (final line in option.lines)
            [line.shipmentItemId, line.availableQty, line.requiredQty],
        ],
      for (final line in d.lines)
        [
          line.id,
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
  String? Function(WarehouseSalesOutboundTableRow)? warehouseNameOf,
  bool editingEnabled = true,
}) {
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
    column(
      'goodsCode',
      l10n.warehouseOutboundGoodsCode,
      126,
      (r) => r.line.goodsCode,
    ),
    column(
      'goodsName',
      l10n.warehouseOutboundGoodsName,
      210,
      (r) => r.line.goodsName,
    ),
    column(
      'quantity',
      l10n.warehouseOutboundQuantity,
      108,
      (r) => r.line.quantity,
      type: 'number',
    ),
    column('unitName', l10n.warehouseOutboundUnit, 80, (r) => r.line.unitName),
    column(
      'warehouse',
      l10n.warehouseSubcontractOutboundWarehouse,
      150,
      (r) => warehouseNameOf != null
          ? warehouseNameOf(r)
          : r.detail.header.warehouseName,
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
            style: TextStyle(
              color: MasterDataTableCellScope.maybeOf(context)?.foregroundColor,
            ),
            maxLength: 200,
            decoration: const UtenInputDecoration(
              InputDecoration(
                isDense: true,
                labelText: '实际库位号',
                hintText: '按本次实际填写',
                counterText: '',
              ),
              info: '主档建议库位仅供参考；请按本次实际位置填写，无固定库位可留空。',
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
    if (has((line) => line.colorName))
      column(
        'colorName',
        l10n.warehouseOutboundColor,
        96,
        (r) => r.line.colorName,
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
