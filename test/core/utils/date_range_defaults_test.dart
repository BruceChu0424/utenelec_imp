import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/utils/date_range_defaults.dart';

void main() {
  final contract =
      jsonDecode(
            File('contracts/date-range-selection/v1.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final raw in contract['recentMonthCases'] as List) {
    final example = Map<String, String>.from(raw as Map);
    test('shared recent month date vector ${example['today']}', () {
      final range = recentMonthDateRange(
        today: DateTime.parse(example['today']!),
      );
      expect(range.start, DateTime.parse('${example['start']}T00:00:00Z'));
      expect(range.end, DateTime.parse('${example['end']}T00:00:00Z'));
      expect(range.start.hour, 0);
      expect(range.end.hour, 0);
    });
  }
}
