enum ProcurementInboundOrderType { purchase, subcontract, unknown }

ProcurementInboundOrderType procurementInboundOrderTypeFrom(Object? value) {
  return switch (_text(value)?.toUpperCase()) {
    'PURCHASE' => ProcurementInboundOrderType.purchase,
    'SUBCONTRACT' => ProcurementInboundOrderType.subcontract,
    _ => ProcurementInboundOrderType.unknown,
  };
}

extension ProcurementInboundOrderTypeUi on ProcurementInboundOrderType {
  String get label => switch (this) {
    ProcurementInboundOrderType.purchase => '采购',
    ProcurementInboundOrderType.subcontract => '委外',
    ProcurementInboundOrderType.unknown => '未知来源',
  };

  String? get receiptCreateRoute => switch (this) {
    ProcurementInboundOrderType.purchase => '/purchase/receipts/new',
    ProcurementInboundOrderType.subcontract => '/subcontract/receipts/new',
    ProcurementInboundOrderType.unknown => null,
  };
}

class InboundExpectationItem {
  const InboundExpectationItem({
    required this.id,
    required this.orderItemId,
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.unitRate,
    required this.orderedQty,
    required this.acceptedQty,
    required this.remainingQty,
    this.lineNo,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.goodsSeries,
    this.goodsStockPlace,
    this.unitPrice,
    this.expectedDate,
  });

  final String id;
  final String orderItemId;
  final int? lineNo;
  final String goodsId;
  final String goodsCode;
  final String goodsName;
  final String? goodsSeries;
  final String? goodsStockPlace;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final num unitRate;

  /// 订货单价（服务端从订货明细带出；到货登记预填携带、价格列隐藏，审核时服务端权威重算）。
  final num? unitPrice;
  final num orderedQty;
  final num acceptedQty;
  final num remainingQty;
  final String? expectedDate;

  bool get canReceive =>
      orderItemId.isNotEmpty && goodsId.isNotEmpty && remainingQty > 0;

  factory InboundExpectationItem.fromJson(Map<String, dynamic> json) {
    return InboundExpectationItem(
      id: _text(json['id']) ?? '',
      orderItemId: _text(json['orderItemId']) ?? '',
      lineNo: _integer(json['lineNo']),
      goodsId: _text(json['goodsId']) ?? '',
      goodsCode: _text(json['goodsCode']) ?? '',
      goodsName: _text(json['goodsName']) ?? '未命名货品',
      goodsSeries: _text(json['goodsSeries']),
      goodsStockPlace: _text(json['goodsStockPlace']),
      colorId: _text(json['colorId']),
      colorName: _text(json['colorName']),
      unitId: _text(json['unitId']),
      unitName: _text(json['unitName']),
      unitRate: _number(json['unitRate']),
      unitPrice: json['unitPrice'] == null ? null : _number(json['unitPrice']),
      orderedQty: _number(json['orderedQty']),
      acceptedQty: _number(json['acceptedQty']),
      remainingQty: _number(json['remainingQty']),
      expectedDate: _text(json['expectedDate']),
    );
  }
}

class InboundExpectation {
  const InboundExpectation({
    required this.id,
    required this.orderType,
    required this.orderId,
    required this.billNo,
    required this.status,
    required this.orderedQty,
    required this.acceptedQty,
    required this.remainingQty,
    required this.items,
    this.supplierId,
    this.supplierName,
    this.warehouseId,
    this.warehouseName,
    this.expectedDate,
    this.ownerEmployeeId,
    this.ownerEmployeeName,
    this.allowedActions = const <String>{},
  });

  final String id;
  final ProcurementInboundOrderType orderType;
  final String orderId;
  final String billNo;
  final String? supplierId;
  final String? supplierName;
  final String? warehouseId;
  final String? warehouseName;
  final String? expectedDate;
  final String? ownerEmployeeId;
  final String? ownerEmployeeName;
  final String status;
  final num orderedQty;
  final num acceptedQty;
  final num remainingQty;
  final List<InboundExpectationItem> items;
  final Set<String> allowedActions;

