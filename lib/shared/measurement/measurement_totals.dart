/// Shared quantity aggregation that never adds values from different units.
///
/// [unitId] is the grouping authority. Display names are labels only: two rows
/// with the same name but different UUIDs remain separate, while rows without a
/// UUID are collected in an explicit missing-unit bucket.
class MeasuredAmount {
  const MeasuredAmount({
    required this.value,
    required this.unitId,
    this.unitName,
  });

  final double value;
  final String? unitId;
  final String? unitName;
}

class MeasurementTotal {
  const MeasurementTotal({
    required this.unitId,
    required this.unitName,
    required this.value,
    required this.rowCount,
  });

  final String? unitId;
  final String? unitName;
  final double value;
  final int rowCount;

  bool get missingUnit => unitId == null;
}

List<MeasurementTotal> groupMeasurementTotals(
  Iterable<MeasuredAmount> amounts,
) {
  const missingKey = '\u0000missing-unit';
  final totals = <String, double>{};
  final counts = <String, int>{};
  final ids = <String, String?>{};
  final names = <String, String?>{};

  for (final amount in amounts) {
    if (!amount.value.isFinite) continue;
    final normalizedId = amount.unitId?.trim();
    final id = normalizedId == null || normalizedId.isEmpty
        ? null
        : normalizedId;
    final key = id ?? missingKey;
    final normalizedName = amount.unitName?.trim();
    totals[key] = (totals[key] ?? 0) + amount.value;
    counts[key] = (counts[key] ?? 0) + 1;
    ids[key] = id;
    if ((names[key] == null || names[key]!.isEmpty) &&
        normalizedName != null &&
        normalizedName.isNotEmpty) {
      names[key] = normalizedName;
    }
  }

  final keys = totals.keys.toList()
    ..sort((left, right) {
      if (left == missingKey) return 1;
      if (right == missingKey) return -1;
      return left.compareTo(right);
    });
  return [
    for (final key in keys)
      MeasurementTotal(
        unitId: ids[key],
        unitName: names[key],
        value: totals[key]!,
        rowCount: counts[key]!,
      ),
  ];
}

String measurementTotalsText(
  Iterable<MeasuredAmount> amounts, {
  String Function(double value) formatValue = formatMeasurementValue,
  String missingUnitLabel = '单位未维护',
  String emptyLabel = '—',
}) {
  final totals = groupMeasurementTotals(amounts);
  if (totals.isEmpty) return emptyLabel;
  return totals
      .map((total) {
        final unit = total.missingUnit
            ? missingUnitLabel
            : (total.unitName?.isNotEmpty == true
                  ? total.unitName!
                  : total.unitId!);
        return '${formatValue(total.value)} $unit';
      })
      .join(' · ');
}

String formatMeasurementValue(double value, {int scale = 4}) {
  final fixed = value.toStringAsFixed(scale);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}
