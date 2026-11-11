import '../../shared/formatters/exact_decimal.dart';
import '../../core/formatters/exact_number_text.dart';

/// Validates a quantity entered while linking an upstream document item.
///
/// [remaining] must be calculated from the quantity and cumulative counters
/// returned by the server for that upstream item.
///
/// [allowOverRemaining] (2026-09 订货超采放开): skip the "at most remaining"
/// cap while keeping the positive-number check — ordering more than the
/// planned/approved remainder is a business-approved scenario for purchase
/// and subcontract orders. Receipt/return links keep the cap.
String? validateLinkQuantity(
  String raw, {
  required double remaining,
  String? remainingText,
  bool allowOverRemaining = false,
}) {
  if (remainingText != null) {
    final value = financeExactDecimalUnits(raw);
    if (value == null || value <= BigInt.zero) return '请输入大于 0 的本次数量（最多四位小数）';
    final limit = financeExactDecimalUnits(remainingText);
    if (limit == null || limit <= BigInt.zero) return '该明细已无可核对的剩余可引入数量';
    if (!allowOverRemaining && value > limit) return '本次数量最多为 $remainingText';
    return null;
  }
  final value = double.tryParse(raw.trim());
  if (value == null || !value.isFinite || value <= 0) {
    return '请输入大于 0 的本次数量';
  }
  if (!remaining.isFinite || remaining <= 0) {
    return '该明细已无剩余可引入数量';
  }
  if (allowOverRemaining) {
    return null;
  }
  final scale = value.abs() > remaining.abs() ? value.abs() : remaining.abs();
  final tolerance = scale * 1e-9;
  if (value - remaining > tolerance) {
    return '本次数量最多为 ${formatLinkQuantity(remaining)}';
  }
  return null;
}

/// Formats quantities without unnecessary trailing zeroes.
String formatLinkQuantity(double value) {
  final fixed = value.toExactString(minimumFractionDigits: 6);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Issues monotonically increasing tokens for link-picker requests.
///
/// A response may update UI state only while [isCurrent] returns true for the
/// token captured before that request started.
class LatestLinkRequestGuard {
  int _version = 0;

  int begin() => ++_version;

  void invalidate() => _version++;

  bool isCurrent(int requestVersion) => requestVersion == _version;
}

/// Exact source-bound checks used after upstream imports and draft restoration.
String? validateExactLinkedCapacity(String quantity, String remaining) {
  final value = financeExactDecimalUnits(quantity);
  final limit = financeExactDecimalUnits(remaining);
  if (value == null || value < BigInt.zero) return '数量必须为非负数且最多四位小数';
  if (limit == null || limit < BigInt.zero) return '来源剩余数量无法精确核对，请重新引入来源';
  return value > limit ? '数量不能超过来源剩余量 $remaining' : null;
}