  bool get canCreateReceipt {
    final action = switch (orderType) {
      ProcurementInboundOrderType.purchase => 'CREATE_PURCHASE_RECEIPT',
      ProcurementInboundOrderType.subcontract => 'CREATE_SUBCONTRACT_RECEIPT',
      ProcurementInboundOrderType.unknown => '',
    };
    // 入库仓库不作为登记门槛：订货单不再携带仓库，仓库在收货/进仓登记时选择。
    return status == 'OPEN' &&
        action.isNotEmpty &&
        allowedActions.contains(action) &&
        supplierId?.isNotEmpty == true &&
        items.any((item) => item.canReceive);
  }

  ProcurementReceiptPrefill? toReceiptPrefill() {
    if (!canCreateReceipt) return null;
    return ProcurementReceiptPrefill(
      expectationId: id,
      orderType: orderType,
      orderBillNo: billNo,
      orderId: orderId,
      supplierId: supplierId!,
      supplierName: supplierName,
      warehouseId: warehouseId,
      warehouseName: warehouseName,
      purchaserId: ownerEmployeeId,
      items: items
          .where((item) => item.canReceive)
          .map(
            (item) => ProcurementReceiptPrefillItem(
              orderItemId: item.orderItemId,
              goodsId: item.goodsId,
              goodsCode: item.goodsCode,
              goodsName: item.goodsName,
              colorId: item.colorId,
              colorName: item.colorName,
              unitId: item.unitId,
              unitName: item.unitName,
              unitRate: item.unitRate,
              unitPrice: item.unitPrice,
              approvedRemainingQty: item.remainingQty,
            ),
          )
          .toList(growable: false),
    );
  }

  factory InboundExpectation.fromJson(Map<String, dynamic> json) {
    return InboundExpectation(
      id: _text(json['id']) ?? '',
      orderType: procurementInboundOrderTypeFrom(json['orderType']),
      orderId: _text(json['orderId']) ?? '',
      billNo: _text(json['billNo']) ?? '未生成单号',
      supplierId: _text(json['supplierId']),
      supplierName: _text(json['supplierName']),
      warehouseId: _text(json['warehouseId']),
      warehouseName: _text(json['warehouseName']),
      expectedDate: _text(json['expectedDate']),
      ownerEmployeeId: _text(json['ownerEmployeeId']),
      ownerEmployeeName: _text(json['ownerEmployeeName']),
      status: (_text(json['status']) ?? 'UNKNOWN').toUpperCase(),
      orderedQty: _number(json['orderedQty']),
      acceptedQty: _number(json['acceptedQty']),
      remainingQty: _number(json['remainingQty']),
      items: _maps(
        json['items'],
      ).map(InboundExpectationItem.fromJson).toList(growable: false),
      allowedActions: _actions(json['allowedActions']),
    );
  }
}

class ProcurementReceiptPrefill {
  const ProcurementReceiptPrefill({
    required this.expectationId,
    required this.orderType,
    required this.orderBillNo,
    required this.supplierId,
    required this.warehouseId,
    required this.items,
    this.orderId,
    this.supplierName,
    this.warehouseName,
    this.purchaserId,
  });

  final String expectationId;
  final ProcurementInboundOrderType orderType;
  final String orderBillNo;

  /// 来源订货单 id（可点跳订货详情用；空=任务不带时退化为纯编号展示）。
  final String? orderId;
  final String supplierId;
  final String? supplierName;

  /// 入库仓库（可空）：订货单不带仓库时为 null，登记时由用户选择。
  final String? warehouseId;
  final String? warehouseName;
  final String? purchaserId;
  final List<ProcurementReceiptPrefillItem> items;
}

class ProcurementReceiptPrefillItem {
  const ProcurementReceiptPrefillItem({
    required this.orderItemId,
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.unitRate,
    required this.approvedRemainingQty,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.unitPrice,
  });

  final String orderItemId;
  final String goodsId;
  final String goodsCode;
  final String goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final num unitRate;

  /// 订货单价：到货登记行携带（价格列隐藏不展示），保存随行提交；
  /// 服务端审核时仍按订货明细权威重算，防客户端篡改。
  final num? unitPrice;
  final num approvedRemainingQty;
}

class ProcurementArrivalReturnTask {
  const ProcurementArrivalReturnTask({
    required this.id,
    required this.qty,
    required this.status,
    required this.version,
    this.completionNote,
    this.completedAt,
  });

