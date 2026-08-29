String supplierSettlementStatusLabel(String? value) =>
    switch (value?.toUpperCase()) {
      'FROZEN' => '已冻结',
      'SUPPLIER_CONFIRMED' => '供应商已确认',
      'INTERNAL_CONFIRMED' => '公司已确认',
      'BOTH_CONFIRMED' => '双方已确认',
      'DISPUTED' => '争议中',
      'CLOSED' => '已关闭',
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

class SupplierSettlementSummary {
  const SupplierSettlementSummary({
    required this.id,
    this.batchNo,
    required this.supplierId,
    this.supplierCode,
    this.supplierName,
    required this.currencyId,
    this.currencyCode,
    this.currencyName,
    this.periodStart,
    this.periodEnd,
    this.dueDate,
    this.status,
    this.openingBalanceOriginal,
    this.periodPostedOriginal,
    this.periodPaidOriginal,
    this.periodOffsetOriginal,
    this.closingBalanceOriginal,
    this.openingBalanceLocal,
    this.periodPostedLocal,
    this.periodPaidLocal,
    this.periodOffsetLocal,
    this.closingBalanceLocal,
    this.lineCount = 0,
    this.version = 0,
    this.snapshotHash,
    this.createdAt,
  });

  final String id;
  final String? batchNo;
  final String supplierId;
  final String? supplierCode;
  final String? supplierName;
  final String currencyId;
  final String? currencyCode;
  final String? currencyName;
  final String? periodStart;
  final String? periodEnd;
  final String? dueDate;
  final String? status;
  final String? openingBalanceOriginal;
  final String? periodPostedOriginal;
  final String? periodPaidOriginal;
  final String? periodOffsetOriginal;
  final String? closingBalanceOriginal;
  final String? openingBalanceLocal;
  final String? periodPostedLocal;
  final String? periodPaidLocal;
  final String? periodOffsetLocal;
  final String? closingBalanceLocal;
  final int lineCount;
  final int version;
  final String? snapshotHash;
  final String? createdAt;

  String get statusLabel => supplierSettlementStatusLabel(status);
  bool get canSupplierConfirm =>
      status == 'FROZEN' ||
      status == 'INTERNAL_CONFIRMED' ||
      status == 'DISPUTED';
  bool get canInternalConfirm =>
      status == 'FROZEN' ||
      status == 'SUPPLIER_CONFIRMED' ||
      status == 'DISPUTED';
  bool get canDispute => status != 'CLOSED' && status != 'REVERSED';
  bool get canReverse => status != 'REVERSED';

  factory SupplierSettlementSummary.fromJson(Map<String, dynamic> json) =>
      SupplierSettlementSummary(
        id: json['id']?.toString() ?? '',
        batchNo: _text(json['batchNo']),
        supplierId: json['supplierId']?.toString() ?? '',
        supplierCode: _text(json['supplierCode']),
        supplierName: _text(json['supplierName']),
        currencyId: json['currencyId']?.toString() ?? '',
        currencyCode: _text(json['currencyCode']),
        currencyName: _text(json['currencyName']),
        periodStart: _text(json['periodStart']),
        periodEnd: _text(json['periodEnd']),
        dueDate: _text(json['dueDate']),
        status: _text(json['status']),
        openingBalanceOriginal: _text(json['openingBalanceOriginal']),
        periodPostedOriginal: _text(json['periodPostedOriginal']),
        periodPaidOriginal: _text(json['periodPaidOriginal']),
        periodOffsetOriginal: _text(json['periodOffsetOriginal']),
        closingBalanceOriginal: _text(json['closingBalanceOriginal']),
        openingBalanceLocal: _text(json['openingBalanceLocal']),
        periodPostedLocal: _text(json['periodPostedLocal']),
        periodPaidLocal: _text(json['periodPaidLocal']),
        periodOffsetLocal: _text(json['periodOffsetLocal']),
        closingBalanceLocal: _text(json['closingBalanceLocal']),
        lineCount: _intValue(json['lineCount']),
        version: _intValue(json['version']),
        snapshotHash: _text(json['snapshotHash']),
        createdAt: _text(json['createdAt']),
      );
}

class SupplierSettlementLine {
  const SupplierSettlementLine({
    required this.id,
    required this.ledgerId,
    this.businessType,
    this.openItemKind,
    this.sourceDocType,
    this.sourceDocId,
    this.sourceDocNo,
    this.billDate,
    this.dueDate,
    this.bookingRate,
    this.openingBalanceOriginal,
    this.periodPostedOriginal,
    this.periodPaidOriginal,
    this.periodOffsetOriginal,
    this.closingBalanceOriginal,
    this.openingBalanceLocal,
    this.periodPostedLocal,
    this.periodPaidLocal,
    this.periodOffsetLocal,
    this.closingBalanceLocal,
  });

  final String id;
  final String ledgerId;
  final String? businessType;
  final String? openItemKind;
  final String? sourceDocType;
  final String? sourceDocId;
  final String? sourceDocNo;
  final String? billDate;
  final String? dueDate;
  final String? bookingRate;
  final String? openingBalanceOriginal;
  final String? periodPostedOriginal;
  final String? periodPaidOriginal;
  final String? periodOffsetOriginal;
  final String? closingBalanceOriginal;
  final String? openingBalanceLocal;
  final String? periodPostedLocal;
  final String? periodPaidLocal;
  final String? periodOffsetLocal;
  final String? closingBalanceLocal;

  factory SupplierSettlementLine.fromJson(Map<String, dynamic> json) =>
      SupplierSettlementLine(
        id: json['id']?.toString() ?? '',
        ledgerId: json['ledgerId']?.toString() ?? '',
        businessType: _text(json['businessType']),
        openItemKind: _text(json['openItemKind']),
        sourceDocType: _text(json['sourceDocType']),
        sourceDocId: _text(json['sourceDocId']),
        sourceDocNo: _text(json['sourceDocNo']),
        billDate: _text(json['billDate']),
        dueDate: _text(json['dueDate']),
        bookingRate: _text(json['bookingRate']),
        openingBalanceOriginal: _text(json['openingBalanceOriginal']),
        periodPostedOriginal: _text(json['periodPostedOriginal']),
        periodPaidOriginal: _text(json['periodPaidOriginal']),
        periodOffsetOriginal: _text(json['periodOffsetOriginal']),
        closingBalanceOriginal: _text(json['closingBalanceOriginal']),
        openingBalanceLocal: _text(json['openingBalanceLocal']),
        periodPostedLocal: _text(json['periodPostedLocal']),
        periodPaidLocal: _text(json['periodPaidLocal']),
        periodOffsetLocal: _text(json['periodOffsetLocal']),
        closingBalanceLocal: _text(json['closingBalanceLocal']),
      );
}

class SupplierSettlementEvent {
  const SupplierSettlementEvent({
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

  factory SupplierSettlementEvent.fromJson(Map<String, dynamic> json) =>
      SupplierSettlementEvent(
        id: json['id']?.toString() ?? '',
        type: _text(json['type']),
        actorUserId: _text(json['actorUserId']),
        reason: _text(json['reason']),
        createdAt: _text(json['createdAt']),
      );
}

class SupplierSettlementDetail {
  const SupplierSettlementDetail({
    required this.summary,
    required this.lines,
    required this.events,
  });

  final SupplierSettlementSummary summary;
  final List<SupplierSettlementLine> lines;
  final List<SupplierSettlementEvent> events;

  factory SupplierSettlementDetail.fromJson(Map<String, dynamic> json) =>
      SupplierSettlementDetail(
        summary: SupplierSettlementSummary.fromJson(
          (json['summary'] as Map).cast<String, dynamic>(),
        ),
        lines: [
          for (final value in json['lines'] as List? ?? const [])
            if (value is Map)
              SupplierSettlementLine.fromJson(value.cast<String, dynamic>()),
        ],
        events: [
          for (final value in json['events'] as List? ?? const [])
            if (value is Map)
              SupplierSettlementEvent.fromJson(value.cast<String, dynamic>()),
        ],
      );
}

class SupplierSettlementPageResult {
  const SupplierSettlementPageResult({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<SupplierSettlementSummary> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory SupplierSettlementPageResult.fromJson(Map<String, dynamic> json) =>
      SupplierSettlementPageResult(
        items: [
          for (final value in json['items'] as List? ?? const [])
            if (value is Map)
              SupplierSettlementSummary.fromJson(value.cast<String, dynamic>()),
        ],
        page: _intValue(json['page'], 1),
        size: _intValue(json['size'], 30),
        total: _intValue(json['total']),
        totalPages: _intValue(json['totalPages'], 1),
      );
}
