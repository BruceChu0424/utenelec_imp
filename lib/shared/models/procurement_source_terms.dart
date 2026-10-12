import '../formatters/exact_decimal.dart';

/// Commercial facts selected with source lines, including the approved receipt rate.
class ProcurementSourceTerms {
  const ProcurementSourceTerms({
    this.currencyId,
    this.exchangeRate,
    this.taxRate,
    this.settlementMethodId,
  });

  final String? currencyId;
  final String? exchangeRate;
  final String? taxRate;
  final String? settlementMethodId;

  bool compatibleWith(ProcurementSourceTerms other) =>
      _sameKnown(currencyId, other.currencyId) &&
      _sameKnown(
        financeExactTrimmed(exchangeRate),
        financeExactTrimmed(other.exchangeRate),
      ) &&
      _sameKnown(
        financeExactTrimmed(taxRate),
        financeExactTrimmed(other.taxRate),
      ) &&
      _sameKnown(settlementMethodId, other.settlementMethodId);

  static bool _sameKnown(String? left, String? right) =>
      left == null || right == null || left == right;

  Map<String, dynamic> toJson() => {
    'currencyId': currencyId,
    'exchangeRate': exchangeRate,
    'taxRate': taxRate,
    'settlementMethodId': settlementMethodId,
  };

  factory ProcurementSourceTerms.fromJson(Map<String, dynamic> json) =>
      ProcurementSourceTerms(
        currencyId: json['currencyId'] as String?,
        exchangeRate: json['exchangeRate'] as String?,
        taxRate: json['taxRate'] as String?,
        settlementMethodId: json['settlementMethodId'] as String?,
      );
}
