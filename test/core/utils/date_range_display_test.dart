import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/utils/date_range_display.dart';

void main() {
  final contract =
      jsonDecode(
            File('contracts/date-range-selection/v1.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final raw in contract['displayCases'] as List) {
    final sample = raw as Map<String, dynamic>;
    test('shared range display ${sample['name']}', () {
      final from = DateTime.tryParse(sample['start'] as String? ?? '');
      final to = DateTime.tryParse(sample['end'] as String? ?? '');
      expect(
        compactDateRangeLabel(
          from: from,
          to: to,
          today: DateTime.parse(sample['today'] as String),
        ),
        sample['label'],
      );
      expect(dateRangeTooltip(from: from, to: to), sample['tooltip']);
    });
  }

  test('wall dates ignore clock time, local zone and DST duration', () {
    expect(
      compactDateRangeLabel(
        from: DateTime(2026, 3, 7, 23, 59),
        to: DateTime.utc(2026, 3, 9, 0, 1),
        today: DateTime(2026, 3, 9, 20),
      ),
      '近3天',
    );
  });

  test('open range tooltip retains business meanings and localized text', () {
    expect(
      dateRangeTooltip(from: DateTime(2026, 10), openEndLabel: '未安排完工'),
      '2026.10.01-未安排完工',
    );
    expect(
      dateRangeTooltip(to: DateTime(2026, 10), openStartLabel: '未安排开工'),
      '未安排开工-2026.10.01',
    );
    expect(dateRangeTooltip(emptyLabel: '未选择日期'), '未选择日期');
    expect(
      compactDateRangeLabel(
        from: DateTime(2026, 10),
        to: DateTime(2026, 10, 2),
        today: DateTime(2026, 10, 2),
        languageCode: 'en',
      ),
      'Last 2 days',
    );
    expect(
      compactDateRangeLabel(
        from: DateTime(2026, 10),
        to: DateTime(2026, 10, 2),
        today: DateTime(2026, 10, 3),
        languageCode: 'ko',
      ),
      '총 2일',
    );
  });
}
