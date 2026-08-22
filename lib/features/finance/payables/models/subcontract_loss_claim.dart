BigInt? financeDecimalUnits(String? raw, {int scale = 4}) {
  final value = raw?.trim();
  if (value == null || value.isEmpty || scale < 0) return null;
  final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(value);
  if (match == null) return null;
  final sign = match.group(1) == '-' ? BigInt.from(-1) : BigInt.one;
  final whole = BigInt.parse(match.group(2)!);
  var fraction = match.group(3) ?? '';
  if (fraction.length > scale) {
    if (fraction.substring(scale).contains(RegExp('[1-9]'))) return null;
    fraction = fraction.substring(0, scale);
  }
  fraction = fraction.padRight(scale, '0');
  final factor = BigInt.from(10).pow(scale);
  final fractionUnits = fraction.isEmpty ? BigInt.zero : BigInt.parse(fraction);
  return sign * (whole * factor + fractionUnits);
}

String subcontractLossClaimStatusLabel(String? value) =>
    switch (value?.toUpperCase()) {
      'OPEN' => '待处理',
      'ACCEPTED' => '已接受',
      'DISPUTED' => '争议中',
      'AWAITING_FULFILLMENT' => '等待补偿履约',
      'RESOLVED' => '已解决',
      'WAIVED' => '已豁免',
      'CANCELED' => '已取消',
      'REVERSED' => '已反转',
      _ => value?.trim().isNotEmpty == true ? value! : '—',
    };

abstract final class SubcontractLossResolutionType {
  static const companyBear = 'COMPANY_BEAR';
  static const servicePriceReduction = 'SERVICE_PRICE_REDUCTION';
  static const cashCompensation = 'CASH_COMPENSATION';
  static const apOffset = 'AP_OFFSET';
  static const materialReplacement = 'MATERIAL_REPLACEMENT';
  static const outputReplacement = 'OUTPUT_REPLACEMENT';
  static const scrapReturn = 'SCRAP_RETURN';
  static const waiver = 'WAIVER';

  static const values = <String>[
    companyBear,
    servicePriceReduction,
    cashCompensation,
    apOffset,
    materialReplacement,
    outputReplacement,
    scrapReturn,
    waiver,
  ];

  static const moneyTypes = <String>{
    servicePriceReduction,
    cashCompensation,
    apOffset,
  };

  /// 只有应付抵销需要逐笔选择正应付；服务端同口径（其余类型带目标直接 409）。
  static const offsetTypes = <String>{apOffset};

  static const physicalTypes = <String>{
    materialReplacement,
    outputReplacement,
    scrapReturn,
  };
}

String subcontractLossResolutionTypeLabel(String? value) => switch (value) {
  SubcontractLossResolutionType.companyBear => '公司承担',
  SubcontractLossResolutionType.servicePriceReduction => '加工费折让',
  SubcontractLossResolutionType.cashCompensation => '现金赔偿',
  SubcontractLossResolutionType.apOffset => '抵销应付',
  SubcontractLossResolutionType.materialReplacement => '补回材料',
  SubcontractLossResolutionType.outputReplacement => '补合格品/免费重作',
  SubcontractLossResolutionType.scrapReturn => '返还废料',
  SubcontractLossResolutionType.waiver => '内部豁免',
  _ => value?.trim().isNotEmpty == true ? value! : '—',
};

String subcontractLossResolutionStatusLabel(String? value) =>
    switch (value?.toUpperCase()) {
      'PENDING' => '待履约',
      'FULFILLED' => '已履约',
      'REVERSED' => '已反转',
      _ => value?.trim().isNotEmpty == true ? value! : '—',
    };

String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int _intValue(Object? value, [int fallback = 0]) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

class SubcontractLossClaimSummary {
  const SubcontractLossClaimSummary({
    required this.id,
    required this.wasteId,
    this.wasteBillNo,
    required this.supplierId,
    this.supplierCode,
    this.supplierName,
    this.status,
    this.actualLossQty,
    this.allowedLossQty,
    this.excessLossQty,
    this.lossBookValueLocal,
    this.claimAmountLocal,
    required this.version,
    this.createdAt,
  });

  final String id;
  final String wasteId;
  final String? wasteBillNo;
  final String supplierId;
  final String? supplierCode;
  final String? supplierName;
  final String? status;
  final String? actualLossQty;
  final String? allowedLossQty;
  final String? excessLossQty;
  final String? lossBookValueLocal;
  final String? claimAmountLocal;
  final int version;
  final String? createdAt;

