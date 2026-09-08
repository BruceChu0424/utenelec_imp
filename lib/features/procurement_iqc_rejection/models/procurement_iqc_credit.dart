/// All monetary and quantity facts retain the server's exact decimal text.
class ProcurementIqcResolution {
  const ProcurementIqcResolution({
    this.baseUnitName,
    this.creditableBaseQty,
    this.replacementPendingBaseQty,
    this.replacementStockedBaseQty,
    this.creditedBaseQty,
    this.unresolvedBaseQty,
    this.unresolvedAmountOriginal,
    this.unresolvedAmountLocal,
    required this.state,
    required this.legacyUnclassified,
  });
  final String? baseUnitName,
      creditableBaseQty,
      replacementPendingBaseQty,
      replacementStockedBaseQty,
      creditedBaseQty,
      unresolvedBaseQty,
      unresolvedAmountOriginal,
      unresolvedAmountLocal;
  final String state;
  final bool legacyUnclassified;
  factory ProcurementIqcResolution.fromJson(Map<String, dynamic> json) =>
      ProcurementIqcResolution(
        baseUnitName: _text(json['baseUnitName']),
        creditableBaseQty: _text(json['creditableBaseQty']),
        replacementPendingBaseQty: _text(json['replacementPendingBaseQty']),
        replacementStockedBaseQty: _text(json['replacementStockedBaseQty']),
        creditedBaseQty: _text(json['creditedBaseQty']),
        unresolvedBaseQty: _text(json['unresolvedBaseQty']),
        unresolvedAmountOriginal: _text(json['unresolvedAmountOriginal']),
        unresolvedAmountLocal: _text(json['unresolvedAmountLocal']),
        state: _text(json['resolutionState']) ?? 'UNKNOWN',
        legacyUnclassified: json['legacyUnclassified'] == true,
      );
}

class ProcurementIqcCreditCase {
  const ProcurementIqcCreditCase({
    required this.caseId,
    required this.version,
    this.receiptBillNo,
    this.goodsName,
    this.creditableBaseQty,
    this.baseUnitName,
  });
  final String caseId;
  final int version;
  final String? receiptBillNo, goodsName, creditableBaseQty, baseUnitName;
  factory ProcurementIqcCreditCase.fromJson(Map<String, dynamic> json) =>
      ProcurementIqcCreditCase(
        caseId: _text(json['caseId']) ?? '',
        version: int.tryParse('${json['version']}') ?? 0,
        receiptBillNo: _text(json['receiptBillNo']),
        goodsName: _text(json['goodsName']),
        creditableBaseQty: _text(json['creditableBaseQty']),
        baseUnitName: _text(json['baseUnitName']),
      );
}

class ProcurementIqcCreditSource {
  const ProcurementIqcCreditSource({
    required this.sourceApLedgerId,
    this.sourceBillNo,
    this.amountOriginal,
    this.amountLocal,
    this.creditedAmountOriginal,
    this.remainingAmountOriginal,
    this.cases = const [],
  });
  final String sourceApLedgerId;
  final String? sourceBillNo,
      amountOriginal,
      amountLocal,
      creditedAmountOriginal,
      remainingAmountOriginal;
  final List<ProcurementIqcCreditCase> cases;
  factory ProcurementIqcCreditSource.fromJson(Map<String, dynamic> json) =>
      ProcurementIqcCreditSource(
        sourceApLedgerId: _text(json['sourceApLedgerId']) ?? '',
        sourceBillNo: _text(json['sourceBillNo']),
        amountOriginal: _text(json['amountOriginal']),
        amountLocal: _text(json['amountLocal']),
        creditedAmountOriginal: _text(json['creditedAmountOriginal']),
        remainingAmountOriginal: _text(json['remainingAmountOriginal']),
        cases: _rows(
          json['cases'],
        ).map(ProcurementIqcCreditCase.fromJson).toList(),
      );
}

class ProcurementIqcCreditCaseBook {
  const ProcurementIqcCreditCaseBook({
    required this.caseId,
    this.baseQty,
    this.amountOriginal,
    this.amountLocal,
    this.beforeOriginal,
    this.beforeLocal,
    this.afterOriginal,
    this.afterLocal,
  });
  final String caseId;
  final String? baseQty,
      amountOriginal,
      amountLocal,
      beforeOriginal,
      beforeLocal,
      afterOriginal,
      afterLocal;
  factory ProcurementIqcCreditCaseBook.fromJson(Map<String, dynamic> json) =>
      ProcurementIqcCreditCaseBook(
        caseId: _text(json['caseId']) ?? '',
        baseQty: _text(json['baseQty']),
        amountOriginal: _text(json['amountOriginal']),
        amountLocal: _text(json['amountLocal']),
        beforeOriginal: _text(json['beforeOriginal']),
        beforeLocal: _text(json['beforeLocal']),
        afterOriginal: _text(json['afterOriginal']),
        afterLocal: _text(json['afterLocal']),
      );
}

