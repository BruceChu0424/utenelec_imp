import 'china_datetime.dart';
import 'date_range_defaults.dart';

String _text(String languageCode, String zh, String en, String ko) =>
    switch (languageCode) {
      'en' => en,
      'ko' => ko,
      _ => zh,
    };

/// Presentation only: retain the selected wall dates and count both endpoints.
/// A historical or future interval must never be described as "recent".
String compactDateRangeLabel({
  DateTime? from,
  DateTime? to,
  DateTime? today,
  String languageCode = 'zh',
}) {
  if (from == null && to == null) {
    return _text(languageCode, '选择日期', 'Select dates', '날짜 선택');
  }
  if (to == null) {
    return _text(
      languageCode,
      '${dateRangeDisplayDate(from!)}起',
      'From ${dateRangeDisplayDate(from)}',
      '${dateRangeDisplayDate(from)}부터',
    );
  }
  if (from == null) {
    return _text(
      languageCode,
      '截至${dateRangeDisplayDate(to)}',
      'Until ${dateRangeDisplayDate(to)}',
      '${dateRangeDisplayDate(to)}까지',
    );
  }
  final start = ChinaDateTime.dateOnly(from);
  final end = ChinaDateTime.dateOnly(to);
  final now = ChinaDateTime.dateOnly(today ?? ChinaDateTime.today());
  final days = end.difference(start).inDays + 1;
  if (days <= 0) {
    return _text(languageCode, '日期范围', 'Date range', '날짜 범위');
  }
  if (end == now) {
    if (days == 1) return _text(languageCode, '今天', 'Today', '오늘');
    if (start == recentMonthStart(today: now)) {
      return _text(languageCode, '近1个月', 'Last month', '최근 1개월');
    }
    return _text(languageCode, '近$days天', 'Last $days days', '최근 $days일');
  }
  return _text(languageCode, '共$days天', '$days days', '총 $days일');
}

String dateRangeDisplayDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}.'
    '${date.month.toString().padLeft(2, '0')}.'
    '${date.day.toString().padLeft(2, '0')}';

String dateRangeTooltip({
  DateTime? from,
  DateTime? to,
  String languageCode = 'zh',
  String? openStartLabel,
  String? openEndLabel,
  String? emptyLabel,
}) => switch ((from, to)) {
  (final DateTime start, final DateTime end) =>
    '${dateRangeDisplayDate(start)}-${dateRangeDisplayDate(end)}',
  (final DateTime start, null) =>
    openEndLabel == null
        ? compactDateRangeLabel(from: start, languageCode: languageCode)
        : '${dateRangeDisplayDate(start)}-$openEndLabel',
  (null, final DateTime end) =>
    openStartLabel == null
        ? compactDateRangeLabel(to: end, languageCode: languageCode)
        : '$openStartLabel-${dateRangeDisplayDate(end)}',
  _ =>
    emptyLabel ??
        (openStartLabel == null && openEndLabel == null
            ? _text(languageCode, '全部日期', 'All dates', '전체 날짜')
            : '${openStartLabel ?? _text(languageCode, '不限开始', 'No start', '시작 제한 없음')}-'
                  '${openEndLabel ?? _text(languageCode, '不限结束', 'No end', '종료 제한 없음')}'),
};
