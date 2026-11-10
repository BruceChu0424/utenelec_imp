import '../../../shared/formatters/exact_decimal.dart';

/// Legacy linked sales documents use null/zero for the original price.
/// This is presentation only: the immutable source and server amount stay intact.
String salesSourceDiscountText(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '1';
  final exact = financeExactTrimmed(raw);
  return exact == '0' ? '1' : exact ?? raw.trim();
}
