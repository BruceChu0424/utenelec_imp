// 财务订货审批任务模型。
//
// V328/ADR-027 起：共享队列使用 view，批准/驳回按 approve/reject 独立授权，
// 不再单点指定负责人。后端演进期间允许常见字段别名；但关键身份字段
// （orderId）缺失时前端保持 fail-closed，不猜测可办理对象。

enum FinanceProcurementOrderType { purchase, subcontract, unknown }

FinanceProcurementOrderType financeProcurementOrderTypeFrom(Object? value) {
  final normalized = _string(value)?.toUpperCase().replaceAll('-', '_');
  return switch (normalized) {
    'PURCHASE' ||
    'PURCHASE_ORDER' ||
    'PROCUREMENT' ||
    'PROCUREMENT_ORDER' => FinanceProcurementOrderType.purchase,
    'SUBCONTRACT' ||
    'SUBCONTRACT_ORDER' ||
    'OUTSOURCE' ||
    'OUTSOURCE_ORDER' ||
    'OUTSOURCING' => FinanceProcurementOrderType.subcontract,
    _ => FinanceProcurementOrderType.unknown,
  };
}

class FinanceProcurementApprovalTask {
  const FinanceProcurementApprovalTask({
    required this.caseId,
    required this.orderId,
    required this.orderType,
    required this.billNo,
    this.supplierName,
    this.warehouseName,
    this.submittedByName,
    this.submittedByEmployeeId,
    this.amount,
    this.currencyName,
    this.submittedAt,
    this.expectedDate,
    this.attempt,
    this.sourceApplicationCount,
    this.lineCount,
    this.status,
    this.version,
    this.allowedActions = const <String>{},
    this.changeCount = 0,
  });

  final String caseId;
  final String orderId;
  final FinanceProcurementOrderType orderType;
  final String billNo;
  final String? supplierName;
  final String? warehouseName;
  final String? submittedByName;
  final String? submittedByEmployeeId;

  /// 金额保留服务端字符串，避免大额或小数在客户端转换时丢精度。
  final String? amount;
  final String? currencyName;
  final String? submittedAt;
  final String? expectedDate;
  final int? attempt;
  final int? sourceApplicationCount;
  final int? lineCount;
  final String? status;
  final int? version;
  final Set<String> allowedActions;

  /// 批准后改量次数（末字段；旧后端未推时容错为 0）：>0 表示该单在财务批准
  /// 后被改过数量，正在等待财务按修改清单复核。
  final int changeCount;

  bool get canOpen =>
      caseId.isNotEmpty &&
      orderId.isNotEmpty &&
      orderType != FinanceProcurementOrderType.unknown;

  String get orderTypeLabel => switch (orderType) {
    FinanceProcurementOrderType.purchase => '采购订货',
    FinanceProcurementOrderType.subcontract => '委外订货',
    FinanceProcurementOrderType.unknown => '未知订货类型',
  };

  String? get detailRoute => switch (orderType) {
    FinanceProcurementOrderType.purchase when orderId.isNotEmpty =>
      '/purchase/orders/${Uri.encodeComponent(orderId)}',
    FinanceProcurementOrderType.subcontract when orderId.isNotEmpty =>
      '/subcontract/orders/${Uri.encodeComponent(orderId)}',
    _ => null,
  };

  FinanceProcurementDecisionItem? get decisionItem {
    final currentVersion = version;
    if (!canOpen || currentVersion == null || currentVersion < 1) return null;
    return FinanceProcurementDecisionItem(
      caseId: caseId,
      expectedVersion: currentVersion,
    );
  }

