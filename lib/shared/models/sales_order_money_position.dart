import '../formatters/exact_decimal.dart';

class SalesOrderMoneyPosition {
  const SalesOrderMoneyPosition({
    this.cashReceivedOriginal,
    this.plannedRemainingOriginal,
    this.prepaymentAvailableOriginal,
    this.customerUnassignedPrepaymentOriginal,
    this.pendingReceiptOriginal,
    this.prepaymentAppliedOriginal,
    this.returnCreditOriginal,
    this.customerPendingBalanceOriginal,
    this.orderBillNo,
    this.currencyName,
    this.hasUnallocated = false,
    this.positionComplete = false,
    this.warnings = const [],
  });
  final String? cashReceivedOriginal;
  final String? plannedRemainingOriginal;
  final String? prepaymentAvailableOriginal;
  final String? customerUnassignedPrepaymentOriginal;
  final String? pendingReceiptOriginal,
      prepaymentAppliedOriginal,
      returnCreditOriginal,
      customerPendingBalanceOriginal;
  final String? orderBillNo, currencyName;
  final bool hasUnallocated, positionComplete;
  final List<String> warnings;
  factory SalesOrderMoneyPosition.fromJson(Map<String, dynamic> json) =>
      SalesOrderMoneyPosition(
        cashReceivedOriginal: financeExactDecimal(json['cashReceivedOriginal']),
        plannedRemainingOriginal: financeExactDecimal(
          json['plannedRemainingOriginal'],
        ),
        prepaymentAvailableOriginal: financeExactDecimal(
          json['prepaymentAvailableOriginal'],
        ),
        customerUnassignedPrepaymentOriginal: financeExactDecimal(
          json['customerUnassignedPrepaymentOriginal'],
        ),
        pendingReceiptOriginal: financeExactDecimal(
          json['pendingReceiptOriginal'],
        ),
        prepaymentAppliedOriginal: financeExactDecimal(
          json['prepaymentAppliedOriginal'],
        ),
        returnCreditOriginal: financeExactDecimal(json['returnCreditOriginal']),
        customerPendingBalanceOriginal: financeExactDecimal(
          json['customerPendingBalanceOriginal'],
        ),
        orderBillNo: json['orderBillNo'] as String?,
        currencyName: json['currencyName'] as String?,
        hasUnallocated: json['hasUnallocated'] == true,
        positionComplete: json['positionComplete'] == true,
        warnings: [
          for (final value in json['warnings'] as List? ?? const [])
            value.toString(),
        ],
      );
}
