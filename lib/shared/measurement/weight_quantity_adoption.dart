import '../../core/network/business_precision.dart';
import '../formatters/exact_decimal.dart';
import 'weight_predictor.dart';

/// A scale-assisted input, never a new observed sample or a rounded whole count.
/// Statistical estimates retain the model's complete binary64 decimal text.
/// Exact mass goods use the original decimal ratio, with one policy only at the
/// final line-quantity field. The predictor and its uncertainty are unchanged.
class WeightQuantityAdoption {
  const WeightQuantityAdoption({this.qty, this.baseQty, this.reason});
  final String? qty, baseQty, reason;
}

WeightQuantityAdoption resolveWeightQuantityAdoption({
  required String? netKg,
  required String? unitRate,
  String? exactMassFactorKg,
  CountEstimate? estimate,
  BusinessPrecisionChoice? choice,
}) {
  final rate = financeExactTrimmed(financeExactDecimal(unitRate));
  if (rate == null || rate == '0' || rate.startsWith('-')) {
    return const WeightQuantityAdoption();
  }
  final numerator = exactMassFactorKg != null
      ? netKg
      : financeExactDecimal(estimate?.estimatedQty);
  final denominator = exactMassFactorKg != null
      ? financeExactMultiplyTexts([exactMassFactorKg, rate])
      : rate;
  final result = financeExactDivideTexts(
    numerator,
    denominator,
    choiceScale: choice?.scale,
    choiceRounding: choice?.rounding,
  );
  return WeightQuantityAdoption(
    qty: result.text,
    baseQty: result.text == null
        ? null
        : financeExactTrimmed(financeExactMultiplyTexts([result.text, rate])),
    reason: result.text == null ? result.reason : null,
  );
}