  final String id;
  final num qty;
  final String status;
  final int version;
  final String? completionNote;
  final String? completedAt;

  factory ProcurementArrivalReturnTask.fromJson(Map<String, dynamic> json) {
    return ProcurementArrivalReturnTask(
      id: _text(json['id']) ?? '',
      qty: _number(json['qty']),
      status: (_text(json['status']) ?? 'UNKNOWN').toUpperCase(),
      version: _integer(json['version']) ?? 0,
      completionNote: _text(json['completionNote']),
      completedAt: _text(json['completedAt']),
    );
  }
}

class ProcurementArrivalException {
  const ProcurementArrivalException({
    required this.id,
    required this.orderType,
    required this.receiptId,
    required this.receiptItemId,
    required this.receiptBillNo,
    required this.orderId,
    required this.orderItemId,
    required this.orderBillNo,
    required this.goodsCode,
    required this.goodsName,
    required this.declaredQty,
    required this.approvedRemainingQty,
    required this.requestedExcessQty,
    required this.acceptedQty,
    required this.unacceptedQty,
    required this.status,
    required this.version,
    this.supplierName,
    this.warehouseName,
    this.colorName,
    this.unitName,
    this.decision,
    this.financeAssigneeUserId,
    this.financeAssigneeEmployeeId,
    this.financeAssigneeName,
    this.detectedByEmployeeName,
    this.financeReason,
    this.unitPrice,
    this.declaredAmountOriginal,
    this.declaredAmountLocal,
    this.excessAmountLocal,
    this.approvedExcessQty,
    this.detectedAt,
    this.decidedAt,
    this.returnTask,
    this.allowedActions = const <String>{},
  });

  final String id;
  final ProcurementInboundOrderType orderType;
  final String receiptId;
  final String receiptItemId;
  final String receiptBillNo;
  final String orderId;
  final String orderItemId;
  final String orderBillNo;
  final String? supplierName;
  final String? warehouseName;
  final String goodsCode;
  final String goodsName;
  final String? colorName;
  final String? unitName;
  final num declaredQty;
  final num approvedRemainingQty;
  final num requestedExcessQty;
  final num acceptedQty;
  final num unacceptedQty;
  final String status;
  final String? decision;
  final String? financeAssigneeUserId;
  final String? financeAssigneeEmployeeId;
  final String? financeAssigneeName;
  final String? detectedByEmployeeName;
  final String? financeReason;
  final String? unitPrice;
  final String? declaredAmountOriginal;
  final String? declaredAmountLocal;
  final String? excessAmountLocal;
  final num? approvedExcessQty;
  final int version;
  final String? detectedAt;
  final String? decidedAt;
  final ProcurementArrivalReturnTask? returnTask;
  final Set<String> allowedActions;

  bool get canApproveAll =>
      version > 0 && allowedActions.contains('APPROVE_ALL');
  bool get canApproveCustom =>
      version > 0 && allowedActions.contains('APPROVE_CUSTOM');
  bool get canRejectExcess =>
      version > 0 && allowedActions.contains('REJECT_EXCESS');
  bool get canFinanceDecide =>
      canApproveAll || canApproveCustom || canRejectExcess;
  bool get canCompleteReturn =>
      returnTask != null &&
      returnTask!.version > 0 &&
      allowedActions.contains('COMPLETE_RETURN');
  num get excessQty => requestedExcessQty;

  /// 一键入库可用：财务已定案且有待入库量（RECEIPT_ADJUSTED = 接受量>0、收货草稿已下调）。
  bool get canStockIn => status == 'RECEIPT_ADJUSTED' && acceptedQty > 0;

  String get statusLabel => switch (status) {
    'PENDING_FINANCE' => '未入库，等待财务审批超量',
    'RECEIPT_ADJUSTED' => '已调整收货草稿，等待仓库重新审核',
    'RETURN_REQUIRED' => '部分接收，余量待退供应商',
    'RECEIPT_POSTED' => '已按批准数量入库',
    'CLOSED' => '到货异常已完成',
    'CANCELED' => '到货异常已取消',
    _ => '状态待确认，请刷新',
  };