  String get statusLabel => subcontractLossClaimStatusLabel(status);
  bool get canReview => status == 'OPEN' || status == 'DISPUTED';
  bool get canReverse =>
      status != 'OPEN' && status != 'CANCELED' && status != 'REVERSED';

  factory SubcontractLossClaimSummary.fromJson(Map<String, dynamic> json) =>
      SubcontractLossClaimSummary(
        id: json['id']?.toString() ?? '',
        wasteId: json['wasteId']?.toString() ?? '',
        wasteBillNo: _text(json['wasteBillNo']),
        supplierId: json['supplierId']?.toString() ?? '',
        supplierCode: _text(json['supplierCode']),
        supplierName: _text(json['supplierName']),
        status: _text(json['status']),
        actualLossQty: _text(json['actualLossQty']),
        allowedLossQty: _text(json['allowedLossQty']),
        excessLossQty: _text(json['excessLossQty']),
        lossBookValueLocal: _text(json['lossBookValueLocal']),
        claimAmountLocal: _text(json['claimAmountLocal']),
        version: _intValue(json['version']),
        createdAt: _text(json['createdAt']),
      );
}

class SubcontractLossClaimLine {
  const SubcontractLossClaimLine({
    required this.id,
    this.wasteItemId,
    this.materialIssueItemId,
    this.orderItemId,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.unitId,
    this.actualLossQty,
    this.allowedLossQty,
    this.excessLossQty,
    this.unitBookValueLocal,
    this.lossBookValueLocal,
    this.valuationStatus,
  });

  final String id;
  final String? wasteItemId;
  final String? materialIssueItemId;
  final String? orderItemId;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? unitId;
  final String? actualLossQty;
  final String? allowedLossQty;
  final String? excessLossQty;
  final String? unitBookValueLocal;
  final String? lossBookValueLocal;
  final String? valuationStatus;

  String get goodsLabel => [
    goodsCode,
    goodsName,
  ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');

  factory SubcontractLossClaimLine.fromJson(Map<String, dynamic> json) =>
      SubcontractLossClaimLine(
        id: json['id']?.toString() ?? '',
        wasteItemId: _text(json['wasteItemId']),
        materialIssueItemId: _text(json['materialIssueItemId']),
        orderItemId: _text(json['orderItemId']),
        goodsId: _text(json['goodsId']),
        goodsCode: _text(json['goodsCode']),
        goodsName: _text(json['goodsName']),
        colorId: _text(json['colorId']),
        unitId: _text(json['unitId']),
        actualLossQty: _text(json['actualLossQty']),
        allowedLossQty: _text(json['allowedLossQty']),
        excessLossQty: _text(json['excessLossQty']),
        unitBookValueLocal: _text(json['unitBookValueLocal']),
        lossBookValueLocal: _text(json['lossBookValueLocal']),
        valuationStatus: _text(json['valuationStatus']),
      );
}

class SubcontractLossResolution {
  const SubcontractLossResolution({
    required this.id,
    required this.caseLineId,
    this.type,
    this.quantity,
    this.amountLocal,
    this.dueDate,
    this.status,
    this.note,
    this.evidenceReference,
    this.fulfillmentDocType,
    this.fulfillmentDocId,
    this.fulfillmentDocNo,
    this.offsetLedgerId,
    this.fulfilledAt,
  });

  final String id;
  final String caseLineId;
  final String? type;
  final String? quantity;
  final String? amountLocal;
  final String? dueDate;
  final String? status;
  final String? note;
  final String? evidenceReference;
  final String? fulfillmentDocType;
  final String? fulfillmentDocId;
  final String? fulfillmentDocNo;
  final String? offsetLedgerId;
  final String? fulfilledAt;

  String get typeLabel => subcontractLossResolutionTypeLabel(type);
  String get statusLabel => subcontractLossResolutionStatusLabel(status);
  bool get isPending => status == 'PENDING';
  bool get isCashCompensation =>
      type == SubcontractLossResolutionType.cashCompensation;
  bool get isServicePriceReduction =>
      type == SubcontractLossResolutionType.servicePriceReduction;
  bool get usesDedicatedFinancialChain => isServicePriceReduction;
  bool get canReverseFulfillment =>
      status == 'FULFILLED' &&
      (isCashCompensation ||
          type == SubcontractLossResolutionType.materialReplacement ||
          type == SubcontractLossResolutionType.outputReplacement ||
          type == SubcontractLossResolutionType.scrapReturn);
  bool get requiresPhysicalDocument =>
      type == SubcontractLossResolutionType.outputReplacement ||
      type == SubcontractLossResolutionType.scrapReturn;

