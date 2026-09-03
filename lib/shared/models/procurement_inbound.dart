/// 到货任务在仓库流水线中的当前步骤（到货登记 → [超量待财务] → 送检 → 品质放行）。
enum InboundArrivalStep {
  /// 可登记实际到货（还有批准剩余量可收）。
  readyToRegister,

  /// 已登记待送检（草稿收货单在途）：一键「继续送检」完成停止的步骤。
  draftPendingInspection,

  /// 实到超量已隔离，待财务定案（到货异常任务中心处理）。
  excessPendingFinance,

  /// 已送检，待品质部检验放行（合格后转独立仓库待入库任务）。
  awaitingQuality,

  /// 暂不能登记（数据/授权不完整）。
  blocked,
}

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
    // 登记实际到货走仓库独立页（价格/币种对仓库不可见；保存后由任务中心直达收货单审核页）。
    ProcurementInboundOrderType.purchase => '/warehouse/inbound/receipts/new',
    ProcurementInboundOrderType.subcontract =>
      '/warehouse/inbound/receipts/new',
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
    this.registeredQty = 0,
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

  /// 服务端当前允许继续登记的数量。采购为财务批准未收量；V436 新委外仅为
  /// 已真实审核出仓、扣除已审核回厂并计入合法 IQC 返修额度后的当前容量。
  final num remainingQty;

  /// 已登记待审核在途量（服务端按草稿未审收货单汇总）：审核通过后转入 acceptedQty。
  final num registeredQty;
  final String? expectedDate;

  /// 还可登记量 = 当前服务端释放容量 − 已登记待审核量。
  num get effectiveRemainingQty {
    final value = remainingQty - registeredQty;
    return value > 0 ? value : 0;
  }

  bool get canReceive =>
      orderItemId.isNotEmpty && goodsId.isNotEmpty && effectiveRemainingQty > 0;

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
      registeredQty: _number(json['registeredQty']),
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
    this.registeredQty = 0,
    required this.items,
    this.supplierId,
    this.supplierName,
    this.warehouseId,
    this.warehouseName,
    this.suggestedWarehouseId,
    this.suggestedWarehouseName,
    this.expectedDate,
    this.ownerEmployeeId,
    this.ownerEmployeeName,
    this.allowedActions = const <String>{},
    this.draftReceiptIds = const <String>[],
    this.pendingInspectionReceipts = 0,
    this.openArrivalExceptions = 0,
  });

  final String id;
  final ProcurementInboundOrderType orderType;
  final String orderId;
  final String billNo;
  final String? supplierId;
  final String? supplierName;
  final String? warehouseId;
  final String? warehouseName;

  /// 建议入库仓库（服务端沿 订货明细→申请→计划前供给行动 回溯物料分析目标仓，
  /// 唯一才建议）：登记到货页据此预填，仓库可按实际到货情况更换。
  final String? suggestedWarehouseId;
  final String? suggestedWarehouseName;
  final String? expectedDate;
  final String? ownerEmployeeId;
  final String? ownerEmployeeName;
  final String status;
  final num orderedQty;
  final num acceptedQty;

  /// 当前页面可登记容量合计；委外不是整张订货未收量，而是已经真实出仓的批次余量。
  final num remainingQty;

  /// 已登记待审核在途量合计（草稿未审收货单）；>0 时卡片展示「已登记待审核」。
  final num registeredQty;
  final List<InboundExpectationItem> items;
  final Set<String> allowedActions;

  /// 该任务当前挂着的草稿收货单 id（服务端按订货明细关联聚合）：
  /// 「已登记待审核」态据此提供「继续送检」恢复入口（中途退出的恢复步骤）。
  final List<String> draftReceiptIds;

  /// 待品质放行的收货单张数（已审核、IQC 未结，货在待检隔离未进可用库存）：
  /// 任务卡的「待品质检验」步骤。
  final int pendingInspectionReceipts;

  /// 未结到货异常数（超量被隔离，待财务定案）：任务卡的「超量待财务」步骤。
  final int openArrivalExceptions;

  /// 流水线当前步骤（优先级：超量待财务 > 待送检 > 待登记 > 不可登记）。
  /// 2026-09-01 起「已送检 · 待品质检验」不再占用本页：送检即移交品质，
  /// 改在「品质部检查结果」页以 等待检查结果/全部合格/部分合格/全部不合格 跟踪。
  InboundArrivalStep get arrivalStep {
    if (openArrivalExceptions > 0) {
      return InboundArrivalStep.excessPendingFinance;
    }
    if (draftReceiptIds.isNotEmpty) {
      return InboundArrivalStep.draftPendingInspection;
    }
    if (canCreateReceipt) return InboundArrivalStep.readyToRegister;
    if (awaitingReceiptReview) return InboundArrivalStep.draftPendingInspection;
    return InboundArrivalStep.awaitingQuality;
  }

  /// 还可登记量 = 当前服务端释放容量 − 已登记待审核量。
  num get effectiveRemainingQty {
    final value = remainingQty - registeredQty;
    return value > 0 ? value : 0;
  }

  /// 全部可收明细均已登记、正等收货审核：任务仍 OPEN 但无可再登记量，
  /// 卡片显示「已登记待审核」而非错误的「暂不能登记」。
  bool get awaitingReceiptReview =>
      status == 'OPEN' &&
      registeredQty > 0 &&
      !items.any((item) => item.canReceive);

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
      suggestedWarehouseId: suggestedWarehouseId,
      suggestedWarehouseName: suggestedWarehouseName,
      purchaserId: ownerEmployeeId,
      items: items
          .where((item) => item.canReceive)
          .map(
            (item) => ProcurementReceiptPrefillItem(
              orderItemId: item.orderItemId,
              goodsId: item.goodsId,
              goodsCode: item.goodsCode,
              goodsName: item.goodsName,
              goodsSeries: item.goodsSeries,
              goodsStockPlace: item.goodsStockPlace,
              colorId: item.colorId,
              colorName: item.colorName,
              unitId: item.unitId,
              unitName: item.unitName,
              unitRate: item.unitRate,
              unitPrice: item.unitPrice,
              approvedRemainingQty: item.effectiveRemainingQty,
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
      suggestedWarehouseId: _text(json['suggestedWarehouseId']),
      suggestedWarehouseName: _text(json['suggestedWarehouseName']),
      expectedDate: _text(json['expectedDate']),
      ownerEmployeeId: _text(json['ownerEmployeeId']),
      ownerEmployeeName: _text(json['ownerEmployeeName']),
      status: (_text(json['status']) ?? 'UNKNOWN').toUpperCase(),
      orderedQty: _number(json['orderedQty']),
      acceptedQty: _number(json['acceptedQty']),
      remainingQty: _number(json['remainingQty']),
      registeredQty: _number(json['registeredQty']),
      items: _maps(
        json['items'],
      ).map(InboundExpectationItem.fromJson).toList(growable: false),
      allowedActions: _actions(json['allowedActions']),
      draftReceiptIds: _texts(json['draftReceiptIds']),
      pendingInspectionReceipts: _int(json['pendingInspectionReceipts']),
      openArrivalExceptions: _int(json['openArrivalExceptions']),
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
    this.suggestedWarehouseId,
    this.suggestedWarehouseName,
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

  /// 建议入库仓库（物料分析目标仓唯一时给出）：登记页预填并锁定，防止入错仓。
  final String? suggestedWarehouseId;
  final String? suggestedWarehouseName;
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
    this.goodsSeries,
    this.goodsStockPlace,
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

  /// 货品主档当前值：登记页库位号/系列文本框初值；保存后学习端点回写差异。
  final String? goodsSeries;
  final String? goodsStockPlace;
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
    this.priceMasked = false,
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

  /// 价格族字段已对当前用户脱敏（仓库视角无收货单价格权限时单价/金额为 null；V302）。
  final bool priceMasked;

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
  bool get canStockIn =>
      status == 'RECEIPT_ADJUSTED' && acceptedQty > 0 && version > 0;

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
      priceMasked: json['priceMasked'] == true,
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

/// 到货登记一步完成（登记 + 送检审核）的结果。
enum WarehouseArrivalRegistrationOutcome {
  /// 已审核并转品质部待检（IQC），合格后等待仓库确认实物入库。
  submittedForInspection,

  /// 实到超过财务批准量：未入库、未立应付，已隔离等待财务定案。
  excessQuarantined;

  static WarehouseArrivalRegistrationOutcome fromName(String? value) =>
      value == 'EXCESS_QUARANTINED'
      ? excessQuarantined
      : submittedForInspection;
}

class WarehouseArrivalRegistration {
  const WarehouseArrivalRegistration({
    required this.outcome,
    this.receiptId,
    this.receiptBillNo,
    this.exceptionId,
  });

  final WarehouseArrivalRegistrationOutcome outcome;
  final String? receiptId;
  final String? receiptBillNo;
  final String? exceptionId;

  factory WarehouseArrivalRegistration.fromJson(Map<String, dynamic> json) {
    return WarehouseArrivalRegistration(
      outcome: WarehouseArrivalRegistrationOutcome.fromName(
        _text(json['outcome']),
      ),
      receiptId: _text(json['receiptId']),
      receiptBillNo: _text(json['receiptBillNo']),
      exceptionId: _text(json['exceptionId']),
    );
  }
}

/// 预计到货「批量继续送检」结果：逐张收货单送检结果（alreadyCompleted = 同幂等键
/// 重试时该单已处理过，按既有事实安全重放）。
class WarehouseArrivalBatchCompleteResult {
  const WarehouseArrivalBatchCompleteResult({
    required this.processedCount,
    required this.items,
  });

  final int processedCount;
  final List<WarehouseArrivalBatchCompleteItem> items;

  factory WarehouseArrivalBatchCompleteResult.fromJson(
    Map<String, dynamic> json,
  ) => WarehouseArrivalBatchCompleteResult(
    processedCount: _integer(json['processedCount']) ?? 0,
    items: _maps(
      json['items'],
    ).map(WarehouseArrivalBatchCompleteItem.fromJson).toList(growable: false),
  );
}

class WarehouseArrivalBatchCompleteItem {
  const WarehouseArrivalBatchCompleteItem({
    required this.receiptId,
    this.receiptBillNo,
    required this.outcome,
    this.exceptionId,
    this.alreadyCompleted = false,
  });

  final String receiptId;
  final String? receiptBillNo;
  final WarehouseArrivalRegistrationOutcome outcome;
  final String? exceptionId;
  final bool alreadyCompleted;

  factory WarehouseArrivalBatchCompleteItem.fromJson(
    Map<String, dynamic> json,
  ) => WarehouseArrivalBatchCompleteItem(
    receiptId: _text(json['receiptId']) ?? '',
    receiptBillNo: _text(json['receiptBillNo']),
    outcome: WarehouseArrivalRegistrationOutcome.fromName(
      _text(json['outcome']),
    ),
    exceptionId: _text(json['exceptionId']),
    alreadyCompleted: json['alreadyCompleted'] as bool? ?? false,
  );
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

int _int(Object? value) => _integer(value) ?? 0;

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

List<String> _texts(Object? value) {
  if (value is! List) return const <String>[];
  return value.map(_text).whereType<String>().toList(growable: false);
}
