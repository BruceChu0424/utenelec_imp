import '../formatters/exact_decimal.dart';

class ExactMeasuredAmount {
  const ExactMeasuredAmount({
    required this.value,
    required this.unitId,
    this.unitName,
  });
  final String? value;
  final String? unitId;
  final String? unitName;
}

/// Aggregate recorded decimal texts only within the same unit UUID. Missing
/// quantities remain unknown; a missing fact must not silently contribute zero.
String exactMeasurementTotalsText(
  Iterable<ExactMeasuredAmount> amounts, {
  String missingUnitLabel = '单位未维护',
  String unknownQuantityLabel = '数量未留存',
  String emptyLabel = '—',
}) {
  const missingKey = '\u0000missing-unit';
  final grouped = <String, List<String?>>{};
  final names = <String, String>{};
  final missingOrder = <String, int>{};
  for (final amount in amounts) {
    final unitId = amount.unitId?.trim();
    final key = unitId == null || unitId.isEmpty
        ? '$missingKey-${missingOrder.length}'
        : unitId;
    if (unitId == null || unitId.isEmpty) {
      missingOrder[key] = missingOrder.length;
    }
    grouped.putIfAbsent(key, () => []).add(amount.value);
    final name = amount.unitName?.trim();
    if (name != null && name.isNotEmpty) names.putIfAbsent(key, () => name);
  }
  final keys = grouped.keys.toList()
    ..sort((a, b) {
      if (missingOrder.containsKey(a)) {
        return missingOrder.containsKey(b)
            ? missingOrder[a]!.compareTo(missingOrder[b]!)
            : 1;
      }
      if (missingOrder.containsKey(b)) return -1;
      return a.compareTo(b);
    });
  if (keys.isEmpty) return emptyLabel;
  return keys
      .map((key) {
        final value = financeExactSumTexts(grouped[key]!);
        final unit = names[key] ?? missingUnitLabel;
        return '${value == null ? unknownQuantityLabel : financeExactTrimmed(value)} $unit';
      })
      .join(' · ');
}
