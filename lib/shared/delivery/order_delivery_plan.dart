import 'dart:convert';

/// Order-line delivery instructions. Paths contain BOM edge UUIDs, never goods IDs.
/// Unknown fields are retained so a draft cannot silently erase server evidence.
class OrderDeliveryPlan {
  OrderDeliveryPlan._(Map<String, dynamic> json)
    : _json = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

  factory OrderDeliveryPlan.assembled() => OrderDeliveryPlan._({
    'version': 1,
    'mode': 'ASSEMBLED',
    'packaging': 'ORIGINAL',
    'nodeModes': <Map<String, dynamic>>[],
    'processes': <Map<String, dynamic>>[],
  });

  static OrderDeliveryPlan? read(Object? value) {
    if (value is! Map) return null;
    return OrderDeliveryPlan._(
      value.map((key, value) => MapEntry('$key', value)),
    );
  }

  final Map<String, dynamic> _json;
  int? get version => _json['version'] is int ? _json['version'] as int : null;
  String get mode => _json['mode']?.toString() ?? '';
  String get packaging => _json['packaging']?.toString() ?? '';
  String? get bomFingerprint => _json['bomFingerprint']?.toString();
  bool get supported {
    bool pathValid(Object? value) =>
        value is List &&
        value.every((entry) => entry is String && entry.isNotEmpty);
    final nodes = _json['nodeModes'], operations = _json['processes'];
    return version == 1 &&
        const {'ASSEMBLED', 'BOM'}.contains(mode) &&
        const {'ORIGINAL', 'BULK', 'PENDING'}.contains(packaging) &&
        nodes is List &&
        nodes.every(
          (entry) =>
              entry is Map &&
              pathValid(entry['path']) &&
              const {'WHOLE', 'CHILDREN'}.contains(entry['mode']),
        ) &&
        operations is List &&
        operations.every(
          (entry) =>
              entry is Map &&
              pathValid(entry['path']) &&
              entry['operation'] == 'LASER' &&
              entry['required'] == true,
        );
  }

  List<Map<String, dynamic>> _entries(String key) => [
    for (final value in _json[key] is List ? _json[key] as List : const [])
      if (value is Map) value.map((key, value) => MapEntry('$key', value)),
  ];
  List<Map<String, dynamic>> get nodeModes => _entries('nodeModes');
  List<Map<String, dynamic>> get processes => _entries('processes');
  bool get requiresPhysicalFulfillment =>
      mode == 'BOM' || processes.any((entry) => entry['required'] == true);
  static List<String> pathOf(Map<String, dynamic> entry) => [
    for (final value
        in entry['path'] is List ? entry['path'] as List : const [])
      value.toString(),
  ];
  static String pathKey(Iterable<String> path) => path.join('/');
  String modeAt(List<String> path) {
    final key = pathKey(path);
    for (final entry in nodeModes) {
      if (pathKey(pathOf(entry)) == key) {
        return entry['mode']?.toString() ?? 'WHOLE';
      }
    }
    return 'WHOLE';
  }

  bool laserAt(List<String> path) => processes.any(
    (entry) =>
        pathKey(pathOf(entry)) == pathKey(path) &&
        entry['operation'] == 'LASER' &&
        entry['required'] == true,
  );
  OrderDeliveryPlan copyWith({
    String? mode,
    String? packaging,
    List<Map<String, dynamic>>? nodeModes,
    List<Map<String, dynamic>>? processes,
    String? bomFingerprint,
  }) => OrderDeliveryPlan._({
    ..._json,
    'mode': ?mode,
    'packaging': ?packaging,
    'nodeModes': ?nodeModes,
    'processes': ?processes,
    'bomFingerprint': ?bomFingerprint,
  });
  OrderDeliveryPlan setNode(List<String> path, String mode) => copyWith(
    nodeModes: [
      ...nodeModes.where((entry) => pathKey(pathOf(entry)) != pathKey(path)),
      {
        ...?nodeModes
            .where((entry) => pathKey(pathOf(entry)) == pathKey(path))
            .firstOrNull,
        'path': path,
        'mode': mode,
      },
    ],
  );
  OrderDeliveryPlan setLaser(List<String> path, bool required) => copyWith(
    processes: [
      ...processes.where(
        (entry) =>
            !(pathKey(pathOf(entry)) == pathKey(path) &&
                entry['operation'] == 'LASER'),
      ),
      if (required)
        {
          ...?processes
              .where(
                (entry) =>
                    pathKey(pathOf(entry)) == pathKey(path) &&
                    entry['operation'] == 'LASER',
              )
              .firstOrNull,
          'path': path,
          'operation': 'LASER',
          'required': true,
        },
    ],
  );
  Map<String, dynamic> toJson() =>
      jsonDecode(jsonEncode(_json)) as Map<String, dynamic>;
  String get signature {
    final json = toJson();
    for (final key in ['nodeModes', 'processes']) {
      if (json[key] is List) {
        (json[key] as List).sort(
          (a, b) => jsonEncode(a).compareTo(jsonEncode(b)),
        );
      }
    }
    return jsonEncode(json);
  }

  String get label => !supported
      ? '交付配置(版本待核对)'
      : mode == 'ASSEMBLED'
      ? '整装交付'
      : '按BOM层级交付';
  String get packagingLabel => switch (packaging) {
    'ORIGINAL' => '沿用原包装',
    'BULK' => '仓库整批打包',
    'PENDING' => '包装待确认',
    _ => '包装待核对',
  };
  String get summary =>
      '$label / $packagingLabel / ${nodeModes.where((e) => e['mode'] == 'CHILDREN').length}处按下级 / ${processes.length}项工艺要求';
}

String orderDeliveryLabel(OrderDeliveryPlan? plan) => plan?.label ?? '整装交付';
