/// Exact, presentation-only numeric conditions. Keep the grammar aligned with
/// the server's NumericColumnFilter; neither side rounds recorded decimals.
class NumericColumnQuery {
  NumericColumnQuery._(this.operator, this.lower, [this.upper]);

  final String operator;
  final ColumnDecimal lower;
  final ColumnDecimal? upper;

  static const help = '输入数字、>0、<=10 或 -5..5（含两端）';
  static const error = '请输入有效数字或范围，例如 >0、-5..5';

  static NumericColumnQuery? tryParse(String text) {
    final query = text.trim();
    if (query.isEmpty || query.length > 128) return null;
    final range = query.split('..');
    if (range.length == 2) {
      final lower = ColumnDecimal.tryParse(range[0].trim());
      final upper = ColumnDecimal.tryParse(range[1].trim());
      if (lower == null || upper == null || lower.compareTo(upper) > 0) {
        return null;
      }
      return NumericColumnQuery._('range', lower, upper);
    }
    final match = RegExp(
      r'^(<=|>=|!=|=|<|>)?\s*([+-]?\d+(?:\.\d+)?)$',
    ).firstMatch(query);
    if (match == null) return null;
    final value = ColumnDecimal.tryParse(match.group(2)!);
    return value == null
        ? null
        : NumericColumnQuery._(match.group(1) ?? '=', value);
  }

  /// Null/unknown values never become zero and never satisfy even !=.
  bool matches(String? exact) {
    final value = ColumnDecimal.tryParse(exact?.trim() ?? '');
    if (value == null) return false;
    final comparison = value.compareTo(lower);
    return switch (operator) {
      '=' => comparison == 0,
      '!=' => comparison != 0,
      '>' => comparison > 0,
      '>=' => comparison >= 0,
      '<' => comparison < 0,
      '<=' => comparison <= 0,
      'range' => comparison >= 0 && value.compareTo(upper!) <= 0,
      _ => false,
    };
  }
}

/// Only a single displayed measure may supply a fallback. An explicit exact
/// accessor takes precedence, including its null (masked/unavailable) result.
/// Do not parse approximate values, compound summaries, or convert units here.
String? displayedColumnDecimal(String? text) {
  if (text == null) return null;
  final match = RegExp(
    r'^([+-]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)(?:\s+[^\d/\n]+|\s*[%％])?$',
  ).firstMatch(text.trim());
  return match?.group(1)?.replaceAll(',', '');
}

class ColumnDecimal {
  ColumnDecimal._(this.units, this.scale);
  final BigInt units;
  final int scale;

  static ColumnDecimal? tryParse(String value) {
    if (value.isEmpty || value.length > 1024) return null;
    final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(value);
    if (match == null) return null;
    final fraction = match.group(3) ?? '';
    final unsigned = BigInt.parse('${match.group(2)}$fraction');
    return ColumnDecimal._(
      match.group(1) == '-' ? -unsigned : unsigned,
      fraction.length,
    );
  }

  int compareTo(ColumnDecimal other) {
    final commonScale = scale > other.scale ? scale : other.scale;
    return (units * BigInt.from(10).pow(commonScale - scale)).compareTo(
      other.units * BigInt.from(10).pow(commonScale - other.scale),
    );
  }
}
