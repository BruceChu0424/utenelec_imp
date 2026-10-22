import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../models/goods_bom_item.dart';
import 'goods_bom_repository.dart';

class BomEditAffectedParent {
  const BomEditAffectedParent({
    required this.goodsId,
    this.goodsCode,
    this.goodsName,
    required this.otherUsageCount,
  });

  final String goodsId;
  final String? goodsCode, goodsName;
  final int otherUsageCount;

  factory BomEditAffectedParent.fromJson(Map<String, dynamic> json) =>
      BomEditAffectedParent(
        goodsId: json['goodsId'] as String,
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        otherUsageCount: (json['otherUsageCount'] as num?)?.toInt() ?? 0,
      );
}

class BomEditPreview {
  const BomEditPreview({
    required this.previewToken,
    required this.operationCount,
    required this.affectedParents,
    required this.otherUsageCount,
    this.expiresAt,
    this.warnings = const [],
  });

  final String previewToken;
  final int operationCount, otherUsageCount;
  final List<BomEditAffectedParent> affectedParents;
  final DateTime? expiresAt;
  final List<String> warnings;

  factory BomEditPreview.fromJson(Map<String, dynamic> json) => BomEditPreview(
    previewToken: json['previewToken'] as String,
    operationCount: (json['operationCount'] as num).toInt(),
    affectedParents: [
      for (final row in json['affectedParents'] as List)
        BomEditAffectedParent.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    otherUsageCount: (json['otherUsageCount'] as num?)?.toInt() ?? 0,
    expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
    warnings: (json['warnings'] as List? ?? const <Object>[])
        .whereType<String>()
        .toList(growable: false),
  );
}

/// One page's edit session. Commands update this in-memory draft only. The API
/// validates the complete command list before showing the shared-change consent,
/// then rechecks the same snapshots and commits everything in one transaction.
/// Draft data must never be stored in a cross-account or OS clipboard cache.
class GoodsBomEditDraft implements GoodsBomRepository {
  GoodsBomEditDraft({
    required this.base,
    required this.api,
    required this.rootGoodsId,
    bool Function()? isCurrent,
  }) : _isCurrent = isCurrent ?? (() => true);

  final GoodsBomRepository base;
  final ApiClient api;
  final String rootGoodsId;
  final bool Function() _isCurrent;
  final _rows = <String, List<Map<String, dynamic>>>{};
  final _loading = <String, Future<void>>{};
  final _fingerprints = <String, String>{};
  final _components = <String, Map<String, dynamic>>{};
  final _operations = <Map<String, dynamic>>[];
  bool _closed = false;
  bool _busy = false;
  String? _previewToken;
  BomEditPreview? _lastPreview;
  Map<String, dynamic>? _reviewedRequest;
  bool _recoverCommit = false;
  AuthenticatedRequestScope? _requestScope;
  Future<AuthenticatedRequestScope>? _capturingScope;

  bool get hasChanges => _operations.isNotEmpty;
  int get operationCount => _operations.length;
  bool get isBusy => _busy;
  // The last write may already have committed; dropping the local draft does
  // not undo it. The exit dialog must describe a refresh instead of no save.
  bool get isCommitRecoveryPending => _recoverCommit;

  String _path(String goodsId) => '${ApiEndpoints.goodsBom(goodsId)}/edit';

  void _check() {
    if (_closed || !_isCurrent()) throw AuthenticatedRequestScope.changed();
  }

  Future<AuthenticatedRequestScope> _scope() async {
    _check();
    // Expanded sibling snapshots share one authenticated capture even when
    // their reads start together. Verification still runs for every request.
    final AuthenticatedRequestScope scope;
    try {
      scope = _requestScope ??= await (_capturingScope ??= api
          .captureRequestScope(isCurrent: () => !_closed && _isCurrent()));
    } finally {
      if (_requestScope == null) _capturingScope = null;
    }
    await scope.verify();
    _check();
    return scope;
  }

  Future<void> _ensure(String goodsId) async {
    _check();
    if (_rows.containsKey(goodsId)) return;
    final pending = _loading[goodsId];
    if (pending != null) return pending;
    final load = () async {
      final scope = await _scope();
      final json = await scope.run(() => api.get('${_path(goodsId)}/snapshot'));
      _check();
      final source = json['items'] as List;
      final rows = <Map<String, dynamic>>[];
      for (var index = 0; index < source.length; index++) {
        if (index > 0 && index % 128 == 0) {
          // Network Futures alone do not yield a long synchronous conversion
          // to browser input or animation; use an event turn between chunks.
          await Future<void>.delayed(Duration.zero);
          _check();
        }
        rows.add(Map<String, dynamic>.from(source[index] as Map));
      }
      _check();
      _fingerprints[goodsId] = json['fingerprint'] as String;
      _rows[goodsId] = rows;
      for (final row in rows) {
        _components[row['componentGoodsId'] as String] = _presentation(row);
      }
    }();
    _loading[goodsId] = load;
    try {
      await load;
    } finally {
      _loading.remove(goodsId);
    }
  }

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    await _ensure(goodsId);
    _check();
    final items = <GoodsBomItem>[];
    final rows = _rows[goodsId]!;
    for (var index = 0; index < rows.length; index++) {
      if (index > 0 && index % 128 == 0) {
        await Future<void>.delayed(Duration.zero);
        _check();
      }
      final row = rows[index];
      items.add(
        GoodsBomItem.fromJson({
          ...row,
          if (_rows.containsKey(row['componentGoodsId']))
            'hasChildren': _rows[row['componentGoodsId']]!.isNotEmpty,
        }),
      );
    }
    return items;
  }

