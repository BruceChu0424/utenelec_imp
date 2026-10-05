import '../../../shared/drafts/form_draft_field_codec.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../shared/models/inbound_allocation.dart';
import '../../../shared/models/procurement_inbound.dart';

void restoreArrivalDraftText(
  UtenAutofillTextController controller,
  String value,
  bool autofilled,
) {
  if (autofilled) {
    controller.setAutomaticText(value);
  } else {
    // Explicit user confirmation must survive even when text equals the hint.
    controller.text = value.isEmpty ? ' ' : '';
    controller.text = value;
  }
}

/// Recovery keeps original source identities and intended allocations; the
/// registration endpoint still recomputes current capacity and permissions.
Map<String, dynamic> arrivalPrefillDraft(ProcurementReceiptPrefill value) => {
  'expectationId': value.expectationId,
  'orderType': value.orderType.name,
  'orderBillNo': value.orderBillNo,
  'orderId': value.orderId,
  'supplierId': value.supplierId,
  'supplierName': value.supplierName,
  'warehouseId': value.warehouseId,
  'warehouseName': value.warehouseName,
  'suggestedWarehouseId': value.suggestedWarehouseId,
  'suggestedWarehouseName': value.suggestedWarehouseName,
  'purchaserId': value.purchaserId,
  'items': [for (final item in value.items) arrivalItemDraft(item)],
};

ProcurementReceiptPrefill restoreArrivalPrefillDraft(
  Map<String, dynamic> value,
) => ProcurementReceiptPrefill(
  expectationId: draftText(value, 'expectationId'),
  orderType: ProcurementInboundOrderType.values.byName(
    draftText(value, 'orderType'),
  ),
  orderBillNo: draftText(value, 'orderBillNo'),
  orderId: value['orderId'] as String?,
  supplierId: draftText(value, 'supplierId'),
  supplierName: value['supplierName'] as String?,
  warehouseId: value['warehouseId'] as String?,
  warehouseName: value['warehouseName'] as String?,
  suggestedWarehouseId: value['suggestedWarehouseId'] as String?,
  suggestedWarehouseName: value['suggestedWarehouseName'] as String?,
  purchaserId: value['purchaserId'] as String?,
  items: draftMaps(value['items']).map(restoreArrivalItemDraft).toList(),
);

Map<String, dynamic> arrivalItemDraft(ProcurementReceiptPrefillItem value) => {
  'orderItemId': value.orderItemId,
  'goodsId': value.goodsId,
  'goodsCode': value.goodsCode,
  'goodsName': value.goodsName,
  'goodsSeries': value.goodsSeries,
  'goodsStockPlace': value.goodsStockPlace,
  'colorId': value.colorId,
  'colorName': value.colorName,
  'unitId': value.unitId,
  'unitName': value.unitName,
  'baseUnitId': value.baseUnitId,
  'baseUnitName': value.baseUnitName,
  'unitRate': value.unitRate,
  'approvedRemainingQty': value.approvedRemainingQty,
  // ADR-144 采购允许超收(仅展示)：恢复草稿后「最多可收」列照常显示。
  'allowedOverReceiptPct': value.allowedOverReceiptPct,
  'maxReceivableQty': value.maxReceivableQty,
  'lastReceiptWarehouseId': value.lastReceiptWarehouseId,
  'lastReceiptWarehouseName': value.lastReceiptWarehouseName,
  'expectedAllocations': [
    for (final allocation in value.expectedAllocations)
      {
        'passEventId': allocation.passEventId,
        'stockInBatchItemId': allocation.stockInBatchItemId,
        'kind': allocation.kind.apiValue,
        'qty': allocation.qty,
        'actualWarehouseId': allocation.actualWarehouseId,
        'actualWarehouseName': allocation.actualWarehouseName,
        'targetWarehouseId': allocation.targetWarehouseId,
        'targetWarehouseName': allocation.targetWarehouseName,
        'intendedWarehouseNames': allocation.intendedWarehouseNames,
        'warehouseMatches': allocation.warehouseMatches,
        'analysisId': allocation.analysisId,
        'analysisMaterialId': allocation.analysisMaterialId,
        'productCode': allocation.productCode,
        'productName': allocation.productName,
        'baseUnitName': allocation.baseUnitName,
        'sourceLabel': allocation.sourceLabel,
        'planId': allocation.planId,
        'planNo': allocation.planNo,
        'executionSegmentId': allocation.executionSegmentId,
        'executionSegmentCode': allocation.executionSegmentCode,
        'workshopDepartmentId': allocation.workshopDepartmentId,
        'workshopName': allocation.workshopName,
        'responsibleEmployeeId': allocation.responsibleEmployeeId,
        'responsibleEmployeeName': allocation.responsibleEmployeeName,
        'formationStatus': allocation.formationStatus,
      },
  ],
};

ProcurementReceiptPrefillItem restoreArrivalItemDraft(
  Map<String, dynamic> value,
) => ProcurementReceiptPrefillItem(
  orderItemId: draftText(value, 'orderItemId'),
  goodsId: draftText(value, 'goodsId'),
  goodsCode: draftText(value, 'goodsCode'),
  goodsName: draftText(value, 'goodsName'),
  goodsSeries: value['goodsSeries'] as String?,
  goodsStockPlace: value['goodsStockPlace'] as String?,
  colorId: value['colorId'] as String?,
  colorName: value['colorName'] as String?,
  unitId: value['unitId'] as String?,
  unitName: value['unitName'] as String?,
  baseUnitId: value['baseUnitId'] as String?,
  baseUnitName: value['baseUnitName'] as String?,
  unitRate: value['unitRate'] as num,
  approvedRemainingQty: value['approvedRemainingQty'] as num,
  allowedOverReceiptPct: value['allowedOverReceiptPct'] as num?,
  maxReceivableQty: value['maxReceivableQty'] as num?,
  lastReceiptWarehouseId: value['lastReceiptWarehouseId'] as String?,
  lastReceiptWarehouseName: value['lastReceiptWarehouseName'] as String?,
  expectedAllocations: draftMaps(
    value['expectedAllocations'],
  ).map(WarehouseInboundAllocation.fromJson).toList(),
);