  factory SubcontractLossResolution.fromJson(Map<String, dynamic> json) =>
      SubcontractLossResolution(
        id: json['id']?.toString() ?? '',
        caseLineId: json['caseLineId']?.toString() ?? '',
        type: _text(json['type']),
        quantity: _text(json['quantity']),
        amountLocal: _text(json['amountLocal']),
        dueDate: _text(json['dueDate']),
        status: _text(json['status']),
        note: _text(json['note']),
        evidenceReference: _text(json['evidenceReference']),
        fulfillmentDocType: _text(json['fulfillmentDocType']),
        fulfillmentDocId: _text(json['fulfillmentDocId']),
        fulfillmentDocNo: _text(json['fulfillmentDocNo']),
        offsetLedgerId: _text(json['offsetLedgerId']),
        fulfilledAt: _text(json['fulfilledAt']),
      );
}

class SubcontractLossClaimEvent {
  const SubcontractLossClaimEvent({
    required this.id,
    this.type,
    this.actorUserId,
    this.reason,
    this.createdAt,
  });

  final String id;
  final String? type;
  final String? actorUserId;
  final String? reason;
  final String? createdAt;

  factory SubcontractLossClaimEvent.fromJson(Map<String, dynamic> json) =>
      SubcontractLossClaimEvent(
        id: json['id']?.toString() ?? '',
        type: _text(json['type']),
        actorUserId: _text(json['actorUserId']),
        reason: _text(json['reason']),
        createdAt: _text(json['createdAt']),
      );
}

class SubcontractLossClaimDetail {
  const SubcontractLossClaimDetail({
    required this.summary,
    required this.lines,
    required this.resolutions,
    required this.events,
  });

  final SubcontractLossClaimSummary summary;
  final List<SubcontractLossClaimLine> lines;
  final List<SubcontractLossResolution> resolutions;
  final List<SubcontractLossClaimEvent> events;

  factory SubcontractLossClaimDetail.fromJson(Map<String, dynamic> json) =>
      SubcontractLossClaimDetail(
        summary: SubcontractLossClaimSummary.fromJson(
          (json['summary'] as Map).cast<String, dynamic>(),
        ),
        lines: [
          for (final value in json['lines'] as List? ?? const [])
            if (value is Map)
              SubcontractLossClaimLine.fromJson(value.cast<String, dynamic>()),
        ],
        resolutions: [
          for (final value in json['resolutions'] as List? ?? const [])
            if (value is Map)
              SubcontractLossResolution.fromJson(value.cast<String, dynamic>()),
        ],
        events: [
          for (final value in json['events'] as List? ?? const [])
            if (value is Map)
              SubcontractLossClaimEvent.fromJson(value.cast<String, dynamic>()),
        ],
      );
}

class SubcontractLossClaimPageResult {
  const SubcontractLossClaimPageResult({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<SubcontractLossClaimSummary> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory SubcontractLossClaimPageResult.fromJson(Map<String, dynamic> json) =>
      SubcontractLossClaimPageResult(
        items: [
          for (final value in json['items'] as List? ?? const [])
            if (value is Map)
              SubcontractLossClaimSummary.fromJson(
                value.cast<String, dynamic>(),
              ),
        ],
        page: _intValue(json['page'], 1),
        size: _intValue(json['size'], 30),
        total: _intValue(json['total']),
        totalPages: _intValue(json['totalPages'], 1),
      );
}

class SubcontractLossOffsetTarget {
  const SubcontractLossOffsetTarget({
    required this.payableId,
    required this.amountOriginal,
  });

  final String payableId;
  final String amountOriginal;

  Map<String, dynamic> toJson() => {
    'payableId': payableId,
    'amountOriginal': amountOriginal,
  };
}

class SubcontractLossResolutionInput {
  const SubcontractLossResolutionInput({
    required this.caseLineId,
    required this.type,
    required this.quantity,
    this.amountLocal,
    this.dueDate,
    this.note,
    this.offsetTargets = const [],
  });

  final String caseLineId;
  final String type;
  final String quantity;
  final String? amountLocal;
  final String? dueDate;
  final String? note;
  final List<SubcontractLossOffsetTarget> offsetTargets;

  Map<String, dynamic> toJson() => {
    'caseLineId': caseLineId,
    'type': type,
    'quantity': quantity,
    if (amountLocal != null) 'amountLocal': amountLocal,
    if (dueDate != null) 'dueDate': dueDate,
    if (note?.trim().isNotEmpty == true) 'note': note!.trim(),
    'offsetTargets': [for (final target in offsetTargets) target.toJson()],
  };
}