  Future<T> _mutate<T>(Future<T> Function() action) async {
    _check();
    if (_recoverCommit) {
      throw ApiException(
        'BOM_EDIT_RECEIPT_PENDING',
        '上次保存回执尚未确认，请先点击退出并保存核对结果',
      );
    }
    if (_busy) throw ApiException('BOM_EDIT_BUSY', '正在处理组件，请稍后再试');
    _busy = true;
    final beforeRows = {
      for (final entry in _rows.entries)
        entry.key: [
          for (final row in entry.value) Map<String, dynamic>.of(row),
        ],
    };
    final beforeCount = _operations.length;
    final beforeFingerprints = Map<String, String>.of(_fingerprints);
    try {
      final value = await action();
      _check();
      _assertNoKnownCycles();
      final workItems = _operations.fold<int>(0, (count, operation) {
        final deletes = (operation['itemIds'] as List?)?.length ?? 0;
        final moves = (operation['moves'] as List?)?.length ?? 0;
        return count +
            (deletes > 0
                ? deletes
                : moves > 0
                ? moves
                : 1);
      });
      if (workItems > 500) {
        throw ApiException('BOM_EDIT_LIMIT', '本次编辑最多暂存 500 个操作，请先退出并保存');
      }
      _previewToken = null;
      _lastPreview = null;
      _reviewedRequest = null;
      return value;
    } catch (_) {
      _rows
        ..clear()
        ..addAll(beforeRows);
      _fingerprints
        ..clear()
        ..addAll(beforeFingerprints);
      _operations.removeRange(beforeCount, _operations.length);
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Map<String, dynamic> _find(String goodsId, String itemId) {
    for (final row in _rows[goodsId] ?? const <Map<String, dynamic>>[]) {
      if (row['id'] == itemId) return row;
    }
    throw ApiException('BOM_EDIT_CHANGED', '组件已变化，请重新核对组装清单');
  }

  static Map<String, dynamic> _presentation(Map<String, dynamic> row) => {
    for (final key in const [
      'componentGoodsId',
      'componentCode',
      'componentName',
      'componentModel',
      'componentSpec',
      'componentMaterial',
      'componentStockQty',
      'componentUnitName',
      'componentColorName',
      'componentSourceType',
      'componentIssueMethod',
    ])
      key: row[key],
  };

  void _assertNoKnownCycles() {
    final visited = <String>{};
    final active = <String>{};
    void visit(String parent) {
      if (active.contains(parent)) {
        throw ApiException('BOM_EDIT_CYCLE', '此操作会形成组装环路，请选择其他位置');
      }
      if (!visited.add(parent)) return;
      active.add(parent);
      for (final row in _rows[parent] ?? const <Map<String, dynamic>>[]) {
        visit(row['componentGoodsId'] as String);
      }
      active.remove(parent);
    }

    for (final parent in _rows.keys) {
      visit(parent);
    }
  }

  /// A copied relation contributes display metadata, never another parent's
  /// actual consumption, audit, legacy identity or learning ownership.
  void rememberItems(Iterable<GoodsBomItem> items) {
    _check();
    for (final item in items) {
      _components[item.componentGoodsId] = {
        'componentGoodsId': item.componentGoodsId,
        'componentCode': item.componentCode,
        'componentName': item.componentName,
        'componentModel': item.componentModel,
        'componentSpec': item.componentSpec,
        'componentMaterial': item.componentMaterial,
        'componentUnitName': item.componentUnitName,
        'componentColorName': item.componentColorName,
        'componentSourceType': item.componentSourceType,
        'componentIssueMethod': item.componentIssueMethod,
      };
    }
  }

  void confirmPeriodicFields(Set<String> fields) {
    _check();
    if (_busy ||
        fields.any(
          (field) => !const {
            'confirmUnusualWeight',
            'confirmSecondPeriodicMaterial',
          }.contains(field),
        )) {
      throw ApiException('BOM_EDIT_CONFIRMATION', '确认内容已变化，请重新核对');
    }
    for (final operation in _operations) {
      final body = operation['body'];
      if (body is Map<String, dynamic>) {
        for (final field in fields) {
          body[field] = true;
        }
      }
    }
    _previewToken = null;
  }

  void _applyBody(Map<String, dynamic> row, Map<String, dynamic> body) {
    const structureFields = [
      'componentGoodsId',
      'qty',
      'colorId',
      'controlStage',
      'consumptionBasis',
      'basisOutputQty',
      'allowPartialPackage',
      'hardGate',
    ];
    final previous = {for (final key in structureFields) key: row[key]};
    for (final key in const [
      'componentGoodsId',
      'qty',
      'price',
      'summary',
      'colorId',
      'defaultSupplierId',
      'controlStage',
      'consumptionBasis',
      'basisOutputQty',
      'allowPartialPackage',
      'hardGate',
    ]) {
      if (body.containsKey(key)) row[key] = body[key];
    }
    if (body['unitWeightGrams'] case final num grams) {
      row['unitWeightGrams'] = grams;
      final factor = periodicGramsPerBaseUnit(
        row['componentUnitName'] as String?,
      );
      if (factor != null) row['qty'] = grams / factor;
    }
    final qty = row['qty'] as num?;
    final price = row['price'] as num?;
    row['total'] = qty == null || price == null ? null : qty * price;
    row['auditedAt'] = null;
    if (structureFields.any((key) => previous[key] != row[key])) {
      row['systemLearned'] = false;
    }
  }

  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) => _mutate(() async {
    await _ensure(goodsId);
    final row = _find(goodsId, itemId);
    if (body['componentGoodsId'] != null &&
        body['componentGoodsId'] != row['componentGoodsId']) {
      throw ApiException('BOM_EDIT_COMPONENT', '更换组件请使用物料反查的一键替换');
    }
    _applyBody(row, body);
    _operations.add({
      'type': 'UPDATE',
      'goodsId': goodsId,
      'itemId': itemId,
      'body': {'componentGoodsId': row['componentGoodsId'], ...body},
    });
    return GoodsBomItem.fromJson(row);
  });

  @override
  Future<int> deleteMany(String goodsId, List<String> itemIds) =>
      _mutate(() async {
        await _ensure(goodsId);
        final unique = itemIds.toSet();
        for (final id in unique) {
          final matches = _rows.entries.where(
            (e) => e.value.any((r) => r['id'] == id),
          );
          if (matches.isEmpty) _find(goodsId, id);
        }
        _operations.add({
          'type': 'DELETE',
          'goodsId': goodsId,
          'itemIds': unique.toList(),
        });
        for (final rows in _rows.values) {
          rows.removeWhere((row) => unique.contains(row['id']));
        }
        return unique.length;
      });

  Future<Map<String, dynamic>> _component(String id) async {
    final cached = _components[id];
    if (cached != null) return cached;
    final scope = await _scope();
    final detail = await scope.run(() => api.get('${ApiEndpoints.goods}/$id'));
    _check();
    final component = <String, dynamic>{
      'componentGoodsId': id,
      'componentCode': detail['code'],
      'componentName': detail['name'],
      'componentModel': detail['model'],
      'componentSpec': detail['spec'],
      'componentMaterial': detail['material'],
      'componentUnitName': detail['unitName'],
      'componentColorName': detail['colorName'],
      'colorId': detail['colorId'],
      'componentSourceType': detail['sourceType'],
      'componentIssueMethod': detail['issueMethod'],
    };
    _components[id] = component;
    return component;
  }

  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) => _mutate(() async {
    if (mode == BomPasteMode.replace) {
      throw ApiException('BOM_EDIT_REPLACE', '编辑草稿中只能追加组件，整份替换请使用导入组件的检测与确认流程');
    }
    for (final target in targets) {
      await _ensure(target.goodsId);
      final rows = _rows[target.goodsId]!;
      for (final body in items) {
        final componentId = body['componentGoodsId'] as String;
        if (rows.any((r) => r['componentGoodsId'] == componentId)) {
          throw ApiException('BOM_EDIT_DUPLICATE', '同一层不能重复添加相同组件');
        }
        if (target.goodsId == componentId) {
          throw ApiException('BOM_EDIT_CYCLE', '组件不能添加到自身下面');
        }
        final component = await _component(componentId);
        final id = const Uuid().v4();
        final row = <String, dynamic>{
          ...component, 'id': id, 'qty': 1.0,
          'controlStage': 'START', 'consumptionBasis': 'PER_UNIT',
          'basisOutputQty': 1.0, 'allowPartialPackage': true,
          'hardGate': component['componentIssueMethod'] != 'PERIODIC',
          // Discovering the child snapshot preserves expansion for copied assemblies.
          'hasChildren': (await list(componentId)).isNotEmpty,
        };
        _applyBody(row, body);
        rows.add(row);
        _operations.add({
          'type': 'CREATE',
          'goodsId': target.goodsId,
          'clientItemId': id,
          'body': Map<String, dynamic>.of(body),
        });
      }
    }
    return BomPasteResult(
      targets: targets.length,
      added: targets.length * items.length,
      removed: 0,
    );
  });

