import '../business_columns/business_column.dart';

class PlatformFormulaOperand {
  const PlatformFormulaOperand({this.columnId, this.fact, this.constant});
  final String? columnId;
  final String? fact;
  final String? constant;
  factory PlatformFormulaOperand.fromJson(Map<String, dynamic> json) =>
      PlatformFormulaOperand(
        columnId: json['columnId']?.toString(),
        fact: json['fact']?.toString(),
        constant: json['constant']?.toString(),
      );
  Map<String, dynamic> toJson() => {
    if (columnId != null) 'columnId': columnId,
    if (fact != null) 'fact': fact,
    if (constant != null) 'constant': constant,
  };
}

class PlatformFormulaStep {
  const PlatformFormulaStep({required this.operation, required this.operand});
  final String operation;
  final PlatformFormulaOperand operand;
  factory PlatformFormulaStep.fromJson(Map<String, dynamic> json) =>
      PlatformFormulaStep(
        operation: json['operation']?.toString() ?? '',
        operand: PlatformFormulaOperand.fromJson(
          Map<String, dynamic>.from(json['operand'] as Map? ?? {}),
        ),
      );
  Map<String, dynamic> toJson() => {
    'operation': operation,
    'operand': operand.toJson(),
  };
}

class PlatformFormula {
  const PlatformFormula({required this.base, this.steps = const []});
  final PlatformFormulaOperand base;
  final List<PlatformFormulaStep> steps;
  factory PlatformFormula.fromJson(Map<String, dynamic> json) =>
      PlatformFormula(
        base: PlatformFormulaOperand.fromJson(
          Map<String, dynamic>.from(json['base'] as Map? ?? {}),
        ),
        steps: [
          for (final step in json['steps'] as List? ?? [])
            if (step is Map)
              PlatformFormulaStep.fromJson(Map<String, dynamic>.from(step)),
        ],
      );
  Map<String, dynamic> toJson() => {
    'base': base.toJson(),
    'steps': steps.map((s) => s.toJson()).toList(),
  };

  /// Display-only arithmetic. Missing/masked facts never become zero.
  String? calculate(String? Function(PlatformFormulaOperand) resolve) {
    final initial = resolve(base);
    final operands = steps.map((step) => resolve(step.operand)).toList();
    if (initial == null ||
        operands.any((value) => value == null || value.trim().isEmpty)) {
      return null;
    }
    return businessColumnAmount(initial, [
      for (var i = 0; i < steps.length; i++)
        BusinessColumn(
          id: '$i',
          name: '$i',
          type: 'NUMBER',
          operation: steps[i].operation,
          value: operands[i],
        ),
    ], allowNegative: true);
  }
}

class PlatformColumnDefinition {
  const PlatformColumnDefinition({
    required this.id,
    required this.scope,
    required this.name,
    this.type = 'TEXT',
    this.priceProtected = false,
    this.formula,
    this.usageCount = 0,
    this.personalUsageCount = 0,
  });
  final String id;
  final String scope;
  final String name;
  final String type;
  final bool priceProtected;
  final PlatformFormula? formula;
  final int usageCount;
  final int personalUsageCount;
  bool get calculated => type == 'CALCULATED';
  bool get numeric => type != 'TEXT';
  String get key => 'platform:$id';
  factory PlatformColumnDefinition.fromJson(Map<String, dynamic> json) =>
      PlatformColumnDefinition(
        id: json['id']?.toString() ?? json['columnId']?.toString() ?? '',
        scope: json['scope']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        type: json['type']?.toString() ?? 'TEXT',
        priceProtected: json['priceProtected'] == true,
        formula: json['formula'] is Map
            ? PlatformFormula.fromJson(
                Map<String, dynamic>.from(json['formula'] as Map),
              )
            : null,
        usageCount: (json['usageCount'] as num?)?.toInt() ?? 0,
        personalUsageCount: (json['personalUsageCount'] as num?)?.toInt() ?? 0,
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'scope': scope,
    'name': name,
    'type': type,
    'priceProtected': priceProtected,
    if (formula != null) 'formula': formula!.toJson(),
  };
}

