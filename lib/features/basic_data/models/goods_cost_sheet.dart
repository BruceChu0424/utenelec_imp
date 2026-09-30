import 'dart:convert';
import '../../../shared/formatters/exact_decimal.dart';

/// Cost facts retain their wire decimal strings. No display value is parsed back
/// into an authoritative amount; the server calculation owns every total.
Map<String, dynamic> costMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<Map<String, dynamic>> costMaps(Object? value) => value is List
    ? value
          .whereType<Map<Object?, Object?>>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList()
    : <Map<String, dynamic>>[];
Map<String, dynamic> copyCostJson(Map<String, dynamic> value) =>
    costMap(jsonDecode(jsonEncode(value)));
String? costText(Object? value) => value?.toString();
bool costFeeUsesQuantity(Object? type) =>
    type == 'PER_QUANTITY' || type == 'PER_CYCLE';

bool positiveCostRate(String? raw) {
  if (raw == null || raw.length > 120) return false;
  final decimal = financeExactDecimal(raw);
  return decimal != null &&
      !decimal.startsWith('-') &&
      RegExp('[1-9]').hasMatch(decimal);
}

bool _sameCostDecimal(String? left, String? right) {
  final a = financeExactDecimal(left), b = financeExactDecimal(right);
  if (a == null || b == null) return false;
  final difference = financeExactSumTexts([
    a,
    b.startsWith('-') ? b.substring(1) : '-$b',
  ]);
  return difference != null && !RegExp('[1-9]').hasMatch(difference);
}

/// Raw imported prices may be per bag/in another currency or tax basis. Only
/// explicitly normalized manual prices belong directly in the per-base-unit cell.
bool normalizedCostPriceOverride(
  Map<String, dynamic>? override,
  String? sheetRate,
) =>
    override != null &&
    override['unitPrice'] != null &&
    override['priceSourceType'] == 'MANUAL' &&
    override['taxMode'] == 'AS_RECORDED' &&
    _sameCostDecimal(costText(override['priceUnitRate']), '1') &&
    positiveCostRate(sheetRate) &&
    positiveCostRate(costText(override['priceExchangeRateToLocal'])) &&
    _sameCostDecimal(costText(override['priceExchangeRateToLocal']), sheetRate);
String? costUnitPriceEditorText(
  Map<String, dynamic> row,
  Map<String, dynamic>? override,
  String? sheetRate,
) => normalizedCostPriceOverride(override, sheetRate)
    ? costText(override!['unitPrice'])
    : costText(row['unitPrice']);

class GoodsCostCalculation {
  GoodsCostCalculation(Map<String, dynamic> value) : json = copyCostJson(value);
  final Map<String, dynamic> json;
  List<Map<String, dynamic>> get lines => costMaps(json['lines']);
  List<Map<String, dynamic>> get fees => costMaps(json['fees']);
  List<Map<String, dynamic>> get issues => costMaps(json['issues']);
  Map<String, dynamic> get totals => costMap(json['totals']);
  String? get digest => costText(json['contentDigest']);

  /// Optional additive HTTP field. Older preview responses remain compatible.
  Map<String, dynamic>? get resolvedInput =>
      json['resolvedInput'] is Map ? costMap(json['resolvedInput']) : null;
  bool get complete =>
      issues.every((i) => i['blocksConfirmation'] != true) &&
      !const {
        'INCOMPLETE',
        'MISSING',
        'PENDING',
      }.contains(totals['valueState']);
}

Set<String> costMetadataKeys(Object? text) {
  if (text is! String) return <String>{};
  try {
    final value = jsonDecode(text);
    return value is List ? value.whereType<String>().toSet() : <String>{};
  } on FormatException {
    return <String>{};
  }
}