  @override
  Future<int> move(
    String goodsId,
    List<GoodsBomMove> moves,
  ) => _mutate(() async {
    await _ensure(goodsId);
    for (final move in moves) {
      await _ensure(move.targetParentGoodsId);
      final source = _rows.entries
          .where((entry) => entry.value.any((row) => row['id'] == move.itemId))
          .firstOrNull;
      if (source == null) throw ApiException('BOM_EDIT_CHANGED', '移动的组件已变化');
      final row = _find(source.key, move.itemId);
      final target = _rows[move.targetParentGoodsId]!;
      if (target.any(
        (r) =>
            r['id'] != row['id'] &&
            r['componentGoodsId'] == row['componentGoodsId'],
      )) {
        throw ApiException('BOM_EDIT_DUPLICATE', '目标层已有相同组件');
      }
      source.value.remove(row);
      if (source.key != move.targetParentGoodsId) {
        row.removeWhere(
          (key, _) =>
              key.startsWith('actual') ||
              key == 'usageBasis' ||
              key == 'effectiveQty' ||
              key == 'relearnedAt' ||
              key == 'legacyId',
        );
        row['auditedAt'] = null;
        row['systemLearned'] = false;
      }
      var index = move.anchorItemId == null
          ? target.length
          : target.indexWhere((r) => r['id'] == move.anchorItemId);
      if (index < 0) throw ApiException('BOM_EDIT_CHANGED', '移动目标已变化');
      if (move.anchorItemId != null && move.afterAnchor) index++;
      target.insert(index, row);
    }
    _operations.add({
      'type': 'MOVE',
      'goodsId': goodsId,
      'moves': [for (final move in moves) move.toJson()],
    });
    return moves.length;
  });

