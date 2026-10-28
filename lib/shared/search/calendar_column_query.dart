/// Business calendar conditions aligned with JpaColumnSearch.businessDateBounds.
/// Local views compare their actual displayed day; server timestamps use the
/// same calendar boundaries in the company's Asia/Shanghai timezone.
class CalendarColumnQuery {
  CalendarColumnQuery._(this.from, this.toExclusive);
  final DateTime from;
  final DateTime toExclusive;

  static const help = '日期：YYYY、YYYY-MM、YYYY-MM-DD，或起止日期用 .. 连接';
  static const error = '请输入有效日期或范围，例如 2026-10、2026-10-01..2026-10-31';

  static CalendarColumnQuery? tryParse(String text) {
    final value = text.trim();
    if (value.isEmpty || value.length > 128) return null;
    final parts = value.split('..');
    if (parts.length > 2) return null;
    final lower = _period(parts.first.trim());
    final upper = _period(parts.last.trim());
    if (lower == null || upper == null || !lower.$1.isBefore(upper.$2)) {
      return null;
    }
    return CalendarColumnQuery._(lower.$1, upper.$2);
  }

  bool matches(String? displayedDate) {
    if (displayedDate == null) return false;
    // Missing/relative/partial dates are not guessed to be a first day.
    final match = RegExp(
      r'^\d{4}-\d{2}-\d{2}(?=$|[ T])',
    ).firstMatch(displayedDate.trim());
    if (match == null) return false;
    final day = _period(match.group(0)!.substring(0, 10));
    return day != null &&
        !day.$1.isBefore(from) &&
        day.$1.isBefore(toExclusive);
  }

  static (DateTime, DateTime)? _period(String text) {
    final match = RegExp(
      r'^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$',
    ).firstMatch(text);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2) ?? '1');
    final day = int.parse(match.group(3) ?? '1');
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final start = DateTime.utc(year, month, day);
    if (start.year != year || start.month != month || start.day != day) {
      return null;
    }
    final end = match.group(3) != null
        ? DateTime.utc(year, month, day + 1)
        : match.group(2) != null
        ? DateTime.utc(year, month + 1)
        : DateTime.utc(year + 1);
    return (start, end);
  }
}
