import 'exact_decimal.dart';

String? validateFinanceAmount(String? value, {String label = '金额'}) =>
    _validateExactFinanceAmount(
      value,
      label: label,
      positive: true,
      scale: financeAmountScale,
    );

String? validateNonNegativeFinanceAmount(
  String? value, {
  String label = '金额',
}) => _validateExactFinanceAmount(
  value,
  label: label,
  positive: false,
  scale: financeAmountScale,
);

String? validateNonNegativeFinanceBookAmount(
  String? value, {
  String label = '金额',
}) => _validateExactFinanceAmount(
  value,
  label: label,
  positive: false,
  scale: 30,
);

String? _validateExactFinanceAmount(
  String? value, {
  required String label,
  required bool positive,
  required int scale,
  bool signed = false,
}) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return '请填写$label';
  if (raw.length > 200) return '$label过长，请核对原始金额';
  var canonical = financeExactDecimal(raw);
  if (canonical == null) return '请填写有效的$label';
  if (canonical.contains('.')) {
    canonical = canonical
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  final units = financeExactDecimalUnits(canonical, scale: scale);
  if (units == null || units.abs() >= BigInt.from(10).pow(40 + scale)) {
    return '$label最多 40 位整数、$scale 位小数，请核对原值';
  }
  if ((!signed && units.isNegative) || (positive && units == BigInt.zero)) {
    return positive ? '$label必须大于 0' : '$label不能是负数';
  }
  return null;
}

/// Explicit original-currency facts may carry either natural balance direction.
String? validateSignedFinanceAmount(String? value, {String label = '原币金额'}) =>
    _validateExactFinanceAmount(
      value,
      label: label,
      positive: false,
      scale: financeAmountScale,
      signed: true,
    );
