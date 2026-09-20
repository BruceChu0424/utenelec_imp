import 'dart:collection';

const materialAnalysisProjectionVersion = 'shared-material-defaults-v2';

/// One response owns its complete defaults. A sparse row overlays them by key
/// presence, so explicit null, zero, false and empty lists are never inherited.
/// Lookup views avoid allocating thousands of reconstructed full JSON maps.
class MaterialAnalysisMaterialDefaults {
  MaterialAnalysisMaterialDefaults(Object? raw) : _defaults = _object(raw) {
    _validate(_defaults);
  }

  final Map<String, dynamic> _defaults;
  final Set<String> _identities = {};

  Map<String, dynamic> hydrate(Object? raw) {
    final row = _object(raw);
    _validate(row);
    final result = _MaterialRowOverlay(_defaults, row);
    for (final field in const [
      'requiredQty',
      'availableQty',
      'allocatedAvailableQty',
      'shortageQty',
      'additionalSupplyRecommendedQty',
      'perProductQty',
      'routeConfirmed',
      'actionable',
      'level',
      'nodeRole',
    ]) {
      if (!result.containsKey(field) || result[field] == null) {
        throw FormatException('物料分析关键事实缺失: $field');
      }
    }
    final id = result['materialLineId'];
    final dimension = result['materialKey'];
    if (id is! String ||
        id.trim().isEmpty ||
        !_identities.add(id) ||
        dimension is! String ||
        dimension.trim().isEmpty) {
      throw const FormatException('物料分析节点身份缺失或重复');
    }
    return result;
  }

  static Map<String, dynamic> _object(Object? raw) {
    if (raw is! Map || raw.keys.any((key) => key is! String)) {
      throw const FormatException('物料分析默认值或节点格式无效');
    }
    return raw.cast<String, dynamic>();
  }

  static const _flags = {
    'allowPartialPackage',
    'hardGate',
    'routeConfirmed',
    'actionable',
    'lowerLevelPending',
  };
  static const _textLists = {'path', 'notifiedTargets'};
  static const _objectLists = {
    'borrowRefs',
    'crossReallocationRefs',
    'downstreamReferences',
    'sharedFutureSupplyRefs',
  };
  static const _textFields = {
    'materialLineId',
    'analysisLineId',
    'nodeKey',
    'actionGroupKey',
    'materialKey',
    'goodsId',
    'goodsCode',
    'goodsName',
    'spec',
    'colorId',
    'colorName',
    'unitId',
    'unitName',
    'parentNodeKey',
    'parentGoodsId',
    'parentLabel',
    'controlStage',
    'consumptionBasis',
    'expectedReadyDate',
    'sourceSuggestion',
    'sourceConfirmed',
    'routeReason',
    'requirementState',
    'delegatedToAnalysisLineId',
    'delegatedToSourceRef',
    'publicSurplusExpectedDate',
    'flowStage',
    'planAnchorAnalysisLineId',
    'subcontractOutboundForm',
    'owningWarehouseId',
    'owningWarehouseName',
    'owningWorkshopId',
    'owningWorkshopName',
    'nodeRole',
  };

  static void _validate(Map<String, dynamic> values) {
    for (final entry in values.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key == 'warehouseBreakdown') {
        throw const FormatException('共享仓库格式不得夹带独立仓库明细');
      }
      // Nullable values remain explicit. The typed domain parser retains its
      // existing null semantics; transport must never replace null with a default.
      if (value == null) continue;
      final valid = switch (key) {
        'level' => value is int,
        _ when key.endsWith('Qty') || key == 'qty' =>
          value is num && value.isFinite,
        _ when _flags.contains(key) => value is bool,
        _ when _textFields.contains(key) => value is String,
        _ when _textLists.contains(key) =>
          value is List && value.every((item) => item is String),
        _ when _objectLists.contains(key) =>
          value is List &&
              value.every(
                (item) =>
                    item is Map && item.keys.every((key) => key is String),
              ),
        _ => true,
      };
      if (!valid) throw FormatException('物料分析字段格式无效: $key');
      if (_objectLists.contains(key)) {
        for (final item in value as List) {
          _validate((item as Map).cast<String, dynamic>());
        }
      }
    }
  }
}

class _MaterialRowOverlay extends MapBase<String, dynamic> {
  _MaterialRowOverlay(this.defaults, this.row);
  final Map<String, dynamic> defaults;
  final Map<String, dynamic> row;

  @override
  dynamic operator [](Object? key) =>
      row.containsKey(key) ? row[key] : defaults[key];
  @override
  bool containsKey(Object? key) =>
      row.containsKey(key) || defaults.containsKey(key);
  @override
  Iterable<String> get keys sync* {
    yield* row.keys;
    yield* defaults.keys.where((key) => !row.containsKey(key));
  }

  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('Read-only material projection');
  @override
  void clear() => throw UnsupportedError('Read-only material projection');
  @override
  dynamic remove(Object? key) =>
      throw UnsupportedError('Read-only material projection');
}
