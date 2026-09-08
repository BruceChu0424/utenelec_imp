import 'finance_decimal.dart';

int _int(Object? value, {int fallback = 0}) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString() ?? '') ?? fallback;

String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

class CustomerPrepaymentPage {
  const CustomerPrepaymentPage({
    required this.summary,
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final CustomerPrepaymentSummary summary;
  final List<CustomerPrepaymentItem> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory CustomerPrepaymentPage.fromJson(Map<String, dynamic> json) =>
      CustomerPrepaymentPage(
        summary: CustomerPrepaymentSummary.fromJson(
          (json['summary'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        items: [
          for (final item in json['items'] as List? ?? const [])
            CustomerPrepaymentItem.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
        ],
        page: _int(json['page'], fallback: 1),
        size: _int(json['size'], fallback: 20),
        total: _int(json['total']),
        totalPages: _int(json['totalPages'], fallback: 1),
      );
}

class CustomerPrepaymentSummary {
  const CustomerPrepaymentSummary({
    this.receivedOriginal,
    this.receivedLocal,
    this.appliedOriginal,
    this.appliedSourceBookLocal,
    this.availableOriginal,
    this.availableLocal,
  });

  final String? receivedOriginal;
  final String? receivedLocal;
  final String? appliedOriginal;
  final String? appliedSourceBookLocal;
  final String? availableOriginal;
  final String? availableLocal;

  factory CustomerPrepaymentSummary.fromJson(Map<String, dynamic> json) =>
      CustomerPrepaymentSummary(
        receivedOriginal: financeExactDecimal(json['receivedOriginal']),
        receivedLocal: financeExactDecimal(json['receivedLocal']),
        appliedOriginal: financeExactDecimal(json['appliedOriginal']),
        appliedSourceBookLocal: financeExactDecimal(
          json['appliedSourceBookLocal'] ?? json['appliedLocal'],
        ),
        availableOriginal: financeExactDecimal(json['availableOriginal']),
        availableLocal: financeExactDecimal(json['availableLocal']),
      );
}

class CustomerPrepaymentItem {
  const CustomerPrepaymentItem({
    required this.ledgerId,
    this.receiptId,
    this.billNo,
    this.billDate,
    this.salesOrderId,
    this.clientId,
    this.currencyId,
    this.currencyCode,
    this.currencyName,
    this.exchangeRate,
    this.receivedOriginal,
    this.receivedLocal,
    this.appliedOriginal,
    this.appliedSourceBookLocal,
    this.availableOriginal,
    this.availableLocal,
    this.rowVersion = 0,
  });

  final String ledgerId;
  final String? receiptId;
  final String? billNo;
  final String? billDate;
  final String? salesOrderId;
  final String? clientId;
  final String? currencyId;
  final String? currencyCode;
  final String? currencyName;
  final String? exchangeRate;
  final String? receivedOriginal;
  final String? receivedLocal;
  final String? appliedOriginal;
  final String? appliedSourceBookLocal;
  final String? availableOriginal;
  final String? availableLocal;
  final int rowVersion;

  bool get hasAvailable =>
      (financeAmountUnits(availableOriginal) ?? BigInt.zero) > BigInt.zero;

  factory CustomerPrepaymentItem.fromJson(Map<String, dynamic> json) =>
      CustomerPrepaymentItem(
        ledgerId: _text(json['ledgerId'] ?? json['sourceLedgerId']) ?? '',
        receiptId: _text(json['receiptId']),
        billNo: _text(json['billNo']),
        billDate: _text(json['billDate'] ?? json['date']),
        salesOrderId: _text(json['salesOrderId']),
        clientId: _text(json['clientId']),
        currencyId: _text(json['currencyId']),
        currencyCode: _text(json['currencyCode']),
        currencyName: _text(json['currencyName']),
        exchangeRate: financeExactDecimal(json['exchangeRate'] ?? json['rate']),
        receivedOriginal: financeExactDecimal(
          json['receivedOriginal'] ?? json['amountOriginal'],
        ),
        receivedLocal: financeExactDecimal(
          json['receivedLocal'] ?? json['amountLocal'],
        ),
        appliedOriginal: financeExactDecimal(json['appliedOriginal']),
        appliedSourceBookLocal: financeExactDecimal(
          json['appliedSourceBookLocal'] ?? json['appliedLocal'],
        ),
        availableOriginal: financeExactDecimal(json['availableOriginal']),
        availableLocal: financeExactDecimal(json['availableLocal']),
        rowVersion: _int(json['rowVersion']),
      );
}

class CustomerPrepaymentOffsetTarget {
  const CustomerPrepaymentOffsetTarget({
    required this.receivableLedgerId,
    required this.salesOrderId,
    required this.amountOriginal,
  });

  final String receivableLedgerId;
  final String salesOrderId;
  final String amountOriginal;

  Map<String, dynamic> toJson() => {
    'receivableLedgerId': receivableLedgerId,
    'salesOrderId': salesOrderId,
    'amountOriginal': amountOriginal,
  };
}

class CustomerPrepaymentOffsetResult {
  const CustomerPrepaymentOffsetResult({
    required this.batchId,
    this.rowVersion = 0,
    this.status,
    this.effectiveDate,
    this.allocations = const [],
  });

  final String batchId;
  final int rowVersion;
  final String? status;
  final String? effectiveDate;
  final List<Map<String, dynamic>> allocations;

  factory CustomerPrepaymentOffsetResult.fromJson(Map<String, dynamic> json) =>
      CustomerPrepaymentOffsetResult(
        batchId: _text(json['batchId']) ?? '',
        rowVersion: _int(json['rowVersion']),
        status: _text(json['status']),
        effectiveDate: _text(json['effectiveDate']),
        allocations: [
          for (final item in json['allocations'] as List? ?? const [])
            (item as Map).cast<String, dynamic>(),
        ],
      );
}

class SalesOrderMoneySummary {
  const SalesOrderMoneySummary({
    required this.salesOrderId,
    this.orderBillNo,
    this.clientId,
    this.currencyId,
    this.currencyCode,
    this.orderTotalOriginal,
    this.orderTotalLocal,
    this.formalArOriginal,
    this.formalArLocal,
    this.cashReceivedOriginal,
    this.cashReceivedLocal,
    this.writeOffOriginal,
    this.writeOffLocal,
    this.prepaymentReceivedOriginal,
    this.prepaymentReceivedLocal,
    this.prepaymentAppliedOriginal,
    this.prepaymentAppliedSourceBookLocal,
    this.prepaymentAppliedTargetBookLocal,
    this.prepaymentExchangeDifferenceLocal,
    this.prepaymentAvailableOriginal,
    this.prepaymentAvailableLocal,
    this.arOutstandingOriginal,
    this.arOutstandingLocal,
    this.unrecognizedOrderOriginal,
    this.unrecognizedOrderLocal,
    this.plannedRemainingOriginal,
    this.overpaidOriginal,
    this.hasUnallocated = false,
    this.unallocatedReceiptLines = const [],
    this.warnings = const [],
    this.returnCreditOriginal,
    this.returnCreditLocal,
    this.unusedReturnCreditOriginal,
    this.unusedReturnCreditLocal,
    this.netReceivableOriginal,
    this.netReceivableLocal,
    this.customerPendingBalanceOriginal,
    this.customerPendingBalanceLocal,
    this.positionComplete = false,
    this.unresolvedPositionCount = 0,
  });

  final String salesOrderId;
  final String? orderBillNo;
  final String? clientId;
  final String? currencyId;
  final String? currencyCode;
  final String? orderTotalOriginal;
  final String? orderTotalLocal;
  final String? formalArOriginal;
  final String? formalArLocal;
  final String? cashReceivedOriginal;
  final String? cashReceivedLocal;
  final String? writeOffOriginal;
  final String? writeOffLocal;
  final String? prepaymentReceivedOriginal;
  final String? prepaymentReceivedLocal;
  final String? prepaymentAppliedOriginal;
  final String? prepaymentAppliedSourceBookLocal;
  final String? prepaymentAppliedTargetBookLocal;
  final String? prepaymentExchangeDifferenceLocal;
  final String? prepaymentAvailableOriginal;
  final String? prepaymentAvailableLocal;
  final String? arOutstandingOriginal;
  final String? arOutstandingLocal;
  final String? unrecognizedOrderOriginal;
  final String? unrecognizedOrderLocal;
  final String? plannedRemainingOriginal;
  final String? overpaidOriginal;
  final bool hasUnallocated;
  final List<Map<String, dynamic>> unallocatedReceiptLines;
  final List<String> warnings;
  final String? returnCreditOriginal;
  final String? returnCreditLocal;
  final String? unusedReturnCreditOriginal;
  final String? unusedReturnCreditLocal;
  final String? netReceivableOriginal;
  final String? netReceivableLocal;
  final String? customerPendingBalanceOriginal;
  final String? customerPendingBalanceLocal;
  final bool positionComplete;
  final int unresolvedPositionCount;

  factory SalesOrderMoneySummary.fromJson(Map<String, dynamic> json) {
    String? money(String key) => financeExactDecimal(json[key]);
    return SalesOrderMoneySummary(
      salesOrderId: _text(json['salesOrderId']) ?? '',
      orderBillNo: _text(json['orderBillNo']),
      clientId: _text(json['clientId']),
      currencyId: _text(json['currencyId']),
      currencyCode: _text(json['currencyCode']),
      orderTotalOriginal: money('orderTotalOriginal'),
      orderTotalLocal: money('orderTotalLocal'),
      formalArOriginal: money('formalArOriginal'),
      formalArLocal: money('formalArLocal'),
      cashReceivedOriginal: money('cashReceivedOriginal'),
      cashReceivedLocal: money('cashReceivedLocal'),
      writeOffOriginal: money('writeOffOriginal'),
      writeOffLocal: money('writeOffLocal'),
      prepaymentReceivedOriginal: money('prepaymentReceivedOriginal'),
      prepaymentReceivedLocal: money('prepaymentReceivedLocal'),
      prepaymentAppliedOriginal: money('prepaymentAppliedOriginal'),
      prepaymentAppliedSourceBookLocal: money(
        'prepaymentAppliedSourceBookLocal',
      ),
      prepaymentAppliedTargetBookLocal: money(
        'prepaymentAppliedTargetBookLocal',
      ),
      prepaymentExchangeDifferenceLocal: money(
        'prepaymentExchangeDifferenceLocal',
      ),
      prepaymentAvailableOriginal: money('prepaymentAvailableOriginal'),
      prepaymentAvailableLocal: money('prepaymentAvailableLocal'),
      arOutstandingOriginal: money('arOutstandingOriginal'),
      arOutstandingLocal: money('arOutstandingLocal'),
      unrecognizedOrderOriginal: money('unrecognizedOrderOriginal'),
      unrecognizedOrderLocal: money('unrecognizedOrderLocal'),
      plannedRemainingOriginal: money('plannedRemainingOriginal'),
      overpaidOriginal: money('overpaidOriginal'),
      hasUnallocated: json['hasUnallocated'] == true,
      unallocatedReceiptLines: [
        for (final item in json['unallocatedReceiptLines'] as List? ?? const [])
          (item as Map).cast<String, dynamic>(),
      ],
      warnings: [
        for (final warning in json['warnings'] as List? ?? const [])
          ?_text(warning),
      ],
      returnCreditOriginal: money('returnCreditOriginal'),
      returnCreditLocal: money('returnCreditLocal'),
      unusedReturnCreditOriginal: money('unusedReturnCreditOriginal'),
      unusedReturnCreditLocal: money('unusedReturnCreditLocal'),
      netReceivableOriginal: money('netReceivableOriginal'),
      netReceivableLocal: money('netReceivableLocal'),
      customerPendingBalanceOriginal: money('customerPendingBalanceOriginal'),
      customerPendingBalanceLocal: money('customerPendingBalanceLocal'),
      positionComplete: json['positionComplete'] == true,
      unresolvedPositionCount: _int(json['unresolvedPositionCount']),
    );
  }
}
