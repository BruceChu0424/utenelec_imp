import 'procurement_iqc_credit.dart';
export 'procurement_iqc_credit.dart';

enum ProcurementIqcReceiptType {
  purchase('PURCHASE', '采购'),
  subcontract('SUBCONTRACT', '委外');

  const ProcurementIqcReceiptType(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static ProcurementIqcReceiptType? tryParse(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    for (final type in values) {
      if (type.apiValue == normalized) return type;
    }
    return null;
  }
}

enum ProcurementIqcRejectionStatus {
  pendingReturn('PENDING_RETURN', '待登记实物退回'),
  returnRecorded('RETURN_RECORDED', '实物已退回 / 待财务'),
  creditConfirmed('CREDIT_CONFIRMED', '供应商贷项已确认'),
  closedNoCredit('CLOSED_NO_CREDIT', '零金额无需贷项结案'),
  financeException('FINANCE_EXCEPTION', '财务投影异常'),
  reversed('REVERSED', '已反向'),
  unknown('UNKNOWN', '未知状态');

  const ProcurementIqcRejectionStatus(this.apiValue, this.label);

  final String apiValue;
  final String label;

  bool get isTerminal =>
      this == creditConfirmed || this == closedNoCredit || this == reversed;

  static ProcurementIqcRejectionStatus parse(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    for (final status in values) {
      if (status.apiValue == normalized) return status;
    }
    return unknown;
  }
}

abstract final class ProcurementIqcRejectionAction {
  static const recordReturn = 'RECORD_RETURN';
  static const confirmCredit = 'CONFIRM_CREDIT';
  static const closeNoCredit = 'CLOSE_NO_CREDIT';
  static const reverse = 'REVERSE';
  static const retryFinanceProjection = 'RETRY_FINANCE_PROJECTION';
}

class ProcurementIqcRejectionFilter {
  const ProcurementIqcRejectionFilter({
    this.receiptType,
    this.status,
    this.keyword = '',
    this.page = 1,
    this.size = 50,
  });

  final ProcurementIqcReceiptType? receiptType;

  /// Exact status or backend sentinel `TERMINAL`.
  final String? status;
  final String keyword;
  final int page;
  final int size;

  Map<String, dynamic> toQuery({bool includePaging = true}) => {
    if (receiptType != null) 'receiptType': receiptType!.apiValue,
    if (status?.trim().isNotEmpty == true) 'status': status!.trim(),
    if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
    if (includePaging) 'page': page,
    if (includePaging) 'size': size,
  };
}

class ProcurementIqcRejectionCase {
  const ProcurementIqcRejectionCase({
    required this.id,
    required this.receiptType,
    required this.status,
    required this.version,
    required this.allowedActions,
    required this.priceMasked,
    this.receiptId,
    this.receiptItemId,
    this.inspectionItemId,
    this.receiptBillNo,
    this.orderBillNo,
    this.supplierId,
    this.supplierName,
    this.goodsCode,
    this.goodsName,
    this.failedBaseQty,
    this.failedQty,
    this.unitName,
    this.failedAmountOriginal,
    this.failedAmountLocal,
    this.currencyCode,
    this.ownerUserId,
    this.returnReference,
    this.returnDate,
    this.returnNote,
    this.returnedAt,
    this.creditReference,
    this.creditDate,
    this.creditConfirmedAt,
    this.closedNoCreditReason,
    this.closedNoCreditAt,
    this.financeExceptionCode,
    this.financeExceptionMessage,
    this.holdReason,
  });

