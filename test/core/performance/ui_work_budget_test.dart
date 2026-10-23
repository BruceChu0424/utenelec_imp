import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

void main() {
  test(
    'large conversion lets queued input turns run before completion',
    () async {
      var inputTurns = 0;
      var completed = false;
      void inputTurn() {
        if (!completed) {
          inputTurns++;
          Timer.run(inputTurn);
        }
      }

      Timer.run(inputTurn);
      final result = await mapInUiSlices<int, int>(
        List.generate(1025, (index) => index),
        (value) => value * 2,
        budget: UiWorkBudget(maxItems: 64),
      );
      completed = true;
      expect(inputTurns, greaterThanOrEqualTo(16));
      expect(result, List.generate(1025, (index) => index * 2));
    },
  );

  test(
    'superseded conversion stops before processing the whole input',
    () async {
      var current = true;
      var converted = 0;
      Timer.run(() => current = false);
      await expectLater(
        mapInUiSlices<int, int>(
          List.generate(1000, (index) => index),
          (value) {
            converted++;
            return value;
          },
          budget: UiWorkBudget(maxItems: 8, isCurrent: () => current),
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
      expect(converted, lessThan(1000));
    },
  );

  test('source membership is fixed before yielding to an edit', () async {
    final values = List.generate(20, (index) => index);
    Timer.run(() => values.clear());
    final result = await mapInUiSlices<int, int>(
      values,
      (value) => value,
      budget: UiWorkBudget(maxItems: 2),
    );
    expect(values, isEmpty);
    expect(result, List.generate(20, (index) => index));
  });

  test(
    'conversion failures preserve their original type and result is atomic',
    () async {
      await expectLater(
        mapInUiSlices<int, int>([1, 2, 3], (value) {
          if (value == 2) throw const FormatException('invalid row');
          return value;
        }),
        throwsFormatException,
      );
    },
  );
}
