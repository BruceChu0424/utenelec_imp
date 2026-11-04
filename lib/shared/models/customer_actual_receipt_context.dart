/// Approved receipt and its account posting; amounts remain exact decimal text.
class CustomerActualReceiptContext {
  const CustomerActualReceiptContext({
    required this.available,
    required this.verifiedCount,
    required this.pendingCount,
    required this.receipts,
    required this.more,
    required this.basis,
    this.verifiedCashLocal,
    this.asOf,
  });
  final bool available, more;
  final int verifiedCount, pendingCount;
  final String? verifiedCashLocal, asOf;
  final String basis;
  final List<CustomerActualReceipt> receipts;
  factory CustomerActualReceiptContext.fromJson(Map<String, dynamic> json) =>
      CustomerActualReceiptContext(
        available: json['available'] == true,
        verifiedCount: (json['verifiedCount'] as num?)?.toInt() ?? 0,
        pendingCount: (json['pendingCount'] as num?)?.toInt() ?? 0,
        verifiedCashLocal: json['verifiedCashLocal']?.toString(),
        asOf: json['asOf']?.toString(),
        more: json['more'] == true,
        basis: json['basis']?.toString() ?? '',
        receipts: [
          for (final row in json['receipts'] as List? ?? const [])
            if (row is Map)
              CustomerActualReceipt.fromJson(Map<String, dynamic>.from(row)),
        ],
      );
}

class CustomerActualReceipt {
  const CustomerActualReceipt({
    required this.id,
    required this.billNo,
    required this.bankBookedAt,
    required this.accountCurrency,
    required this.accountAmount,
    required this.cashLocal,
  });
  final String id,
      billNo,
      bankBookedAt,
      accountCurrency,
      accountAmount,
      cashLocal;
  factory CustomerActualReceipt.fromJson(Map<String, dynamic> j) =>
      CustomerActualReceipt(
        id: j['receiptId'].toString(),
        billNo: j['billNo']?.toString() ?? '',
        bankBookedAt: j['bankBookedAt']?.toString() ?? '',
        accountCurrency: j['accountCurrency']?.toString() ?? '',
        accountAmount: j['accountAmount']?.toString() ?? '',
        cashLocal: j['cashLocal']?.toString() ?? '',
      );
}