  final String id;
  final ProcurementIqcReceiptType? receiptType;
  final String? receiptId;
  final String? receiptItemId;
  final String? inspectionItemId;
  final String? receiptBillNo;
  final String? orderBillNo;
  final String? supplierId;
  final String? supplierName;
  final String? goodsCode;
  final String? goodsName;
  final String? failedBaseQty;
  final String? failedQty;
  final String? unitName;
  final String? failedAmountOriginal;
  final String? failedAmountLocal;
  final String? currencyCode;
  final ProcurementIqcRejectionStatus status;
  final int version;
  final String? ownerUserId;
  final String? returnReference;
  final String? returnDate;
  final String? returnNote;
  final String? returnedAt;
  final String? creditReference;
  final String? creditDate;
  final String? creditConfirmedAt;
  final String? closedNoCreditReason;
  final String? closedNoCreditAt;
  final String? financeExceptionCode;
  final String? financeExceptionMessage;
  final String? holdReason;
  final Set<String> allowedActions;
  final bool priceMasked;

  bool allows(String action) => allowedActions.contains(action);

  String get goodsLabel => [
    goodsCode,
    goodsName,
  ].where((value) => value?.trim().isNotEmpty == true).join(' ');

  String amountLabel(String? amount) {
    if (priceMasked) return '***';
    if (amount == null || amount.trim().isEmpty) return '待核对';
    final currency = currencyCode?.trim();
    return currency?.isNotEmpty == true ? '$currency $amount' : amount;
  }

  factory ProcurementIqcRejectionCase.fromJson(Map<String, dynamic> json) =>
      ProcurementIqcRejectionCase(
        id: _text(json['id']) ?? '',
        receiptType: ProcurementIqcReceiptType.tryParse(json['receiptType']),
        receiptId: _text(json['receiptId']),
        receiptItemId: _text(json['receiptItemId']),
        inspectionItemId: _text(json['inspectionItemId']),
        receiptBillNo: _text(json['receiptBillNo']),
        orderBillNo: _text(json['orderBillNo']),
        supplierId: _text(json['supplierId']),
        supplierName: _text(json['supplierName']),
        goodsCode: _text(json['goodsCode']),
        goodsName: _text(json['goodsName']),
        failedBaseQty: _text(json['failedBaseQty']),
        failedQty: _text(json['failedQty']),
        unitName: _text(json['unitName']),
        failedAmountOriginal: _text(json['failedAmountOriginal']),
        failedAmountLocal: _text(json['failedAmountLocal']),
        currencyCode: _text(json['currencyCode']),
        status: ProcurementIqcRejectionStatus.parse(json['status']),
        version: _integer(json['version']),
        ownerUserId: _text(json['ownerUserId']),
        returnReference: _text(json['returnReference']),
        returnDate: _text(json['returnDate']),
        returnNote: _text(json['returnNote']),
        returnedAt: _text(json['returnedAt']),
        creditReference: _text(json['creditReference']),
        creditDate: _text(json['creditDate']),
        creditConfirmedAt: _text(json['creditConfirmedAt']),
        closedNoCreditReason: _text(json['closedNoCreditReason']),
        closedNoCreditAt: _text(json['closedNoCreditAt']),
        financeExceptionCode: _text(json['financeExceptionCode']),
        financeExceptionMessage: _text(json['financeExceptionMessage']),
        holdReason: _text(json['holdReason']),
        allowedActions: {
          for (final action in json['allowedActions'] as List? ?? const [])
            ?_text(action),
        },
        priceMasked: json['priceMasked'] != false,
      );
}

class ProcurementIqcRejectionCounts {
  const ProcurementIqcRejectionCounts({
    required this.total,
    required this.pendingReturn,
    required this.returnRecorded,
    required this.creditConfirmed,
    required this.closedNoCredit,
    required this.financeException,
    required this.reversed,
  });

  final int total;
  final int pendingReturn;
  final int returnRecorded;
  final int creditConfirmed;
  final int closedNoCredit;
  final int financeException;
  final int reversed;

  int get open => pendingReturn + returnRecorded + financeException;
  int get terminal => creditConfirmed + closedNoCredit + reversed;