  Map<String, dynamic> _request() => {
    'operations': _operations,
    'snapshots': [
      for (final entry in _fingerprints.entries)
        {'goodsId': entry.key, 'fingerprint': entry.value},
    ],
  };

  Future<BomEditPreview> preview() async {
    _check();
    // A command with a lost response may already have committed. Retain its
    // consent token and ask the server for that same result on explicit retry.
    if (_recoverCommit && _lastPreview != null) return _lastPreview!;
    if (_busy) throw ApiException('BOM_EDIT_BUSY', '正在处理组件，请稍后再试');
    _busy = true;
    try {
      await _ensure(rootGoodsId);
      final scope = await _scope();
      final request = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(_request())) as Map,
      );
      final json = await scope.run(
        () => api.post('${_path(rootGoodsId)}/preview', body: request),
      );
      _check();
      final preview = BomEditPreview.fromJson(json);
      _previewToken = preview.previewToken;
      _lastPreview = preview;
      _reviewedRequest = request;
      return preview;
    } finally {
      _busy = false;
    }
  }

  Future<void> commit(
    String previewToken, {
    required bool confirmSharedChanges,
  }) async {
    _check();
    if (_busy || _previewToken != previewToken || _reviewedRequest == null) {
      throw ApiException('BOM_EDIT_PREVIEW_CHANGED', '草稿已变化，请重新核对同步范围');
    }
    _busy = true;
    try {
      final scope = await _scope();
      await scope.run(
        () => api.post(
          '${_path(rootGoodsId)}/commit',
          body: {
            ..._reviewedRequest!,
            'previewToken': previewToken,
            'confirmSharedChanges': confirmSharedChanges,
          },
        ),
      );
      _check();
      close();
    } on ApiException catch (error) {
      _recoverCommit =
          const {'NETWORK', 'NETWORK_TIMEOUT'}.contains(error.code) ||
          (error.httpStatus != null && error.httpStatus! >= 500);
      rethrow;
    } catch (_) {
      _recoverCommit = true;
      rethrow;
    } finally {
      _busy = false;
    }
  }

  void close() {
    _closed = true;
    _previewToken = null;
    _lastPreview = null;
    _reviewedRequest = null;
    _recoverCommit = false;
    _operations.clear();
    _rows.clear();
    _fingerprints.clear();
    _components.clear();
  }

  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) => throw ApiException('BOM_EDIT_AUDIT', '请先退出并保存编辑，再核对组件');

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) =>
      base.learning(goodsId);

  @override
  Future<GoodsBomLearningSummary> relearn(
    String goodsId,
    String componentGoodsId,
  ) => throw ApiException('BOM_EDIT_LEARNING', '请先退出并保存编辑，再重新学习');
}