class ProcurementIqcCreditDocument {
  const ProcurementIqcCreditDocument({
    required this.creditDocumentId,
    required this.status,
    required this.canReverse,
    this.baseQty,
    this.amountOriginal,
    this.amountLocal,
    this.creditReference,
    this.creditDate,
    this.caseAllocations = const [],
  });
  final String creditDocumentId, status;
  final String? baseQty,
      amountOriginal,
      amountLocal,
      creditReference,
      creditDate;
  final bool canReverse;
  final List<ProcurementIqcCreditCaseBook> caseAllocations;
  factory ProcurementIqcCreditDocument.fromJson(Map<String, dynamic> json) =>
      ProcurementIqcCreditDocument(
        creditDocumentId: _text(json['creditDocumentId']) ?? '',
        status: _text(json['status']) ?? 'UNKNOWN',
        canReverse: json['canReverse'] == true,
        baseQty: _text(json['baseQty']),
        amountOriginal: _text(json['amountOriginal']),
        amountLocal: _text(json['amountLocal']),
        creditReference: _text(json['creditReference']),
        creditDate: _text(json['creditDate']),
        caseAllocations: _rows(
          json['caseAllocations'],
        ).map(ProcurementIqcCreditCaseBook.fromJson).toList(),
      );
}

class ProcurementIqcCreditPreview {
  const ProcurementIqcCreditPreview({
    required this.bookAllocationHash,
    this.amountOriginal,
    this.amountLocal,
    this.offsetOriginal,
    this.offsetLocal,
    this.creditRemainingOriginal,
    this.creditRemainingLocal,
    this.sourceBeforeOriginal,
    this.sourceBeforeLocal,
    this.sourceAfterOriginal,
    this.sourceAfterLocal,
    this.caseAllocations = const [],
  });
  final String bookAllocationHash;
  final String? amountOriginal,
      amountLocal,
      offsetOriginal,
      offsetLocal,
      creditRemainingOriginal,
      creditRemainingLocal,
      sourceBeforeOriginal,
      sourceBeforeLocal,
      sourceAfterOriginal,
      sourceAfterLocal;
  final List<ProcurementIqcCreditCaseBook> caseAllocations;
  factory ProcurementIqcCreditPreview.fromJson(Map<String, dynamic> json) =>
      ProcurementIqcCreditPreview(
        bookAllocationHash: _text(json['bookAllocationHash']) ?? '',
        amountOriginal: _text(json['amountOriginal']),
        amountLocal: _text(json['amountLocal']),
        offsetOriginal: _text(json['offsetOriginal']),
        offsetLocal: _text(json['offsetLocal']),
        creditRemainingOriginal: _text(json['creditRemainingOriginal']),
        creditRemainingLocal: _text(json['creditRemainingLocal']),
        sourceBeforeOriginal: _text(json['sourceBeforeOriginal']),
        sourceBeforeLocal: _text(json['sourceBeforeLocal']),
        sourceAfterOriginal: _text(json['sourceAfterOriginal']),
        sourceAfterLocal: _text(json['sourceAfterLocal']),
        caseAllocations: _rows(
          json['caseAllocations'],
        ).map(ProcurementIqcCreditCaseBook.fromJson).toList(),
      );
}

class ProcurementIqcCreditAllocationCommand {
  const ProcurementIqcCreditAllocationCommand({
    required this.caseId,
    required this.expectedVersion,
    required this.baseQty,
    required this.amountOriginal,
  });
  final String caseId, baseQty, amountOriginal;
  final int expectedVersion;
  Map<String, dynamic> toJson() => {
    'caseId': caseId,
    'expectedVersion': expectedVersion,
    'baseQty': baseQty.trim(),
    'amountOriginal': amountOriginal.trim(),
  };
}

String? _text(Object? raw) {
  final text = raw?.toString().trim();
  return text?.isNotEmpty == true ? text : null;
}

Iterable<Map<String, dynamic>> _rows(Object? raw) sync* {
  if (raw is List) {
    for (final row in raw) {
      if (row is Map) yield row.cast<String, dynamic>();
    }
  }
}
