/// Price-free processing subjects inside one physical delivery component.
/// Exact decimal or rational quantities remain source text; no rounding occurs.
class DeliveryProcessingTarget {
  const DeliveryProcessingTarget(this.data);
  final Map<String, dynamic> data;
  static const _fields = {
    'path',
    'goodsId',
    'code',
    'name',
    'unitId',
    'unitName',
    'quantityExact',
    'quantityNumerator',
    'quantityDenominator',
    'operations',
  };
  static List<DeliveryProcessingTarget> read(Object? value) {
    if (value == null) return const [];
    if (value is! List) throw const FormatException('加工对象快照格式不完整');
    return List<DeliveryProcessingTarget>.unmodifiable([
      for (final target in value)
        if (target is Map)
          DeliveryProcessingTarget({
            for (final entry in target.entries)
              if (_fields.contains(entry.key))
                entry.key.toString(): entry.value,
          })
        else
          throw const FormatException('加工对象快照格式不完整'),
    ]);
  }

  String get id => (data['path'] as List? ?? const []).join('/');
  String get code => data['code']?.toString() ?? '';
  String get name => data['name']?.toString() ?? '';
  String get unit => data['unitName']?.toString() ?? '';
  String get quantity =>
      data['quantityExact']?.toString() ??
      (data['quantityNumerator'] != null && data['quantityDenominator'] != null
          ? '${data['quantityNumerator']}/${data['quantityDenominator']}'
          : '数量未提供');
  String get operations => (data['operations'] as List? ?? const [])
      .map((value) => value == 'LASER' ? '激光加工' : value.toString())
      .join('、');
  String get label => '$code $name / $quantity $unit / $operations';
}