  factory ProcurementIqcRejectionCounts.fromJson(Map<String, dynamic> json) =>
      ProcurementIqcRejectionCounts(
        total: _integer(json['total']),
        pendingReturn: _integer(json['pendingReturn']),
        returnRecorded: _integer(json['returnRecorded']),
        creditConfirmed: _integer(json['creditConfirmed']),
        closedNoCredit: _integer(json['closedNoCredit']),
        financeException: _integer(json['financeException']),
        reversed: _integer(json['reversed']),
      );
}

class ProcurementIqcRejectionEvent {
  const ProcurementIqcRejectionEvent({
    required this.id,
    required this.eventType,
    this.actorUserId,
    this.commandId,
    this.reference,
    this.eventDate,
    this.reason,
    this.createdAt,
  });

  final String id;
  final String eventType;
  final String? actorUserId;
  final String? commandId;
  final String? reference;
  final String? eventDate;
  final String? reason;
  final String? createdAt;

  factory ProcurementIqcRejectionEvent.fromJson(Map<String, dynamic> json) =>
      ProcurementIqcRejectionEvent(
        id: _text(json['id']) ?? '',
        eventType: _text(json['eventType']) ?? 'UNKNOWN',
        actorUserId: _text(json['actorUserId']),
        commandId: _text(json['commandId']),
        reference: _text(json['reference']),
        eventDate: _text(json['eventDate']),
        reason: _text(json['reason']),
        createdAt: _text(json['createdAt']),
      );
}

class ProcurementIqcReplacementAllocation {
  const ProcurementIqcReplacementAllocation({
    required this.id,
    required this.status,
    this.replacementReceiptType,
    this.replacementReceiptId,
    this.replacementReceiptItemId,
    this.allocatedBaseQty,
    this.allocatedQty,
    this.allocatedAmountOriginal,
    this.allocatedAmountLocal,
    this.createdAt,
    this.reversedAt,
  });

  final String id;
  final String? replacementReceiptType;
  final String? replacementReceiptId;
  final String? replacementReceiptItemId;
  final String? allocatedBaseQty;
  final String? allocatedQty;
  final String? allocatedAmountOriginal;
  final String? allocatedAmountLocal;
  final String status;
  final String? createdAt;
  final String? reversedAt;

  factory ProcurementIqcReplacementAllocation.fromJson(
    Map<String, dynamic> json,
  ) => ProcurementIqcReplacementAllocation(
    id: _text(json['id']) ?? '',
    replacementReceiptType: _text(json['replacementReceiptType']),
    replacementReceiptId: _text(json['replacementReceiptId']),
    replacementReceiptItemId: _text(json['replacementReceiptItemId']),
    allocatedBaseQty: _text(json['allocatedBaseQty']),
    allocatedQty: _text(json['allocatedQty']),
    allocatedAmountOriginal: _text(json['allocatedAmountOriginal']),
    allocatedAmountLocal: _text(json['allocatedAmountLocal']),
    status: _text(json['status']) ?? 'UNKNOWN',
    createdAt: _text(json['createdAt']),
    reversedAt: _text(json['reversedAt']),
  );
}

class ProcurementIqcRejectionDetail {
  const ProcurementIqcRejectionDetail({
    required this.caseItem,
    this.events = const [],
    this.replacementAllocations = const [],
    this.resolution,
    this.creditDocuments = const [],
    this.creditSources = const [],
  });

  final ProcurementIqcRejectionCase caseItem;
  final List<ProcurementIqcRejectionEvent> events;
  final List<ProcurementIqcReplacementAllocation> replacementAllocations;
  final ProcurementIqcResolution? resolution;
  final List<ProcurementIqcCreditDocument> creditDocuments;
  final List<ProcurementIqcCreditSource> creditSources;