  factory FinanceProcurementApprovalTask.fromJson(Map<String, dynamic> json) {
    final order = _map(json['order']) ?? _map(json['document']);
    final submitter = _map(json['submitter']) ?? _map(json['submittedBy']);
    final supplier = _map(json['supplier']);
    final currency = _map(json['currency']);
    final orderId = _firstString([
      json['orderId'],
      json['documentId'],
      json['businessId'],
      order?['id'],
    ]);
    return FinanceProcurementApprovalTask(
      caseId: _string(json['caseId']) ?? '',
      orderId: orderId,
      orderType: financeProcurementOrderTypeFrom(
        json['orderType'] ??
            json['documentType'] ??
            json['businessType'] ??
            order?['type'],
      ),
      billNo: _firstString([
        json['orderNo'],
        json['orderBillNo'],
        json['billNo'],
        json['documentNo'],
        order?['number'],
        order?['billNo'],
      ], fallback: '未生成单号'),
      supplierName: _firstNullableString([
        json['supplierName'],
        supplier?['name'],
        order?['supplierName'],
      ]),
      warehouseName: _string(json['warehouseName']),
      submittedByName: _firstNullableString([
        json['submitterName'],
        json['submittedByName'],
        json['purchaserName'],
        submitter?['name'],
      ]),
      submittedByEmployeeId: _string(json['submittedByEmployeeId']),
      amount: _firstNullableString([
        json['amount'],
        json['totalAmount'],
        json['totalLocal'],
        order?['amount'],
        order?['totalLocal'],
      ]),
      currencyName: _firstNullableString([
        json['currencyName'],
        json['currencyCode'],
        currency?['name'],
        currency?['code'],
      ]),
      submittedAt: _firstNullableString([
        json['submittedAt'],
        json['createdAt'],
        json['assignedAt'],
      ]),
      expectedDate: _firstNullableString([
        json['expectedDate'],
        json['deliverDate'],
        json['expectedDeliveryDate'],
        order?['deliverDate'],
      ]),
      attempt: _firstInt([json['attempt']]),
      sourceApplicationCount: _firstInt([
        json['sourceApplicationCount'],
        json['applicationCount'],
        json['requestCount'],
      ]),
      lineCount: _firstInt([json['lineCount'], json['itemCount']]),
      status: _firstNullableString([
        json['status'],
        json['taskStatus'],
        order?['status'],
      ]),
      version: _firstInt([json['version']]),
      allowedActions: _stringSet(json['allowedActions']),
      changeCount: _firstInt([json['changeCount']]) ?? 0,
    );
  }
}

class FinanceProcurementDecisionItem {
  const FinanceProcurementDecisionItem({
    required this.caseId,
    required this.expectedVersion,
    this.expectedClaimId,
  });

  final String caseId;
  final int expectedVersion;
  final String? expectedClaimId;

  FinanceProcurementDecisionItem withClaimId(String claimId) =>
      FinanceProcurementDecisionItem(
        caseId: caseId,
        expectedVersion: expectedVersion,
        expectedClaimId: claimId,
      );

  Map<String, dynamic> toJson() => {
    'caseId': caseId,
    'expectedVersion': expectedVersion,
    'expectedClaimId': ?expectedClaimId,
  };
}

/// 审核详情（财务专用视图，与采购/委外业务详情页分离）。
///
/// 投影自审批 case：订单头商业事实 + 供应商应付快照 + 明细 + 逐轮审批历史；
/// allowedActions 仅在 case 仍为 PENDING 时由服务端按当前审核员实时资格返回。
class FinanceProcurementApprovalReview {
  const FinanceProcurementApprovalReview({
    required this.caseId,
    required this.orderId,
    required this.orderType,
    required this.billNo,
    required this.status,
    required this.attempt,
    required this.version,
    this.allowedActions = const <String>{},
    this.submittedByName,
    this.submittedAt,
    this.billDate,
    this.supplierName,
    this.supplierCode,
    this.warehouseName,
    this.currencyName,
    this.exchangeRate,
    this.settlementMethodName,
    this.taxRate,
    this.purchaserName,
    this.makerName,
    this.deliverDate,
    this.remark,
    this.totalOriginal,
    this.totalLocal,
    this.supplierApBalance,
    this.sourceApplicationCount = 0,
    this.qtyChanges = const <FinanceProcurementQtyChange>[],
    this.items = const <FinanceProcurementReviewLine>[],
    this.history = const <FinanceProcurementReviewHistoryEntry>[],
  });

  final String caseId;
  final String orderId;
  final FinanceProcurementOrderType orderType;
  final String billNo;
  final String? status;
  final int? attempt;
  final int? version;
  final Set<String> allowedActions;
  final String? submittedByName;
  final String? submittedAt;
  final String? billDate;
  final String? supplierName;
  final String? supplierCode;
  final String? warehouseName;
  final String? currencyName;
  final String? exchangeRate;
  final String? settlementMethodName;
  final String? taxRate;
  final String? purchaserName;
  final String? makerName;
  final String? deliverDate;
  final String? remark;
  final String? totalOriginal;
  final String? totalLocal;
  final String? supplierApBalance;
  final int sourceApplicationCount;

  /// 批准后改量清单（服务端字段位于 items 之前）：为空表示本单未被改过数量。
  final List<FinanceProcurementQtyChange> qtyChanges;
  final List<FinanceProcurementReviewLine> items;
  final List<FinanceProcurementReviewHistoryEntry> history;

  bool get isPending => status == null || status == 'PENDING';

