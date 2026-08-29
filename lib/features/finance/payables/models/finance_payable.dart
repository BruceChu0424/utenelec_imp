String? _decimalText(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is num) return value.toString();
  return value.toString();
}

int _intValue(Object? value, [int fallback = 0]) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

Map<String, dynamic>? _mapValue(Object? value) {
  if (value is! Map) return null;
  return value.cast<String, dynamic>();
}

String? _firstText(Iterable<Object?> values) {
  for (final value in values) {
    final text = value?.toString().trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return null;
}

String financePayableBusinessTypeLabel(String? value) =>
    switch (value?.toUpperCase()) {
      'PURCHASE' => '采购',
      'SUBCONTRACT' => '委外',
      _ => value?.trim().isNotEmpty == true ? value! : '—',
    };

String financePayableSourceTypeLabel(String? value) =>
    switch (value?.toUpperCase()) {
      'PURCHASE_RECEIPT' => '采购收货',
      'PURCHASE_RETURN' => '采购退货',
      'SUBCONTRACT_RECEIPT' => '委外进仓',
      'SUBCONTRACT_RETURN' => '委外退货',
      'SUBCONTRACT_WASTE' || 'SUBCONTRACT_WASTE_DEDUCTION' => '委外损耗扣款',
      'SUBCONTRACT_LOSS_OFFSET' => '委外索赔抵销',
      'OPENING_BALANCE' => '期初应付',
      'MANUAL' || 'MANUAL_AP' => '手工应付',
      _ => value?.trim().isNotEmpty == true ? value! : '—',
    };

String financePayableStatusLabel(String? value) =>
    switch (value?.toUpperCase()) {
      'OPEN' => '未付',
      'PARTIAL' => '部分付款',
      'SETTLED' => '已结清',
      'OVERDUE' => '已逾期',
      'CREDIT' => '贷项/负应付',
      'UNDATED' => '未定到期日',
      'PREPAYMENT' => '供应商预付款',
      'CLAIM_CREDIT' => '委外索赔贷项',
      'FROZEN' => '已冻结',
      _ => value?.trim().isNotEmpty == true ? value! : '—',
    };

String financePayableOpenItemKindLabel(String? value) =>
    switch (value?.toUpperCase()) {
      'PAYABLE' => '正应付',
      'CREDIT' => '供应商贷项',
      'CLAIM_CREDIT' => '委外索赔贷项',
      'PREPAYMENT' => '供应商预付款',
      _ => value?.trim().isNotEmpty == true ? value! : '—',
    };

class FinancePayablesSummary {
  const FinancePayablesSummary({
    this.payableLocal,
    this.paidLocal,
    this.settledBookLocal,
    this.exchangeDifferenceLocal,
    this.offsetLocal,
    this.outstandingLocal,
    this.overdueLocal,
    this.dueThisMonthLocal,
    this.creditLocal,
    this.prepaymentLocal,
    this.pendingLossCases = 0,
  });

  final String? payableLocal;
  final String? paidLocal;
  final String? settledBookLocal;
  final String? exchangeDifferenceLocal;
  final String? offsetLocal;
  final String? outstandingLocal;
  final String? overdueLocal;
  final String? dueThisMonthLocal;
  final String? creditLocal;
  final String? prepaymentLocal;
  final int pendingLossCases;

  @Deprecated('Use offsetLocal')
  String? get writeOffLocal => offsetLocal;

  @Deprecated('Use dueThisMonthLocal')
  String? get dueLocal => dueThisMonthLocal;

  factory FinancePayablesSummary.fromJson(Map<String, dynamic>? json) {
    final source = json ?? const <String, dynamic>{};
    return FinancePayablesSummary(
      payableLocal: _decimalText(
        source['payableLocal'] ?? source['amountPayableLocal'],
      ),
      paidLocal: _decimalText(source['paidLocal'] ?? source['amountPaidLocal']),
      settledBookLocal: _decimalText(
        source['settledBookLocal'] ??
            source['settledLocal'] ??
            source['amountSettledLocal'],
      ),
      exchangeDifferenceLocal: _decimalText(
        source['exchangeDifferenceLocal'] ?? source['exchangeDiffLocal'],
      ),
      offsetLocal: _decimalText(
        source['offsetLocal'] ??
            source['writeOffLocal'] ??
            source['amountWriteOffLocal'],
      ),
      outstandingLocal: _decimalText(
        source['outstandingLocal'] ?? source['amountBalanceLocal'],
      ),
      overdueLocal: _decimalText(
        source['overdueLocal'] ?? source['amountOverdueLocal'],
      ),
      dueThisMonthLocal: _decimalText(
        source['dueThisMonthLocal'] ??
            source['dueLocal'] ??
            source['dueThisPeriodLocal'],
      ),
      creditLocal: _decimalText(source['creditLocal']),
      prepaymentLocal: _decimalText(source['prepaymentLocal']),
      pendingLossCases: _intValue(source['pendingLossCases']),
    );
  }
}

class FinancePayableItem {
  const FinancePayableItem({
    required this.id,
    this.version,
    this.businessType,
    this.openItemKind,
    this.sourceDocType,
    this.sourceDocId,
    this.sourceDocNo,
    this.supplierId,
    this.supplierCode,
    this.supplierName,
    this.billDate,
    this.dueDate,
    this.settlementPeriod,
    this.settlementMethodId,
    this.settlementMethodCode,
    this.settlementMethodName,
    this.creditDays,
    this.currencyId,
    this.currencyCode,
    this.currencyName,
    this.bookingRate,
    this.grossOriginal,
    this.grossLocal,
    this.paidOriginal,
    this.paidLocal,
    this.offsetOriginal,
    this.offsetLocal,
    this.outstandingOriginal,
    this.outstandingLocal,
    this.status,
    this.overdueDays,
    this.remark,
  });

  final String id;
  final int? version;
  final String? businessType;
  final String? openItemKind;
  final String? sourceDocType;
  final String? sourceDocId;
  final String? sourceDocNo;
  final String? supplierId;
  final String? supplierCode;
  final String? supplierName;
  final String? billDate;
  final String? dueDate;
  final String? settlementPeriod;
  final String? settlementMethodId;
  final String? settlementMethodCode;
  final String? settlementMethodName;
  final int? creditDays;
  final String? currencyId;
  final String? currencyCode;
  final String? currencyName;
  final String? bookingRate;

  /// 金额保持服务端十进制字符串，不在客户端用 double 重新核算。
  final String? grossOriginal;
  final String? grossLocal;
  final String? paidOriginal;
  final String? paidLocal;
  final String? offsetOriginal;
  final String? offsetLocal;
  final String? outstandingOriginal;
  final String? outstandingLocal;
  final String? status;
  final int? overdueDays;
  final String? remark;

  String get businessTypeLabel => financePayableBusinessTypeLabel(businessType);
  String get sourceTypeLabel => financePayableSourceTypeLabel(sourceDocType);
  String get statusLabel => financePayableStatusLabel(status);
  String get openItemKindLabel => financePayableOpenItemKindLabel(openItemKind);

  @Deprecated('Use grossOriginal')
  String? get payableOriginal => grossOriginal;

  @Deprecated('Use offsetOriginal')
  String? get writeOffOriginal => offsetOriginal;

  factory FinancePayableItem.fromJson(Map<String, dynamic> json) {
    final supplier = _mapValue(json['supplier']);
    final currency = _mapValue(json['currency']);
    final settlement = _mapValue(json['settlementMethod']);
    return FinancePayableItem(
      id: json['id']?.toString() ?? '',
      version: json['version'] == null ? null : _intValue(json['version']),
      businessType: json['businessType']?.toString(),
      openItemKind: json['openItemKind']?.toString(),
      sourceDocType: json['sourceDocType']?.toString(),
      sourceDocId: json['sourceDocId']?.toString(),
      sourceDocNo: _firstText([json['sourceDocNo'], json['billNo']]),
      supplierId: _firstText([json['supplierId'], supplier?['id']]),
      supplierCode: _firstText([json['supplierCode'], supplier?['code']]),
      supplierName: _firstText([json['supplierName'], supplier?['name']]),
      billDate: json['billDate']?.toString(),
      dueDate: json['dueDate']?.toString(),
      settlementPeriod: _firstText([json['settlementPeriod']]),
      settlementMethodId: _firstText([
        json['settlementMethodId'],
        settlement?['id'],
      ]),
      settlementMethodCode: _firstText([
        json['settlementMethodCode'],
        settlement?['code'],
      ]),
      settlementMethodName: _firstText([
        json['settlementMethodName'],
        settlement?['name'],
      ]),
      creditDays: json['creditDays'] == null
          ? null
          : _intValue(json['creditDays']),
      currencyId: _firstText([json['currencyId'], currency?['id']]),
      currencyCode: _firstText([json['currencyCode'], currency?['code']]),
      currencyName: _firstText([json['currencyName'], currency?['name']]),
      bookingRate: _decimalText(json['bookingRate'] ?? json['exchangeRate']),
      grossOriginal: _decimalText(
        json['grossOriginal'] ??
            json['payableOriginal'] ??
            json['amountPayableOriginal'] ??
            json['amountOriginal'],
      ),
      grossLocal: _decimalText(
        json['grossLocal'] ??
            json['payableLocal'] ??
            json['amountOriginalLocal'],
      ),
      paidOriginal: _decimalText(
        json['paidOriginal'] ??
            json['amountPaidOriginal'] ??
            json['amountReceivedOriginal'],
      ),
      paidLocal: _decimalText(
        json['paidLocal'] ??
            json['amountPaidLocal'] ??
            json['amountReceivedLocal'],
      ),
      offsetOriginal: _decimalText(
        json['offsetOriginal'] ??
            json['writeOffOriginal'] ??
            json['amountWriteOffOriginal'],
      ),
      offsetLocal: _decimalText(
        json['offsetLocal'] ??
            json['writeOffLocal'] ??
            json['amountWriteOffLocal'],
      ),
      outstandingOriginal: _decimalText(
        json['outstandingOriginal'] ?? json['amountBalanceOriginal'],
      ),
      outstandingLocal: _decimalText(
        json['outstandingLocal'] ?? json['amountBalanceLocal'],
      ),
      status: json['status']?.toString(),
      overdueDays: json['overdueDays'] == null
          ? null
          : _intValue(json['overdueDays']),
      remark: _firstText([json['remark']]),
    );
  }
}

class FinancePayablesResult {
  const FinancePayablesResult({
    required this.summary,
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final FinancePayablesSummary summary;
  final List<FinancePayableItem> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory FinancePayablesResult.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List? ?? const <Object?>[];
    final page = _intValue(json['page'], 1);
    final size = _intValue(json['size'], 30);
    final total = _intValue(json['total']);
    final suppliedTotalPages = _intValue(json['totalPages']);
    final calculatedTotalPages = size <= 0 ? 1 : (total / size).ceil();
    return FinancePayablesResult(
      summary: FinancePayablesSummary.fromJson(_mapValue(json['summary'])),
      items: [
        for (final item in rawItems)
          if (item is Map)
            FinancePayableItem.fromJson(item.cast<String, dynamic>()),
      ],
      page: page <= 0 ? 1 : page,
      size: size <= 0 ? 30 : size,
      total: total < 0 ? 0 : total,
      totalPages: suppliedTotalPages > 0
          ? suppliedTotalPages
          : (calculatedTotalPages > 0 ? calculatedTotalPages : 1),
    );
  }
}