  factory ProcurementIqcRejectionDetail.fromJson(Map<String, dynamic> json) {
    final rawCase = json['caseItem'];
    return ProcurementIqcRejectionDetail(
      caseItem: ProcurementIqcRejectionCase.fromJson(
        rawCase is Map ? rawCase.cast<String, dynamic>() : json,
      ),
      events: [
        for (final raw in json['events'] as List? ?? const [])
          if (raw is Map)
            ProcurementIqcRejectionEvent.fromJson(raw.cast<String, dynamic>()),
      ],
      replacementAllocations: [
        for (final raw in json['replacementAllocations'] as List? ?? const [])
          if (raw is Map)
            ProcurementIqcReplacementAllocation.fromJson(
              raw.cast<String, dynamic>(),
            ),
      ],
      resolution: json['resolution'] is Map
          ? ProcurementIqcResolution.fromJson(
              (json['resolution'] as Map).cast<String, dynamic>(),
            )
          : null,
      creditDocuments: [
        for (final row in json['creditDocuments'] as List? ?? const [])
          if (row is Map)
            ProcurementIqcCreditDocument.fromJson(row.cast<String, dynamic>()),
      ],
      creditSources: [
        for (final row in json['creditSources'] as List? ?? const [])
          if (row is Map)
            ProcurementIqcCreditSource.fromJson(row.cast<String, dynamic>()),
      ],
    );
  }
}

class ProcurementIqcRecordReturnCommand {
  const ProcurementIqcRecordReturnCommand({
    required this.expectedVersion,
    required this.commandId,
    required this.returnReference,
    required this.returnDate,
    required this.returnNote,
  });

  final int expectedVersion;
  final String commandId;
  final String returnReference;
  final String returnDate;
  final String returnNote;

  Map<String, dynamic> toJson() => {
    'expectedVersion': expectedVersion,
    'commandId': commandId,
    'returnReference': returnReference.trim(),
    'returnDate': returnDate,
    'returnNote': returnNote.trim(),
  };
}

class ProcurementIqcConfirmCreditCommand {
  const ProcurementIqcConfirmCreditCommand({
    required this.expectedVersion,
    required this.commandId,
    required this.creditReference,
    required this.creditDate,
    required this.reason,
    this.baseQty,
    this.actualAmountOriginal,
    this.sourceApLedgerId,
    this.allocations = const [],
    this.expectedBookAllocationHash,
  });

  final int expectedVersion;
  final String commandId;
  final String creditReference;
  final String creditDate;
  final String reason;
  final String? baseQty,
      actualAmountOriginal,
      sourceApLedgerId,
      expectedBookAllocationHash;
  final List<ProcurementIqcCreditAllocationCommand> allocations;

  ProcurementIqcConfirmCreditCommand withBookHash(String hash) =>
      ProcurementIqcConfirmCreditCommand(
        expectedVersion: expectedVersion,
        commandId: commandId,
        creditReference: creditReference,
        creditDate: creditDate,
        reason: reason,
        baseQty: baseQty,
        actualAmountOriginal: actualAmountOriginal,
        sourceApLedgerId: sourceApLedgerId,
        allocations: allocations,
        expectedBookAllocationHash: hash,
      );

  Map<String, dynamic> toJson() => {
    'expectedVersion': expectedVersion,
    'commandId': commandId,
    'creditReference': creditReference.trim(),
    'creditDate': creditDate,
    'reason': reason.trim(),
    if (actualAmountOriginal != null) ...{
      'baseQty': baseQty,
      'actualAmountOriginal': actualAmountOriginal!.trim(),
      'sourceApLedgerId': sourceApLedgerId,
      'allocations': allocations.map((item) => item.toJson()).toList(),
      'expectedBookAllocationHash': expectedBookAllocationHash,
    },
  };
}

class ProcurementIqcReasonCommand {
  const ProcurementIqcReasonCommand({
    required this.expectedVersion,
    required this.commandId,
    required this.reason,
    this.creditDocumentId,
  });

  final int expectedVersion;
  final String commandId;
  final String reason;
  final String? creditDocumentId;

  Map<String, dynamic> toJson() => {
    'expectedVersion': expectedVersion,
    'commandId': commandId,
    'reason': reason.trim(),
    if (creditDocumentId != null) 'creditDocumentId': creditDocumentId,
  };
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int _integer(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
