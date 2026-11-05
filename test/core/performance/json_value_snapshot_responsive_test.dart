import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/json_value_snapshot.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

void main() {
  test(
    'large original commands retain order, exact text and numeric spellings while detaching containers',
    () async {
      final original = <String, dynamic>{
        'documents': [
          for (var index = 0; index < 10000; index++)
            {
              'position': index,
              'amount': '0.000000000000000000000001',
              'rate': '7.000000000000000000000001',
              'number': 1.0,
            },
        ],
      };
      final copy =
          await snapshotJsonValueResponsive(original) as Map<String, dynamic>;
      expect(await jsonValuesEqualResponsive(original, copy), isTrue);
      expect(
        () => (copy['documents'] as List).add(<String, dynamic>{}),
        throwsUnsupportedError,
      );
      (original['documents'] as List<Map<String, dynamic>>).last['amount'] =
          '0.000000000000000000000002';
      expect(await jsonValuesEqualResponsive(original, copy), isFalse);
      expect(
        ((copy['documents'] as List).last as Map)['amount'],
        '0.000000000000000000000001',
      );
      expect(await jsonValuesEqualResponsive({'n': 1}, {'n': 1.0}), isFalse);
      expect(await jsonValuesEqualResponsive({'n': -0.0}, {'n': 0.0}), isFalse);
    },
  );
  test(
    'a superseded large comparison yields to input and never publishes a partial proof',
    () async {
      var current = true;
      final first = <String, dynamic>{
        'documents': [
          for (var index = 0; index < 20000; index++)
            {'position': index, 'amount': '$index.000000000000000000000001'},
        ],
      };
      final second = <String, dynamic>{
        'documents': [
          for (var index = 0; index < 20000; index++)
            {'position': index, 'amount': '$index.000000000000000000000001'},
        ],
      };
      Timer.run(() => current = false);
      await expectLater(
        jsonValuesEqualResponsive(first, second, isCurrent: () => current),
        throwsA(isA<UiWorkCancelled>()),
      );
    },
  );
  test(
    'a superseded large detach preserves the original input and returns no partial snapshot',
    () async {
      var current = true;
      final original = <String, dynamic>{
        'documents': [
          for (var index = 0; index < 20000; index++)
            {'position': index, 'amount': '12.'},
        ],
      };
      Timer.run(() => current = false);
      await expectLater(
        snapshotJsonValueResponsive(original, isCurrent: () => current),
        throwsA(isA<UiWorkCancelled>()),
      );
      expect((original['documents'] as List).length, 20000);
      expect(((original['documents'] as List).last as Map)['amount'], '12.');
    },
  );
}
