/// Exact material quantities and editing allocations. Persisted source facts
/// are never coarsened and every non-finite calculation needs a current choice.
library;

import '../../../core/formatters/exact_number_text.dart';
import '../../../shared/formatters/exact_decimal.dart';

/// All source/request quantities retain 24 fractional digits. The older
/// presentation wrappers above are not used by the command path.
const materialQuantityScale = 24;

class MaterialQuantityPrecisionRequired extends FormatException {
  const MaterialQuantityPrecisionRequired(
    this.reason, {
    this.exceedsTotal = false,
  }) : super('本次来源分配需要明确选择精度，原输入和总量已保留');
  final String reason;
  final bool exceedsTotal;
}

BigInt materialQuantityUnits(String raw, {int scale = materialQuantityScale}) {
  final text = financeExactTrimmed(raw.trim().replaceFirst(RegExp(r'\.$'), ''));
  final units = financeExactDecimalUnits(text, scale: scale);
  if (units == null || units.isNegative) {
    throw const FormatException('数量必须为非负数，最多24位小数；原输入已保留');
  }
  return units;
}

String materialQuantityText(
  BigInt units, {
  int scale = materialQuantityScale,
}) => financeExactTrimmed(financeExactDecimalFromUnits(units, scale: scale))!;

/// Existing source shares are facts: neither their sum nor the individual
/// shares can be coarsened using a former rounding/noise budget.
String? coalescedAggregateTotalText(Iterable<String> partTexts) {
  final parts = partTexts.toList();
  if (parts.isEmpty) return null;
  try {
    return materialQuantityText(
      parts.fold(BigInt.zero, (sum, text) => sum + materialQuantityUnits(text)),
    );
  } on FormatException {
    return null;
  }
}

List<String> coalescedAggregateShareTexts(List<String> partTexts) => [
  for (final part in partTexts)
    materialQuantityText(materialQuantityUnits(part)),
];

String materialQuantityFact(String? exact, double legacy) {
  if (exact != null) return materialQuantityText(materialQuantityUnits(exact));
  if (!legacy.isFinite || legacy.abs() >= 10000000000) return 'NaN';
  return materialQuantityText(materialQuantityUnits(legacy.toExactString()));
}

String materialUnitRateFact(String? exact, double? legacy) {
  if (exact == null && legacy == null) return '1';
  if (exact == null &&
      (!legacy!.isFinite || legacy <= 0 || legacy >= 1000000)) {
    throw const FormatException('缺少精确单位比例，请刷新或更新服务端');
  }
  final units = materialQuantityUnits(exact ?? legacy!.toExactString());
  if (units <= BigInt.zero) throw const FormatException('单位比例必须为正数');
  return materialQuantityText(units);
}

String materialQuantityProduct(String left, String right) {
  final product = financeExactTrimmed(financeExactMultiplyTexts([left, right]));
  if (product == null) throw const FormatException('数量单位换算缺少精确值');
  return product;
}

String materialQuantityQuotient(
  String quantity,
  String rate, {
  int? precisionScale,
  String? precisionRounding,
}) {
  final denominator = materialQuantityUnits(rate);
  if (denominator <= BigInt.zero) throw const FormatException('数量单位换算比例无效');
  final result = financeExactDivideTexts(
    quantity,
    rate,
    choiceScale: precisionScale,
    choiceRounding: precisionRounding,
  );
  if (result.text == null) {
    throw MaterialQuantityPrecisionRequired(result.reason ?? 'PRECISION_LIMIT');
  }
  return result.text!;
}

/// Supplier minimum/multiple policy is an explicit business quantity rule,
/// independent of numeric display precision. Its existing ceiling is retained.
String materialQuantityWithOrderPolicy(
  String quantity,
  String minimum,
  String multiple,
) {
  var value = materialQuantityUnits(quantity);
  if (value == BigInt.zero) return '0';
  final floor = materialQuantityUnits(minimum),
      step = materialQuantityUnits(multiple);
  if (value < floor) value = floor;
  if (step > BigInt.zero) value = ((value + step - BigInt.one) ~/ step) * step;
  return materialQuantityText(value);
}

/// Finite source allocations are exact. When an explicit policy is necessary,
/// the last participating source takes the exact remainder, never changing the
/// user's total. An excessive HALF_UP result fails without silently subtracting
/// a tick from another source.
List<String> splitTypedTotalText(
  String total,
  List<String> needs, {
  int? precisionScale,
  String? precisionRounding,
}) {
  final totalUnits = materialQuantityUnits(total);
  final source = [for (final need in needs) materialQuantityUnits(need)];
  if (source.isEmpty) return const [];
  if (totalUnits == BigInt.zero) return [for (final _ in source) '0'];
  final required = source.fold(BigInt.zero, (sum, value) => sum + value);
  final extraMode = totalUnits >= required;
  final positive = [
    for (var i = 0; i < source.length; i++)
      if (source[i] > BigInt.zero) i,
  ];
  final recipients = positive.isEmpty
      ? [for (var i = 0; i < source.length; i++) i]
      : positive;
  final budget = extraMode ? totalUnits - required : totalUnits;
  final shares = [for (final _ in source) BigInt.zero];
  var used = BigInt.zero;
  for (var index = 0; index < recipients.length; index++) {
    final recipient = recipients[index];
    BigInt allocated;
    if (index == recipients.length - 1) {
      allocated = budget - used;
      if (allocated.isNegative) {
        throw const MaterialQuantityPrecisionRequired(
          'PRECISION_LIMIT',
          exceedsTotal: true,
        );
      }
    } else {
      final numerator = extraMode
          ? materialQuantityText(budget)
          : materialQuantityProduct(
              materialQuantityText(budget),
              materialQuantityText(source[recipient]),
            );
      final denominator = extraMode
          ? '${recipients.length}'
          : materialQuantityText(required);
      final result = financeExactDivideTexts(
        numerator,
        denominator,
        choiceScale: precisionScale,
        choiceRounding: precisionRounding,
      );
      if (result.text == null) {
        throw MaterialQuantityPrecisionRequired(
          result.reason ?? 'PRECISION_LIMIT',
        );
      }
      allocated = materialQuantityUnits(result.text!);
      used += allocated;
    }
    shares[recipient] = allocated;
  }
  if (extraMode) {
    for (var i = 0; i < source.length; i++) {
      shares[i] += source[i];
    }
  }
  if (shares.fold(BigInt.zero, (sum, value) => sum + value) != totalUnits) {
    throw const FormatException('来源份额与原总量不一致，原输入已保留');
  }
  return [for (final share in shares) materialQuantityText(share)];
}