  factory ProcurementArrivalException.fromJson(Map<String, dynamic> json) {
    final returnTask = _map(json['returnTask']);
    return ProcurementArrivalException(
      id: _text(json['id']) ?? '',
      orderType: procurementInboundOrderTypeFrom(json['orderType']),
      receiptId: _text(json['receiptId']) ?? '',
      receiptItemId: _text(json['receiptItemId']) ?? '',
      receiptBillNo: _text(json['receiptBillNo']) ?? '未生成收货单号',
      orderId: _text(json['orderId']) ?? '',
      orderItemId: _text(json['orderItemId']) ?? '',
      orderBillNo: _text(json['orderBillNo']) ?? '未生成订货单号',
      supplierName: _text(json['supplierName']),
      warehouseName: _text(json['warehouseName']),
      goodsCode: _text(json['goodsCode']) ?? '',
      goodsName: _text(json['goodsName']) ?? '未命名货品',
      colorName: _text(json['colorName']),
      unitName: _text(json['unitName']),
      declaredQty: _number(json['declaredQty']),
      approvedRemainingQty: _number(json['approvedRemainingQty']),
      requestedExcessQty: _number(json['requestedExcessQty']),
      acceptedQty: _number(json['acceptedQty']),
      unacceptedQty: _number(json['unacceptedQty']),
      status: (_text(json['status']) ?? 'UNKNOWN').toUpperCase(),
      decision: _text(json['decision'])?.toUpperCase(),
      financeAssigneeUserId: _text(json['financeAssigneeUserId']),
      financeAssigneeEmployeeId: _text(json['financeAssigneeEmployeeId']),
      financeAssigneeName: _text(json['financeAssigneeName']),
      detectedByEmployeeName: _text(json['detectedByEmployeeName']),
      financeReason: _text(json['financeReason']),
      unitPrice: _text(json['unitPrice'] ?? json['unitPriceSnapshot']),
      declaredAmountOriginal: _text(
        json['declaredAmountOriginal'] ??
            json['declaredAmountOriginalSnapshot'],
      ),
      declaredAmountLocal: _text(
        json['declaredAmountLocal'] ?? json['declaredAmountLocalSnapshot'],
      ),
      excessAmountLocal: _text(
        json['excessAmountLocal'] ?? json['excessAmountLocalSnapshot'],
      ),
      approvedExcessQty: json['approvedExcessQty'] == null
          ? null
          : _number(json['approvedExcessQty']),
      version: _integer(json['version']) ?? 0,
      detectedAt: _text(json['detectedAt']),
      decidedAt: _text(json['decidedAt']),
      returnTask: returnTask == null
          ? null
          : ProcurementArrivalReturnTask.fromJson(returnTask),
      allowedActions: _actions(json['allowedActions']),
    );
  }
}

enum FinanceArrivalDecision {
  rejectExcess('REJECT_EXCESS'),
  approveCustom('APPROVE_CUSTOM'),
  approveAll('APPROVE_ALL');

  const FinanceArrivalDecision(this.apiValue);
  final String apiValue;

  String get label => switch (this) {
    FinanceArrivalDecision.rejectExcess => '只批准订单剩余，超出退回',
    FinanceArrivalDecision.approveCustom => '自定义批准超量',
    FinanceArrivalDecision.approveAll => '全部批准超量',
  };

  String get description => switch (this) {
    FinanceArrivalDecision.rejectExcess => '推荐。只接收原订单已批准剩余量，超出部分退供应商。',
    FinanceArrivalDecision.approveCustom => '批准一部分超量，其余数量退供应商。',
    FinanceArrivalDecision.approveAll => '批准全部实际到货数量进入后续收货审核。',
  };
}

String procurementQty(num value) {
  final fixed = value.toStringAsFixed(4);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

num _number(Object? value) {
  if (value is num) return value;
  return num.tryParse(value?.toString() ?? '') ?? 0;
}

int? _integer(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

Map<String, dynamic>? _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return null;
}

Iterable<Map<String, dynamic>> _maps(Object? value) sync* {
  if (value is! List) return;
  for (final row in value) {
    final map = _map(row);
    if (map != null) yield map;
  }
}

Set<String> _actions(Object? value) {
  if (value is! List) return const <String>{};
  return value
      .map(_text)
      .whereType<String>()
      .map((action) => action.toUpperCase())
      .toSet();
}
