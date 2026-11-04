import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

void main() {
  final contract =
      jsonDecode(
            File('contracts/business-precision/v1.json').readAsStringSync(),
          )
          as Map;
  for (final raw in contract['cases'] as List) {
    final sample = raw as Map;
    test('shared decimal contract: ${sample['id']}', () {
      final choice = sample['choice'] as Map?;
      final result = financeExactDivideTexts(
        sample['numerator'] as String,
        sample['denominator'] as String,
        maxScale: sample['maxScale'] as int,
        choiceScale: choice?['scale'] as int?,
        choiceRounding: choice?['rounding'] as String?,
      );
      expect(result.text, sample['expected']);
      expect(result.reason, sample['required']);
    });
  }
}
