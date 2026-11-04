/// Decimal text ownership shared by business formatting. No floating-point
/// arithmetic, fixed precision conversion, rounding or truncation is used.
String? exactNumberText(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num && !value.isFinite) {
    return null;
  }
  final raw = value.toString().trim();
  if (raw.length > 4096) {
    return null;
  }
  final match = RegExp(
    r'^([+-]?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$',
  ).firstMatch(raw);
  if (match == null) {
    return null;
  }
  final integer = match.group(2)!,
      fraction = match.group(3) ?? '',
      digits = '$integer$fraction';
  final exponent = int.tryParse(match.group(4) ?? '0');
  if (exponent == null || exponent.abs() > 4096) {
    return null;
  }
  final point = integer.length + exponent;
  if (point.abs() + digits.length > 4096) {
    return null;
  }
  String whole, tail;
  if (point <= 0) {
    whole = '0';
    tail = '${'0' * (-point)}$digits';
  } else if (point >= digits.length) {
    whole = '$digits${'0' * (point - digits.length)}';
    tail = '';
  } else {
    whole = digits.substring(0, point);
    tail = digits.substring(point);
  }
  whole = whole.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final negative =
      match.group(1) == '-' && RegExp(r'[1-9]').hasMatch('$whole$tail');
  return '${negative ? '-' : ''}$whole${tail.isEmpty ? '' : '.$tail'}';
}

/// Grouping and representational zero padding never discard a business digit.
String? exactNumberDisplay(
  Object? value, {
  int minimumFractionDigits = 0,
  bool groupThousands = false,
  bool trimTrailingZeros = true,
}) {
  final exact = exactNumberText(value);
  if (exact == null) {
    return null;
  }
  final negative = exact.startsWith('-'),
      unsigned = exact.startsWith('-') ? exact.substring(1) : exact;
  final parts = unsigned.split('.');
  var fraction = parts.length > 1 ? parts[1] : '';
  final minimum = minimumFractionDigits < 0 ? 0 : minimumFractionDigits;
  if (trimTrailingZeros) {
    while (fraction.length > minimum && fraction.endsWith('0')) {
      fraction = fraction.substring(0, fraction.length - 1);
    }
  }
  fraction = fraction.padRight(minimum, '0');
  var whole = parts.first;
  if (groupThousands) {
    final buffer = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(whole[i]);
    }
    whole = buffer.toString();
  }
  return '${negative ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
}

/// Finite legacy numeric values are displayed without another rounding step.
/// Prefer original decimal strings/Exact DTO fields when they are available.
extension ExactBusinessNumberText on num {
  String toExactString({int minimumFractionDigits = 0}) =>
      exactNumberDisplay(this, minimumFractionDigits: minimumFractionDigits) ?? toString();
}
