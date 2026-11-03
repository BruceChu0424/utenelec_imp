import 'package:flutter/material.dart';

import 'china_datetime.dart';

/// Calendar-month default in the same date-only wall clock as API filters.
/// March 31 goes back to February's last day, without overflowing into March.
DateTime recentMonthStart({DateTime? today}) {
  final end = today ?? ChinaDateTime.today();
  final previous = DateTime.utc(end.year, end.month - 1);
  final lastDay = DateTime.utc(previous.year, previous.month + 1, 0).day;
  return DateTime.utc(previous.year, previous.month, end.day.clamp(1, lastDay));
}

DateTimeRange recentMonthDateRange({DateTime? today}) {
  final now = today ?? ChinaDateTime.today();
  final end = DateTime.utc(now.year, now.month, now.day);
  return DateTimeRange(
    start: recentMonthStart(today: end),
    end: end,
  );
}
