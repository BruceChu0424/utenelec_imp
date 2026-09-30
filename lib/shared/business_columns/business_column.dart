import '../formatters/exact_decimal.dart';

/// A reusable definition. Saved document lines carry their own immutable snapshot.
class BusinessColumn {
  const BusinessColumn({
    required this.id,
    required this.name,
    this.scope = '',
    this.type = 'TEXT',
    this.operation = 'NONE',
    this.usageCount = 0,
    this.value,
  });

  final String id;
  final String name;
  final String scope;
  final String type;
  final String operation;
  final int usageCount;
  final String? value;

  bool get numeric => type != 'TEXT';
  bool get affectsAmount => operation != 'NONE';
  bool get financial => affectsAmount || type == 'AMOUNT';
  String get key => 'extra:$id';
  String get symbol => switch (operation) {
    'ADD' => '+',
    'SUBTRACT' => '−',
    'MULTIPLY' => '×',
    'DIVIDE' => '÷',
    _ => '',
  };
  String get label => symbol.isEmpty ? name : '$name ($symbol)';

  factory BusinessColumn.fromJson(Map<String, dynamic> json) => BusinessColumn(
    id: (json['columnId'] ?? json['id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    scope: (json['scope'] ?? '').toString(),
    type: (json['type'] ?? 'TEXT').toString(),
    operation: (json['operation'] ?? 'NONE').toString(),
    usageCount: (json['usageCount'] as num?)?.toInt() ?? 0,
    value: json['value']?.toString(),
  );

  Map<String, dynamic> toSnapshot([String? currentValue]) => {
    'columnId': id,
    'name': name,
    'scope': scope,
    'type': type,
    'operation': operation,
    'value': currentValue ?? value,
  };

  static List<BusinessColumn> read(Object? raw) => raw is List
      ? [
          for (final entry in raw)
            if (entry is Map)
              BusinessColumn.fromJson(Map<String, dynamic>.from(entry)),
        ].where((c) => c.id.isNotEmpty).toList(growable: false)
      : const [];
}

/// Calculation mirrors the server's sequential decimal arithmetic. A missing
/// operand is optional, but invalid numbers and inexact division never become 0.
String? businessColumnAmount(
  String? base,
  Iterable<BusinessColumn> columns, {
  bool allowNegative = false,
}) {
  var amount = businessExactDecimal(base);
  if (amount == null) return null;
  for (final column in columns) {
    if (!column.affectsAmount ||
        column.value == null ||
        column.value!.trim().isEmpty) {
      continue;
    }
    final operand = businessExactDecimal(column.value);
    if (operand == null) return null;
    if (column.type == 'TEXT') return null;
    amount = switch (column.operation) {
      'ADD' => financeExactSumTexts([amount, operand]),
      'SUBTRACT' => financeExactSumTexts([
        amount,
        operand.startsWith('-') ? operand.substring(1) : '-$operand',
      ]),
      'MULTIPLY' => financeExactMultiplyTexts([amount, operand]),
      'DIVIDE' => _divideExact(amount!, operand),
      _ => null,
    };
    if (amount == null || businessExactDecimal(amount) == null) return null;
  }
  // 循环内对 amount 的再赋值会让 flow analysis 放弃非空提升, 判空后交给局部变量。
  if (amount == null) return null;
  return !allowNegative &&
          amount.startsWith('-') &&
          !RegExp(r'^-0+(\.0+)?$').hasMatch(amount)
      ? null
      : amount;
}

String? _divideExact(String left, String right) {
  final leftScale = left.contains('.') ? left.split('.').last.length : 0;
  final rightScale = right.contains('.') ? right.split('.').last.length : 0;
  var numerator =
      financeExactDecimalUnits(left, scale: leftScale)! *
      BigInt.from(10).pow(rightScale);
  var denominator =
      financeExactDecimalUnits(right, scale: rightScale)! *
      BigInt.from(10).pow(leftScale);
  if (denominator == BigInt.zero) return null;
  if (denominator.isNegative) {
    numerator = -numerator;
    denominator = -denominator;
  }
  final gcd = numerator.abs().gcd(denominator);
  numerator ~/= gcd;
  denominator ~/= gcd;
  var two = 0;
  var five = 0;
  while (denominator % BigInt.two == BigInt.zero) {
    denominator ~/= BigInt.two;
    two++;
  }
  while (denominator % BigInt.from(5) == BigInt.zero) {
    denominator ~/= BigInt.from(5);
    five++;
  }
  if (denominator != BigInt.one) return null;
  final scale = two > five ? two : five;
  if (scale > 30) return null;
  return financeExactDecimalFromUnits(
    numerator * BigInt.two.pow(scale - two) * BigInt.from(5).pow(scale - five),
    scale: scale,
  );
}

/// Definition, value and arithmetic sequence all belong to the saved terms.
Set<String> businessColumnChangedKeys(
  List<BusinessColumn> before,
  List<BusinessColumn> after,
) {
  final old = {for (final column in before) column.id: column};
  final current = {for (final column in after) column.id: column};
  String? value(BusinessColumn? column) => column == null
      ? null
      : column.numeric
      ? financeExactTrimmed(column.value) ?? column.value
      : column.value;
  final result = <String>{};
  for (final id in {...old.keys, ...current.keys}) {
    final a = old[id];
    final b = current[id];
    if (a?.name != b?.name ||
        a?.type != b?.type ||
        a?.operation != b?.operation ||
        value(a) != value(b)) {
      result.add('extra:$id');
    }
  }
  final oldOrder = before
      .where((c) => c.affectsAmount)
      .map((c) => c.id)
      .join('|');
  final newOrder = after
      .where((c) => c.affectsAmount)
      .map((c) => c.id)
      .join('|');
  if (oldOrder != newOrder) {
    result.addAll(
      [...before, ...after].where((c) => c.affectsAmount).map((c) => c.key),
    );
  }
  return result;
}

/// Same finite book-value bound as the server: 40 integer and 30 fractional
/// digits. Normalize common decimal input forms before exact arithmetic.
String? businessExactDecimal(String? raw) {
  if (raw == null) return null;
  var text = raw.trim();
  if (text.length > 120 ||
      !RegExp(r'^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$').hasMatch(text)) {
    return null;
  }
  if (text.startsWith('+')) text = text.substring(1);
  if (text.startsWith('.')) text = '0$text';
  if (text.startsWith('-.')) text = text.replaceFirst('-.', '-0.');
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  text = financeExactTrimmed(text) ?? text;
  final unsigned = text.startsWith('-') ? text.substring(1) : text;
  final parts = unsigned.split('.');
  if (parts.first.replaceFirst(RegExp(r'^0+'), '').length > 40 ||
      (parts.length > 1 && parts.last.length > 30)) {
    return null;
  }
  return RegExp(r'^-?0+(?:\.0+)?$').hasMatch(text) ? '0' : text;
}