class PlatformColumnCell {
  const PlatformColumnCell({
    required this.columnId,
    this.value,
    required this.definition,
    this.masked = false,
    this.persisted = true,
    this.error,
  });
  final String columnId;
  final String? value;
  final PlatformColumnDefinition definition;
  final bool masked;
  final bool persisted;
  final String? error;
  factory PlatformColumnCell.fromJson(Map<String, dynamic> json) =>
      PlatformColumnCell(
        columnId: json['columnId']?.toString() ?? '',
        value: json['value']?.toString(),
        definition: PlatformColumnDefinition.fromJson(
          Map<String, dynamic>.from(json['definition'] as Map? ?? {}),
        ),
        masked: json['masked'] == true,
        persisted: json['persisted'] != false,
        error: json['error']?.toString(),
      );
  Map<String, dynamic> toWriteJson() => {
    'columnId': columnId,
    'value': masked ? null : value,
  };
}

class PlatformRowValues {
  const PlatformRowValues({
    required this.recordId,
    this.version = 0,
    this.canWrite = false,
    this.cells = const [],
  });
  final String recordId;
  final int version;
  final bool canWrite;
  final List<PlatformColumnCell> cells;
  factory PlatformRowValues.fromJson(Map<String, dynamic> json) =>
      PlatformRowValues(
        recordId: json['recordId']?.toString() ?? '',
        version: (json['version'] as num?)?.toInt() ?? 0,
        canWrite: json['canWrite'] == true,
        cells: [
          for (final cell in json['cells'] as List? ?? [])
            if (cell is Map)
              PlatformColumnCell.fromJson(Map<String, dynamic>.from(cell)),
        ],
      );
}

class PlatformTableFact {
  const PlatformTableFact({
    required this.key,
    required this.name,
    this.priceProtected = false,
  });
  final String key;
  final String name;
  final bool priceProtected;
  factory PlatformTableFact.fromJson(Map<String, dynamic> json) =>
      PlatformTableFact(
        key: json['key']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        priceProtected: json['priceProtected'] == true,
      );
}

class PlatformTableCapabilities {
  const PlatformTableCapabilities({
    required this.scope,
    this.label = '',
    this.canWrite = false,
    this.canDefine = false,
    this.canCreate = false,
    this.personalDefinitions = false,
    this.priceVisible = false,
    this.supportsValues = true,
    this.facts = const [],
  });
  final String scope;
  final String label;
  final bool canWrite;
  final bool priceVisible;
  final bool supportsValues;
  final bool canDefine;
  final bool canCreate;
  final bool personalDefinitions;
  final List<PlatformTableFact> facts;
  factory PlatformTableCapabilities.fromJson(Map<String, dynamic> json) =>
      PlatformTableCapabilities(
        scope: json['scope']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        canWrite: json['canWrite'] == true,
        priceVisible: json['priceVisible'] == true,
        supportsValues: json['supportsValues'] != false,
        canDefine: json['canDefine'] == true,
        canCreate: json['canCreate'] == true,
        personalDefinitions: json['personalDefinitions'] == true,
        facts: [
          for (final fact in json['facts'] as List? ?? [])
            if (fact is Map)
              PlatformTableFact.fromJson(Map<String, dynamic>.from(fact)),
        ],
      );
}

/// Raw numeric facts may arrive from a decoded Double as scientific notation.
/// Expand them without rounding; user-entered constants and values still use
/// strict ordinary decimals. Work and output remain bounded before allocation.
String? platformExactFact(Object? raw) {
  if (raw == null) return null;
  final text = raw.toString().trim();
  final ordinary = businessExactDecimal(text);
  if (ordinary != null) return ordinary;
  if (text.length > 120) return null;
  final match = RegExp(
    r'^([+-]?)([0-9]+)(?:\.([0-9]*))?[eE]([+-]?[0-9]+)$',
  ).firstMatch(text);
  if (match == null) return null;
  final exponent = int.tryParse(match.group(4)!);
  if (exponent == null || exponent.abs() > 200) return null;
  final fraction = match.group(3) ?? '';
  final coefficient = BigInt.parse('${match.group(2)}$fraction');
  if (coefficient == BigInt.zero) return '0';
  var digits = coefficient.toString();
  final scale = fraction.length - exponent;
  if (scale > 0) {
    digits = digits.padLeft(scale + 1, '0');
    digits =
        '${digits.substring(0, digits.length - scale)}.${digits.substring(digits.length - scale)}';
  } else if (scale < 0) {
    digits += List.filled(-scale, '0').join();
  }
  return businessExactDecimal('${match.group(1) == '-' ? '-' : ''}$digits');
}
