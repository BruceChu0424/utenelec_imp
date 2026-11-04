import 'exact_number_text.dart';

/// 千分位、半角小数点。[decimalDigits] is minimum zero padding, never a
/// precision cap: every finite input digit survives display/copy/export.
String formatChinaNumber(Object value, {int decimalDigits = 2}) =>
    exactNumberDisplay(
      value,
      minimumFractionDigits: decimalDigits,
      groupThousands: true,
    ) ??
    value.toString();