/// Merge only server-owned suggestions. Quantities, overrides, cells, notes and
/// controllers remain owned by the editor. In particular a template change
/// cannot reinterpret a user's entered unit price as a percentage.
Map<String, dynamic> mergeResolvedCostInput(
  Map<String, dynamic> current,
  Map<String, dynamic>? resolved,
) {
  final result = copyCostJson(current);
  if (resolved == null ||
      resolved['goodsId'] != current['goodsId'] ||
      resolved['clientId'] != current['clientId']) {
    return result;
  }
  final extra = costMap(result['extraFields']),
      serverExtra = costMap(resolved['extraFields']);
  final oldAuto = costMetadataKeys(extra['costAutoPriceColumnKeys']);
  final incomingAuto = costMetadataKeys(serverExtra['costAutoPriceColumnKeys']);
  final excluded = costMetadataKeys(extra['costExcludedPriceColumnKeys']);
  final old = {
    for (final column in costMaps(current['priceColumns']))
      column['key'].toString(): column,
  };
  final manual = old.keys.where((key) => !oldAuto.contains(key)).toSet();
  final referenced = costMaps(
    current['priceCells'],
  ).map((cell) => cell['columnKey'].toString()).toSet();
  final filled = costMaps(current['priceCells'])
      .where(
        (cell) =>
            (costText(cell['value'])?.trim().isNotEmpty ?? false) ||
            (costText(cell['quantity'])?.trim().isNotEmpty ?? false),
      )
      .map((cell) => cell['columnKey'].toString())
      .toSet();
  final merged = <String, Map<String, dynamic>>{};
  String definition(Map<String, dynamic> column) => jsonEncode([
    column['name'],
    column['type'],
    column['category'],
    column['baseKeys'],
  ]);
  for (final column in costMaps(resolved['priceColumns'])) {
    final key = column['key'].toString();
    if (excluded.contains(key) && !manual.contains(key)) continue;
    final previous = old[key];
    if (previous != null &&
        (manual.contains(key) ||
            (filled.contains(key) &&
                definition(previous) != definition(column)))) {
      merged[key] = previous;
      manual.add(key);
    } else {
      merged[key] = column;
    }
  }
  for (final entry in old.entries) {
    if (!merged.containsKey(entry.key) &&
        (manual.contains(entry.key) || referenced.contains(entry.key))) {
      merged[entry.key] = entry.value;
      manual.add(entry.key);
    }
  }
  result['priceColumns'] = merged.values.toList();
  for (final key in ['serverClientName', 'costTemplateVersions']) {
    if (serverExtra.containsKey(key)) extra[key] = serverExtra[key];
  }
  extra['costAutoPriceColumnKeys'] = jsonEncode(
    incomingAuto
        .where((key) => merged.containsKey(key) && !manual.contains(key))
        .toList(),
  );
  result['extraFields'] = extra;
  return result;
}

/// Explicitly editing or reusing a definition makes it this sheet's override.
Map<String, dynamic> markCostPriceColumnManual(
  Map<String, dynamic> input,
  String key,
) {
  final result = copyCostJson(input), extra = costMap(input['extraFields']);
  final keys = costMetadataKeys(extra['costAutoPriceColumnKeys'])..remove(key);
  extra['costAutoPriceColumnKeys'] = jsonEncode(keys.toList());
  result['extraFields'] = extra;
  return result;
}

class GoodsCostSheet {
  GoodsCostSheet(Map<String, dynamic> value) : json = copyCostJson(value);
  final Map<String, dynamic> json;
  String get id => costText(json['id']) ?? '';
  int get version => (json['version'] as num?)?.toInt() ?? 0;
  String get status => costText(json['status']) ?? 'DRAFT';
  String get number => costText(json['sheetNo']) ?? '';
  Map<String, dynamic> get input => costMap(json['input']);
  GoodsCostCalculation get calculation =>
      GoodsCostCalculation(costMap(json['calculation']));
  bool get canEdit => json['canEdit'] == true && status == 'DRAFT';
  bool get canConfirm => json['canConfirm'] == true;
  bool get canExport => json['canExport'] == true;
}

class GoodsCostSnapshot {
  GoodsCostSnapshot(Map<String, dynamic> value) : json = copyCostJson(value);
  final Map<String, dynamic> json;
  String get id => costText(json['id']) ?? '';
  String get kind => costText(json['kind']) ?? '';
  GoodsCostCalculation get calculation =>
      GoodsCostCalculation(costMap(json['calculation']));
}

/// Stable BOM occurrence identity is separate from a goods identity. Two paths
/// using the same material remain independently editable and auditable.
Map<String, dynamic> updateCostOverride(
  Map<String, dynamic> input,
  String path,
  Map<String, dynamic> changes,
) {
  final result = copyCostJson(input);
  final overrides = costMaps(result['lineOverrides']);
  final index = overrides.indexWhere((line) => line['path'] == path);
  if (index < 0) {
    overrides.add({'path': path, ...changes});
  } else {
    overrides[index] = {...overrides[index], ...changes};
  }
  result['lineOverrides'] = overrides;
  return result;
}

Map<String, dynamic> updateCostPriceCell(
  Map<String, dynamic> input,
  String path,
  String columnKey,
  String? value, {
  bool applicable = true,
  String? quantity,
  String? reason,
}) {
  final result = copyCostJson(input);
  final cells = costMaps(result['priceCells']);
  final index = cells.indexWhere(
    (c) => c['path'] == path && c['columnKey'] == columnKey,
  );
  if (!applicable) {
    if (index >= 0) cells.removeAt(index);
  } else {
    final cell = <String, dynamic>{
      if (index >= 0) ...cells[index],
      'path': path,
      'columnKey': columnKey,
      'value': value,
      if (quantity != null)
        'quantity': quantity.trim().isEmpty ? null : quantity,
      'reason': ?reason,
    };
    if (index < 0) {
      cells.add(cell);
    } else {
      cells[index] = cell;
    }
  }
  result['priceCells'] = cells;
  return result;
}
