// 财务订货审批任务模型。
//
// V229/ADR-027 起：审批人为「财务部门持 finance_order_approval:review 的审核组」，
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
    );
  }
}

class FinanceProcurementDecisionItem {
  const FinanceProcurementDecisionItem({
    required this.caseId,
    required this.expectedVersion,
  });

  final String caseId;
  final int expectedVersion;

  Map<String, dynamic> toJson() => {
    'caseId': caseId,
    'expectedVersion': expectedVersion,
  };
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
