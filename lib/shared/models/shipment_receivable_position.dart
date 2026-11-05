import '../formatters/exact_decimal.dart';

ShipmentReceivablePosition? readShipmentReceivablePosition(Object? raw) =>
    raw is Map && raw.isNotEmpty
    ? ShipmentReceivablePosition.fromJson(Map<String, dynamic>.from(raw))
    : null;

/// Current facts belong to one shipment's actual receivable, independently of
/// the order deposit and the immutable finance-release snapshot.
class ShipmentReceivablePosition {
  const ShipmentReceivablePosition({
    this.ledgerId,
    this.currencyId,
    this.currencyName,
    this.shipmentOriginal,
    this.formalReceivableOriginal,
    this.cashReceivedOriginal,
    this.prepaymentAppliedOriginal,
    this.confirmedPaidOriginal,
    this.reductionOriginal,
    this.returnOffsetOriginal,
    this.otherOffsetOriginal,
    this.balanceOriginal,
    this.dueDate,
    this.overdueDays = 0,
    this.state = 'UNVERIFIED',
    this.complete = false,
    this.warnings = const [],
    this.readAt,
  });
  final String? ledgerId,
      currencyId,
      currencyName,
      shipmentOriginal,
      formalReceivableOriginal,
      cashReceivedOriginal,
      prepaymentAppliedOriginal,
      confirmedPaidOriginal,
      reductionOriginal,
      returnOffsetOriginal,
      otherOffsetOriginal,
      balanceOriginal,
      dueDate;
  final int overdueDays;
  final String state;
  final bool complete;
  final List<String> warnings;

  /// Client receipt time only; it does not claim cross-terminal live delivery.
  final DateTime? readAt;
  bool get notPosted => state == 'NOT_POSTED';
  bool get ready =>
      complete &&
      state == 'READY' &&
      financeAmountUnits(balanceOriginal) != null &&
      financeAmountUnits(confirmedPaidOriginal) != null;
  bool get isSettled =>
      ready && financeAmountUnits(balanceOriginal) == BigInt.zero;
  bool get hasDebt =>
      ready &&
      (financeAmountUnits(balanceOriginal) ?? BigInt.zero) > BigInt.zero;
  bool get needsReview =>
      state == 'UNVERIFIED' ||
      (state == 'READY' && !ready) ||
      (!complete && !notPosted);
  bool get isOverdue =>
      hasDebt && dueDate?.isNotEmpty == true && overdueDays > 0;
  String get unavailableLabel => switch (state) {
    'NOT_POSTED' => '待出库',
    'FREE' => '不收费',
    'REVERSED' => '已反审',
    _ => '需核对',
  };
  factory ShipmentReceivablePosition.fromJson(Map<String, dynamic> json) =>
      ShipmentReceivablePosition(
        ledgerId: json['ledgerId'] as String?,
        currencyId: json['currencyId'] as String?,
        currencyName: json['currencyName'] as String?,
        shipmentOriginal: financeExactDecimal(json['shipmentOriginal']),
        formalReceivableOriginal: financeExactDecimal(
          json['formalReceivableOriginal'],
        ),
        cashReceivedOriginal: financeExactDecimal(json['cashReceivedOriginal']),
        prepaymentAppliedOriginal: financeExactDecimal(
          json['prepaymentAppliedOriginal'],
        ),
        confirmedPaidOriginal: financeExactDecimal(
          json['confirmedPaidOriginal'],
        ),
        reductionOriginal: financeExactDecimal(json['reductionOriginal']),
        returnOffsetOriginal: financeExactDecimal(json['returnOffsetOriginal']),
        otherOffsetOriginal: financeExactDecimal(json['otherOffsetOriginal']),
        balanceOriginal: financeExactDecimal(json['balanceOriginal']),
        dueDate: json['dueDate'] as String?,
        overdueDays: (json['overdueDays'] as num?)?.toInt() ?? 0,
        state: json['state'] as String? ?? 'UNVERIFIED',
        complete: json['complete'] == true,
        warnings: [
          for (final value in json['warnings'] as List? ?? const [])
            value.toString(),
        ],
        readAt: DateTime.now(),
      );
}
