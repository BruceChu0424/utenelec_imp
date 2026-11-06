import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_insight.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_insight_tables.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_text.dart';

void main() {
  const raw = '-0.00000000000002220446049250313';

  test(
    'persisted statistical deviation keeps the server decimal in both readers',
    () {
      final observation = WeightObservation.fromJson({
        'id': 'observation',
        'deviationPct': -2.2e-14,
        'deviationPctExact': raw,
      });
      final alert = InsightWeightAlertRow.fromJson({
        'id': 'alert',
        'goodsId': 'goods',
        'deviationPct': -2.2e-14,
        'deviationPctExact': raw,
      });
      expect(observation.deviationPctText, raw);
      expect(alert.deviationPctText, raw);
      expect(formatSignedPct(observation.deviationPctText!), '$raw%');
      final column = insightWeightAlertColumns(
        billCell: (_, _) => const SizedBox(),
      ).singleWhere((column) => column.key == 'deviation');
      expect(column.value(alert), '($raw%)');
    },
  );

  test(
    'older numeric response and absent statistics keep their existing meaning',
    () {
      expect(
        WeightObservation.fromJson({
          'id': 'old',
          'deviationPct': 3.5,
        }).deviationPctText,
        '3.5',
      );
      expect(
        InsightWeightAlertRow.fromJson({
          'id': 'empty',
          'goodsId': 'g',
        }).deviationPctText,
        isNull,
      );
    },
  );
}
