import 'stock_doc.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../../shared/models/production_material_discovery.dart';

/// 一格实称重量的草稿 (ADR-135): 千克 + 是否按称重改了数量 + 数量黄框说明。
///
/// [qty] 给了就一并记下「数量格仍是按这次重量预填的黄框值」, 恢复后黄框与 ⓘ 说明原样回来;
/// 草稿只存千克, 录入单位以恢复时的用户偏好为准 (千克值不变)。
Map<String, dynamic> weightEntryDraft(
  WeightEntryController weight, {
  UtenAutofillTextController? qty,
}) => {
  'kg': weight.kg,
  'qtyFromWeight': weight.qtyFromWeight,
  'qtyNote': weight.qtyEstimateNote,
  if (qty != null)
    'qtyDerived':
        qty.autofilled &&
        weight.derivedQtyText != null &&
        weight.derivedQtyText == qty.text,
};

/// 按 [weightEntryDraft] 的记录恢复重量格; 数量文本须先于本函数恢复。
void restoreWeightEntryDraft(
  WeightEntryController weight,
  Object? raw, {
  UtenAutofillTextController? qty,
}) {
  if (raw is! Map) return;
  final kg = raw['kg'];
  final fromWeight = raw['qtyFromWeight'] == true;
  final note = raw['qtyNote'];
  weight.setKg(kg is num ? kg.toDouble() : null, qtyFromWeight: fromWeight);
  if (qty != null && raw['qtyDerived'] == true && qty.text.isNotEmpty) {
    final text = qty.text;
    qty.setAutomaticText(text);
    weight.markQtyDerived(text, note: note is String ? note : null);
  } else if (fromWeight && note is String) {
    weight.qtyEstimateNote = note;
  }
}

/// Read-only reviewed facts retained solely for replaying the identical interrupted request.
Map<String, dynamic> stockDocumentDraftFacts(StockDocDetail doc) => {
  'id': doc.id,
  'docType': doc.docType,
  'billNo': doc.billNo,
  'billDate': doc.billDate,
  'warehouseId': doc.warehouseId,
  'toWarehouseId': doc.toWarehouseId,
  'remark': doc.remark,
  'totalLocal': doc.totalLocal,
  'status': doc.status,
  'closed': doc.closed,
  'sourceDocNo': doc.sourceDocNo,
  'sourceDailyReportId': doc.sourceDailyReportId,
  'sourcePlanId': doc.sourcePlanId,
  'planNo': doc.planNo,
  'workerId': doc.workerId,
  'makerId': doc.makerId,
  'assTeam': doc.assTeam,
  'departmentId': doc.departmentId,
  'issueStatus': doc.issueStatus,
  'makerName': doc.makerName,
  'workerName': doc.workerName,
  'createdAt': doc.createdAt,
  'productionLinked': doc.productionLinked,
  'productionMaterialReturn': doc.productionMaterialReturn,
  'materialReturnSourceWarehouseId': doc.materialReturnSourceWarehouseId,
  'materialReturnMainWarehouseId': doc.materialReturnMainWarehouseId,
  'canEdit': doc.canEdit,
  'canDelete': doc.canDelete,
  'restrictionReason': doc.restrictionReason,
  'finishedInboundDecision': doc.finishedInboundDecision,
  'finishedInboundVarianceReason': doc.finishedInboundVarianceReason,
  'items': [
    for (final item in doc.items)
      {
        'id': item.id,
        'lineNo': item.lineNo,
        'goodsId': item.goodsId,
        'colorId': item.colorId,
        'unitId': item.unitId,
        'qty': item.qty,
        'reportedQty': item.reportedQty,
        'baseQty': item.baseQty,
        'price': item.price,
        'amountLocal': item.amountLocal,
        'weight': item.weight,
        'surplusQty': item.surplusQty,
        'countQty': item.countQty,
        'place': item.place,
        'remark': item.remark,
        'unitRate': item.unitRate,
        'upstreamItemId': item.upstreamItemId,
        'executionSegmentId': item.executionSegmentId,
        'executionSegmentSalesAllocationId':
            item.executionSegmentSalesAllocationId,
        'sourceDailyReportItemId': item.sourceDailyReportItemId,
        'sourceDocNo': item.sourceDocNo,
        'issuedQty': item.issuedQty,
        'requestedQty': item.requestedQty,
        'qtyFromWeight': item.qtyFromWeight,
        'countWeight': item.countWeight,
        'bookWeight': item.bookWeight,
        'issuedWeightKg': item.issuedWeightKg,
        'issuedWeightEstimated': item.issuedWeightEstimated,
      },
  ],
};

Map<String, dynamic> discoveryDraftFacts(
  ProductionMaterialDiscoveryDetail request,
) => {
  'requestId': request.requestId,
  'segmentId': request.segmentId,
  'segmentCode': request.segmentCode,
  'planNo': request.planNo,
  'productCode': request.productCode,
  'productName': request.productName,
  'productUnitName': request.productUnitName,
  'workshopName': request.workshopName,
  'status': request.status,
  'plannedQty': request.plannedQty,
  'version': request.version,
  'items': request.items,
  'suggestedItems': request.suggestedItems,
  'drawDocIds': request.drawDocIds,
};