  String get orderTypeLabel => switch (orderType) {
    FinanceProcurementOrderType.purchase => '采购订货',
    FinanceProcurementOrderType.subcontract => '委外订货',
    FinanceProcurementOrderType.unknown => '未知订货类型',
  };

  FinanceProcurementDecisionItem? get decisionItem {
    final currentVersion = version;
    if (caseId.isEmpty ||
        orderId.isEmpty ||
        orderType == FinanceProcurementOrderType.unknown ||
        currentVersion == null ||
        currentVersion < 1) {
      return null;
    }
    return FinanceProcurementDecisionItem(
      caseId: caseId,
      expectedVersion: currentVersion,
    );
  }

  factory FinanceProcurementApprovalReview.fromJson(Map<String, dynamic> json) {
    return FinanceProcurementApprovalReview(
      caseId: _string(json['caseId']) ?? '',
      orderId: _string(json['orderId']) ?? '',
      orderType: financeProcurementOrderTypeFrom(json['orderType']),
      billNo: _firstString([json['billNo']], fallback: '未生成单号'),
      status: _string(json['status']),
      attempt: _firstInt([json['attempt']]),
      version: _firstInt([json['version']]),
      allowedActions: _stringSet(json['allowedActions']),
      submittedByName: _firstNullableString([
        json['submittedByName'],
        json['submitterName'],
      ]),
      submittedAt: _firstNullableString([json['submittedAt']]),
      billDate: _firstNullableString([json['billDate']]),
      supplierName: _firstNullableString([json['supplierName']]),
      supplierCode: _firstNullableString([json['supplierCode']]),
      warehouseName: _firstNullableString([json['warehouseName']]),
      currencyName: _firstNullableString([json['currencyName']]),
      exchangeRate: _firstNullableString([json['exchangeRate']]),
      settlementMethodName: _firstNullableString([
        json['settlementMethodName'],
      ]),
      taxRate: _firstNullableString([json['taxRate']]),
      purchaserName: _firstNullableString([json['purchaserName']]),
      makerName: _firstNullableString([json['makerName']]),
      deliverDate: _firstNullableString([json['deliverDate']]),
      remark: _string(json['remark']),
      totalOriginal: _firstNullableString([json['totalOriginal']]),
      totalLocal: _firstNullableString([json['totalLocal']]),
      supplierApBalance: _firstNullableString([json['supplierApBalance']]),
      sourceApplicationCount: _firstInt([json['sourceApplicationCount']]) ?? 0,
      qtyChanges: [
        for (final change in (json['qtyChanges'] as List? ?? const <dynamic>[]))
          if (change is Map)
            FinanceProcurementQtyChange.fromJson(
              change.cast<String, dynamic>(),
            ),
      ],
      items: [
        for (final item in (json['items'] as List? ?? const <dynamic>[]))
          if (item is Map)
            FinanceProcurementReviewLine.fromJson(item.cast<String, dynamic>()),
      ],
      history: [
        for (final entry in (json['history'] as List? ?? const <dynamic>[]))
          if (entry is Map)
            FinanceProcurementReviewHistoryEntry.fromJson(
              entry.cast<String, dynamic>(),
            ),
      ],
    );
  }
}

class FinanceProcurementReviewLine {
  const FinanceProcurementReviewLine({
    required this.lineNo,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitId,
    this.unitName,
    this.unitRate,
    this.qty,
    this.price,
    this.amountOriginal,
    this.amountLocal,
    this.deliverDate,
    this.sourceDocNo,
  });

  final int lineNo;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;

  /// 单位主键：「合计数量」按它分组，不同单位的数量绝不相加。
  final String? unitId;
  final String? unitName;
  final String? unitRate;
  final String? qty;
  final String? price;
  final String? amountOriginal;
  final String? amountLocal;
  final String? deliverDate;
  final String? sourceDocNo;

  factory FinanceProcurementReviewLine.fromJson(Map<String, dynamic> json) {
    return FinanceProcurementReviewLine(
      lineNo: _firstInt([json['lineNo']]) ?? 0,
      goodsCode: _string(json['goodsCode']),
      goodsName: _string(json['goodsName']),
      colorName: _string(json['colorName']),
      unitId: _string(json['unitId']),
      unitName: _string(json['unitName']),
      unitRate: _firstNullableString([json['unitRate']]),
      qty: _firstNullableString([json['qty']]),
      price: _firstNullableString([json['price']]),
      amountOriginal: _firstNullableString([json['amountOriginal']]),
      amountLocal: _firstNullableString([json['amountLocal']]),
      deliverDate: _firstNullableString([json['deliverDate']]),
      sourceDocNo: _string(json['sourceDocNo']),
    );
  }
}

