// 登记实际到货页(ADR-151 §5：单张 = 1 个来源、多选 = N 个来源)的测试桩工具。
//
// 页面只带来源身份进页(?expectationIds=)，再按 id 从服务端读预计到货；提交是一个批量命令
// POST /warehouse/inbound/arrivals/batch(一个事务，服务端按「订货单 x 入库仓库」分组建收货单)。
// 这里把测试里习惯写的 ProcurementReceiptPrefill 转成服务端预计到货的 JSON 形状，并给出批量命令的回执。
import 'package:uten_imp/shared/models/inbound_allocation.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

const arrivalExpectationsByIdsPath = '/warehouse/inbound/expectations/by-ids';
const arrivalBatchPath = '/warehouse/inbound/arrivals/batch';

/// 预计到货任务(OPEN、可登记)的服务端 JSON：明细批准剩余 = 预填的待登记数量。
Map<String, dynamic> expectationJsonOf(ProcurementReceiptPrefill prefill) {
  final purchase = prefill.orderType == ProcurementInboundOrderType.purchase;
  final total = prefill.items.fold<num>(
    0,
    (sum, item) => sum + item.approvedRemainingQty,
  );
  return {
    'id': prefill.expectationId,
    'orderType': purchase ? 'PURCHASE' : 'SUBCONTRACT',
    'orderId': prefill.orderId ?? 'order-${prefill.expectationId}',
    'billNo': prefill.orderBillNo,
    'supplierId': prefill.supplierId,
    'supplierName': prefill.supplierName,
    'warehouseId': prefill.warehouseId,
    'warehouseName': prefill.warehouseName,
    'suggestedWarehouseId': prefill.suggestedWarehouseId,
    'suggestedWarehouseName': prefill.suggestedWarehouseName,
    'ownerEmployeeId': prefill.purchaserId,
    'status': 'OPEN',
    'orderedQty': total,
    'acceptedQty': 0,
    'remainingQty': total,
    'registeredQty': 0,
    'allowedActions': [
      purchase ? 'CREATE_PURCHASE_RECEIPT' : 'CREATE_SUBCONTRACT_RECEIPT',
    ],
    'draftReceiptIds': const <Object>[],
    'pendingInspectionReceipts': 0,
    'openArrivalExceptions': 0,
    'items': [
      for (final item in prefill.items)
        {
          'id': 'expectation-item-${item.orderItemId}',
          'orderItemId': item.orderItemId,
          'goodsId': item.goodsId,
          'goodsCode': item.goodsCode,
          'goodsName': item.goodsName,
          'goodsSeries': item.goodsSeries,
          'goodsStockPlace': item.goodsStockPlace,
          'colorId': item.colorId,
          'colorName': item.colorName,
          'unitId': item.unitId,
          'unitName': item.unitName,
          'baseUnitId': item.baseUnitId,
          'baseUnitName': item.baseUnitName,
          'unitRate': item.unitRate,
          'unitPrice': item.unitPrice,
          'orderedQty': item.approvedRemainingQty,
          'acceptedQty': 0,
          'remainingQty': item.approvedRemainingQty,
          'registeredQty': 0,
          'lastReceiptWarehouseId': item.lastReceiptWarehouseId,
          'lastReceiptWarehouseName': item.lastReceiptWarehouseName,
          // ADR-144：采购明细的允许超收%与最多可收(已登记待审核量为 0, 原样带回)。
          'allowedOverReceiptPct': item.allowedOverReceiptPct,
          'maxReceivableQty': item.maxReceivableQty,
          'expectedAllocations': [
            for (final allocation in item.expectedAllocations)
              allocationJsonOf(allocation),
          ],
        },
    ],
  };
}

Map<String, dynamic> allocationJsonOf(WarehouseInboundAllocation allocation) =>
    {
      'kind': allocation.kind.apiValue,
      'qty': allocation.qty,
      'targetWarehouseId': allocation.targetWarehouseId,
      'targetWarehouseName': allocation.targetWarehouseName,
      'productCode': allocation.productCode,
      'productName': allocation.productName,
      'baseUnitName': allocation.baseUnitName,
      'sourceLabel': allocation.sourceLabel,
      'planId': allocation.planId,
      'planNo': allocation.planNo,
    };

/// GET by-ids 的回答：按请求里的 id 顺序返回仍存在的任务。
List<Map<String, dynamic>> expectationsByIdsAnswer(
  Map<String, dynamic>? query,
  Iterable<ProcurementReceiptPrefill> prefills,
) {
  final byId = {for (final prefill in prefills) prefill.expectationId: prefill};
  final ids = (query?['ids'] as String? ?? '')
      .split(',')
      .where((id) => id.isNotEmpty);
  return [
    for (final id in ids)
      if (byId[id] case final prefill?) expectationJsonOf(prefill),
  ];
}

/// 批量命令的回执：按「来源订货单号 x 入库仓库」分组，每组一张收货单(与服务端分组口径一致)。
Map<String, dynamic> arrivalBatchAnswer(
  Map<String, dynamic> body, {
  String outcome = 'SUBMITTED_FOR_INSPECTION',
}) {
  final lines = (body['lines'] as List).cast<Map<String, dynamic>>();
  final groups = <String>{
    for (final line in lines) '${line['sourceDocNo']}|${line['warehouseId']}',
  }.toList();
  final stockInFirst = body['stockInBeforeInspection'] == true;
  return {
    'groupCount': groups.length,
    'replay': false,
    'items': [
      for (final (index, group) in groups.indexed)
        {
          'orderType': lines.first['orderType'],
          'orderId': 'order-${group.split('|').first}',
          'warehouseId': group.split('|').last,
          'outcome': stockInFirst && outcome == 'SUBMITTED_FOR_INSPECTION'
              ? 'STOCKED_PENDING_INSPECTION'
              : outcome,
          'receiptId': 'receipt-${index + 1}',
          'receiptBillNo': 'SR-${(index + 1).toString().padLeft(3, '0')}',
          'replayed': false,
        },
    ],
  };
}
