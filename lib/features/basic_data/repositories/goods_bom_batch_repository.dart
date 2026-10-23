import '../../../core/performance/json_value_snapshot.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';

enum BomBatchAction {
  add('ADD'),
  remove('REMOVE'),
  overwrite('OVERWRITE');

  const BomBatchAction(this.apiValue);
  final String apiValue;

  static BomBatchAction fromApi(Object? value) => values.firstWhere(
    (action) => action.apiValue == value,
    orElse: () => throw const FormatException('Unknown BOM batch action'),
  );
}

class BomBatchTarget {
  const BomBatchTarget({
    required this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.added = 0,
    this.updated = 0,
    this.removed = 0,
    this.skipped = 0,
  });

  final String goodsId;
  final String? goodsCode, goodsName;
  final int added, updated, removed, skipped;

  factory BomBatchTarget.fromJson(Map<String, dynamic> json) => BomBatchTarget(
    goodsId: json['goodsId'] as String,
    goodsCode: json['goodsCode'] as String?,
    goodsName: json['goodsName'] as String?,
    added: _count(json, 'added'),
    updated: _count(json, 'updated'),
    removed: _count(json, 'removed'),
    skipped: _count(json, 'skipped'),
  );
}

class BomBatchAffectedProduct {
  const BomBatchAffectedProduct({
    required this.goodsId,
    this.goodsCode,
    this.goodsName,
    required this.selected,
  });

  final String goodsId;
  final String? goodsCode, goodsName;
  final bool selected;

  factory BomBatchAffectedProduct.fromJson(Map<String, dynamic> json) =>
      BomBatchAffectedProduct(
        goodsId: json['goodsId'] as String,
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        selected: json['selected'] == true,
      );
}

class BomBatchResult {
  const BomBatchResult({
    required this.selectedTargetCount,
    required this.changedTargetCount,
    required this.added,
    required this.updated,
    required this.removed,
    required this.skipped,
    required this.targets,
    this.affectedProductCount = 0,
    this.warnings = const [],
  });

  final int selectedTargetCount, changedTargetCount;
  final int added, updated, removed, skipped;
  final int affectedProductCount;
  final List<BomBatchTarget> targets;
  final List<String> warnings;

  factory BomBatchResult.fromJson(Map<String, dynamic> json) => BomBatchResult(
    selectedTargetCount: _count(json, 'selectedTargetCount'),
    changedTargetCount: _count(json, 'changedTargetCount'),
    added: _count(json, 'added'),
    updated: _count(json, 'updated'),
    removed: _count(json, 'removed'),
    skipped: _count(json, 'skipped'),
    affectedProductCount: _count(json, 'affectedProductCount'),
    targets: _objects(json, 'targets', BomBatchTarget.fromJson),
    warnings: _warnings(json),
  );
}

class BomBatchPreview extends BomBatchResult {
  const BomBatchPreview({
    required this.previewToken,
    required this.action,
    required super.selectedTargetCount,
    required super.changedTargetCount,
    required super.added,
    required super.updated,
    required super.removed,
    required super.skipped,
    required super.targets,
    required this.affectedProducts,
    required this.otherUsageCount,
    required this.hiddenUsageCount,
    this.expiresAt,
    super.affectedProductCount,
    super.warnings,
  });

  final String previewToken;
  final BomBatchAction action;
  final List<BomBatchAffectedProduct> affectedProducts;
  final int otherUsageCount, hiddenUsageCount;
  final DateTime? expiresAt;

  factory BomBatchPreview.fromJson(Map<String, dynamic> json) {
    final products = _objects(
      json,
      'affectedProducts',
      BomBatchAffectedProduct.fromJson,
    );
    return BomBatchPreview(
      previewToken: json['previewToken'] as String,
      action: BomBatchAction.fromApi(json['action']),
      selectedTargetCount: _count(json, 'selectedTargetCount'),
      changedTargetCount: _count(json, 'changedTargetCount'),
      added: _count(json, 'added'),
      updated: _count(json, 'updated'),
      removed: _count(json, 'removed'),
      skipped: _count(json, 'skipped'),
      targets: _objects(json, 'targets', BomBatchTarget.fromJson),
      affectedProducts: products,
      affectedProductCount: json['affectedProductCount'] is num
          ? _count(json, 'affectedProductCount')
          : products.length + _count(json, 'hiddenUsageCount'),
      otherUsageCount: _count(json, 'otherUsageCount'),
      hiddenUsageCount: _count(json, 'hiddenUsageCount'),
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
      warnings: _warnings(json),
    );
  }
}

int _count(Map<String, dynamic> json, String key) =>
    (json[key] as num?)?.toInt() ?? 0;

List<T> _objects<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Map<String, dynamic>) parse,
) => List<T>.unmodifiable([
  for (final value in json[key] as List? ?? const <Object>[])
    parse(Map<String, dynamic>.from(value as Map)),
]);

List<String> _warnings(Map<String, dynamic> json) => List<String>.unmodifiable(
  (json['warnings'] as List? ?? const <Object>[]).whereType<String>(),
);

abstract interface class GoodsBomBatchRepository {
  /// Previews the complete top-level batch without publishing its changes.
  Future<BomBatchPreview> preview({
    required BomBatchAction action,
    required List<String> targetGoodsIds,
    List<Map<String, dynamic>> items = const [],
    List<String> componentGoodsIds = const [],
  });

  /// Must use the same reviewed token on explicit retry after a lost receipt.
  Future<BomBatchResult> commit(
    String previewToken, {
    required bool confirmSharedChanges,
  });
}

class DioGoodsBomBatchRepository implements GoodsBomBatchRepository {
  DioGoodsBomBatchRepository(this.api);
  final ApiClient api;
  static const _path = '/master/goods/bom/batch-maintenance';

  @override
  Future<BomBatchPreview> preview({
    required BomBatchAction action,
    required List<String> targetGoodsIds,
    List<Map<String, dynamic>> items = const [],
    List<String> componentGoodsIds = const [],
  }) async {
    final body = <String, dynamic>{
      'action': action.apiValue,
      'targetGoodsIds': targetGoodsIds,
      if (action == BomBatchAction.remove)
        'componentGoodsIds': componentGoodsIds
      else
        'items': items,
    };
    // The caller owns the page/session fence. Isolate the reviewed intent from
    // any mutable picker/form collections before yielding to the transport.
    final frozen = JsonValueSnapshot.capture(body).data;
    final result = await api.post('$_path/preview', body: frozen);
    return BomBatchPreview.fromJson(result);
  }

  @override
  Future<BomBatchResult> commit(
    String previewToken, {
    required bool confirmSharedChanges,
  }) async => BomBatchResult.fromJson(
    await api.post(
      '$_path/commit',
      body: {
        'previewToken': previewToken,
        'confirmSharedChanges': confirmSharedChanges,
      },
    ),
  );
}

bool isBomBatchCommitUncertain(Object error) {
  if (error is! ApiException) return true;
  if (error.httpStatus != null && error.httpStatus! >= 500) return true;
  if (const {
    'SESSION_CHANGED',
    'SESSION_STATE_UNAVAILABLE',
    'UNAUTHORIZED',
    'FORBIDDEN',
    'NOT_FOUND',
    'CONFLICT',
    'VALIDATION_FAILED',
  }.contains(error.code)) {
    return false;
  }
  return const {'NETWORK', 'NETWORK_TIMEOUT'}.contains(error.code);
}

final goodsBomBatchRepositoryProvider = Provider<GoodsBomBatchRepository>(
  (ref) => DioGoodsBomBatchRepository(ref.watch(apiClientProvider)),
);
