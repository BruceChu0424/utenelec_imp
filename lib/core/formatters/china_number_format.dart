import 'package:intl/intl.dart';

/// 中国大陆企业界面统一数值格式：千分位、半角小数点。
String formatChinaNumber(num value, {int decimalDigits = 2}) {
  final digits = decimalDigits.clamp(0, 6);
  final decimals = digits == 0 ? '' : '.${List.filled(digits, '0').join()}';
  return NumberFormat('#,##0$decimals', 'zh_CN').format(value);
}