/// 修改清单行（批准后改量）：货品 + 以前数量 → 现在数量 + 修改人/时间。
/// 数量保留服务端字符串口径，避免小数转换丢精度。
class FinanceProcurementQtyChange {
  const FinanceProcurementQtyChange({
    required this.orderItemId,
    this.lineNo,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.oldQty,
    this.newQty,
    this.changedByName,
    this.changedAt,
  });

  final String orderItemId;
  final int? lineNo;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final String? oldQty;
  final String? newQty;
  final String? changedByName;
  final String? changedAt;

  factory FinanceProcurementQtyChange.fromJson(Map<String, dynamic> json) {
    return FinanceProcurementQtyChange(
      orderItemId: _string(json['orderItemId']) ?? '',
      lineNo: _firstInt([json['lineNo']]),
      goodsCode: _string(json['goodsCode']),
      goodsName: _string(json['goodsName']),
      colorName: _string(json['colorName']),
      unitName: _string(json['unitName']),
      oldQty: _firstNullableString([json['oldQty']]),
      newQty: _firstNullableString([json['newQty']]),
      changedByName: _string(json['changedByName']),
      changedAt: _string(json['changedAt']),
    );
  }
}

class FinanceProcurementReviewHistoryEntry {
  const FinanceProcurementReviewHistoryEntry({
    required this.attempt,
    required this.eventType,
    this.actorName,
    this.occurredAt,
    this.reason,
  });

  final int attempt;
  final String eventType;
  final String? actorName;
  final String? occurredAt;
  final String? reason;

  String get eventLabel => switch (eventType.toUpperCase()) {
    'SUBMITTED' => '提交财务审核',
    'APPROVED' => '财务通过',
    'REJECTED' => '财务驳回',
    'CANCELED' => '提交人撤回',
    'REASSIGNED' => '改派',
    _ => eventType,
  };

  factory FinanceProcurementReviewHistoryEntry.fromJson(
    Map<String, dynamic> json,
  ) {
    return FinanceProcurementReviewHistoryEntry(
      attempt: _firstInt([json['attempt']]) ?? 0,
      eventType: _string(json['eventType']) ?? '',
      actorName: _string(json['actorName']),
      occurredAt: _firstNullableString([json['occurredAt'], json['createdAt']]),
      reason: _string(json['reason']),
    );
  }
}

class FinanceProcurementApprovalPage {
  const FinanceProcurementApprovalPage({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<FinanceProcurementApprovalTask> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory FinanceProcurementApprovalPage.fromJson(Map<String, dynamic> json) {
    final nested = _map(json['data']);
    final root = nested ?? json;
    final rawItems = _firstList([
      root['items'],
      root['tasks'],
      root['content'],
      root['records'],
    ]);
    final items = rawItems
        .whereType<Map<Object?, Object?>>()
        .map(
          (item) => FinanceProcurementApprovalTask.fromJson(
            item.cast<String, dynamic>(),
          ),
        )
        .toList(growable: false);
    final page =
        _firstInt([root['page'], root['pageNumber'], root['number']]) ?? 1;
    final size =
        _firstInt([root['size'], root['pageSize'], root['numberOfElements']]) ??
        items.length;
    final total =
        _firstInt([root['total'], root['totalElements'], root['count']]) ??
        items.length;
    final totalPages =
        _firstInt([root['totalPages'], root['pageCount']]) ??
        (size <= 0 ? 1 : ((total + size - 1) ~/ size).clamp(1, 1 << 30));
    return FinanceProcurementApprovalPage(
      items: items,
      page: page < 1 ? 1 : page,
      size: size,
      total: total < 0 ? 0 : total,
      totalPages: totalPages < 1 ? 1 : totalPages,
    );
  }
}

Map<String, dynamic>? _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return null;
}

List<dynamic> _firstList(Iterable<Object?> values) {
  for (final value in values) {
    if (value is List) return value;
  }
  return const <dynamic>[];
}

String? _string(Object? value) {
  if (value == null) return null;
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

String _firstString(Iterable<Object?> values, {String fallback = ''}) {
  return _firstNullableString(values) ?? fallback;
}

String? _firstNullableString(Iterable<Object?> values) {
  for (final value in values) {
    final result = _string(value);
    if (result != null) return result;
  }
  return null;
}

int? _firstInt(Iterable<Object?> values) {
  for (final value in values) {
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return null;
}

Set<String> _stringSet(Object? value) {
  if (value is! List) return const <String>{};
  return value
      .map(_string)
      .whereType<String>()
      .map((item) => item.toUpperCase())
      .toSet();
}
