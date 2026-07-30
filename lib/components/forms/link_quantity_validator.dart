/// Validates a quantity entered while linking an upstream document item.
///
/// [remaining] must be calculated from the quantity and cumulative counters
/// returned by the server for that upstream item.
String? validateLinkQuantity(String raw, {required double remaining}) {
  final value = double.tryParse(raw.trim());
  if (value == null || !value.isFinite || value <= 0) {
    return '请输入大于 0 的本次数量';
  }
  if (!remaining.isFinite || remaining <= 0) {
    return '该明细已无剩余可引入数量';
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
  final fixed = value.toStringAsFixed(6);
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
