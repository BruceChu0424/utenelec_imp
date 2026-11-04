import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/goods_bom_item.dart';
import '../models/goods_node.dart';
import '../repositories/goods_bom_edit_repository.dart';
import '../repositories/goods_bom_repository.dart';
import 'bom_component_quantity_field.dart';
import 'bom_inline_edit_cell.dart';

/// Each root retains the ordinary assembly edit contract. Unrelated root BOMs
/// are never submitted as though they belonged to one assembly tree.
class GoodsBomComparisonEditor extends ChangeNotifier {
  GoodsBomComparisonEditor({
    required this.ref,
    required this.details,
    required this.isCurrent,
    required this.onChanged,
  });
  final WidgetRef ref;
  final Map<String, GoodsDetail> details;
  final bool Function() isCurrent;
  final Future<void> Function() onChanged;
  final drafts = <String, GoodsBomEditDraft>{};
  final _inputs = <String, BomLiveEditController>{};
  final _masterWritable = <String, bool>{};
  final _masters = <String, Map<String, Map<String, dynamic>>>{};
  final _committedMasters = <String, Map<String, dynamic>>{};
  final _staleMasterRoots = <String>{};
  Future<void> _queue = Future.value();
  bool _closed = false;
  int _queued = 0;
  int generation = 0;
  bool get current => !_closed && isCurrent();
  bool has(String permission) {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    return boundary.superAdmin || boundary.permissions.contains(permission);
  }

  bool get pending =>
      _queued > 0 || _inputs.values.any((input) => input.pending);
  bool get hasChanges => details.keys.any(changed);
  bool get hasMasterChanges => _masters.isNotEmpty;
  bool get hasStaleRoots => _staleMasterRoots.isNotEmpty;
  bool changed(String root) =>
      drafts[root]?.hasChanges == true ||
      _inputs.entries.any((e) => e.key.startsWith('$root|') && e.value.pending);
  GoodsBomEditDraft? draftFor(String root) => drafts[root];

  Future<void> open() async {
    for (final detail in details.values) {
      await _openRoot(detail);
    }
  }

  Future<void> _openRoot(GoodsDetail detail) async {
    if (!current ||
        !has(Perm.goodsBomEdit) ||
        !detail.writable ||
        detail.status != '使用') {
      return;
    }
    final draft = GoodsBomEditDraft(
      base: ref.read(goodsBomRepositoryProvider),
      api: ref.read(apiClientProvider),
      rootGoodsId: detail.id,
      isCurrent: () => current,
    );
    try {
      await draft.list(detail.id);
      if (!current) return;
      drafts[detail.id] = draft;
    } finally {
      if (!identical(drafts[detail.id], draft)) draft.close();
    }
  }

  Future<List<GoodsBomItem>> read(String root, String parent) async {
    if (!current) throw ApiException('BOM_EDIT_CHANGED', '对比对象已变化');
    final draft = drafts[root];
    final List<GoodsBomItem> items;
    if (draft != null) {
      items = await draft.list(parent);
    } else {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: () => current);
      items = await scope.run(
        () => ref.read(goodsBomRepositoryProvider).list(parent),
      );
    }
    if (draft != null && has(Perm.goodsEdit)) {
      final ids = items
          .map((item) => item.componentGoodsId)
          .toSet()
          .where((id) => !_masterWritable.containsKey('$root|$id'))
          .toList();
      for (var i = 0; i < ids.length; i += 4) {
        await Future.wait([
          for (final id in ids.skip(i).take(4))
            () async {
              try {
                final snapshot = await draft.goodsSnapshot(id);
                if (current) {
                  _masterWritable['$root|$id'] =
                      snapshot?['componentGoodsWritable'] == true;
                }
              } on ApiException {
                if (current) _masterWritable['$root|$id'] = false;
              }
            }(),
        ]);
        if (!current) return const [];
        await Future<void>.delayed(Duration.zero);
      }
    }
    return items;
  }

  static const masterFields = {'model', 'spec', 'material', 'sourceType'};
  bool canEdit(String root, GoodsBomItem item, String field) {
    if (!current ||
        drafts[root] == null ||
        drafts[root]!.isCommitRecoveryPending ||
        !has(Perm.goodsBomEdit)) {
      return false;
    }
    if (masterFields.contains(field)) {
      if (_staleMasterRoots.contains(root)) return false;
      if (!has(Perm.goodsEdit) ||
          _masterWritable['$root|${item.componentGoodsId}'] != true) {
        return false;
      }
      return !_masters.entries.any(
        (e) =>
            e.key != root &&
            e.value[item.componentGoodsId]?.containsKey(field) == true,
      );
    }
    if (item.isPeriodicEdge &&
        const {
          'controlStage',
          'consumptionBasis',
          'basisOutputQty',
          'allowPartialPackage',
          'hardGate',
        }.contains(field)) {
      return false;
    }
    return const {
      'qty',
      'summary',
      'colorId',
      'componentGoodsId',
      'controlStage',
      'consumptionBasis',
      'basisOutputQty',
      'allowPartialPackage',
      'hardGate',
      'defaultSupplierId',
    }.contains(field);
  }

  Object? masterValue(GoodsBomItem item, String field) {
    for (final root in _masters.values) {
      if (root[item.componentGoodsId]?.containsKey(field) == true) {
        return root[item.componentGoodsId]![field];
      }
    }
    return _committedMasters[item.componentGoodsId]?[field];
  }

  String? colorName(String root, GoodsBomItem item) =>
      _colors['$root|${item.id}'];
  final _colors = <String, String?>{};

  BomLiveEditController input(
    String root,
    String parent,
    GoodsBomItem item,
    String field,
    String initial,
  ) {
    // Replacing a component retains the relation ID, but changes input ownership.
    final key = '$root|$parent|${item.id}|${item.componentGoodsId}|$field';
    final input = _inputs.putIfAbsent(
      key,
      () => BomLiveEditController(
        value: initial,
        isCurrent: () => current,
        onStateChanged: () {
          if (current) notifyListeners();
        },
        apply: (value) => edit(root, parent, item, field, value),
        equivalent: const {'qty', 'basisOutputQty'}.contains(field)
            ? (left, right) =>
                  financeExactTrimmed(left) == financeExactTrimmed(right)
            : null,
      ),
    );
    input.synchronize(initial);
    return input;
  }

  BomLiveEditController? cachedInput(
    String root,
    String parent,
    GoodsBomItem item,
    String field,
  ) => _inputs['$root|$parent|${item.id}|${item.componentGoodsId}|$field'];

  Future<void> edit(
    String root,
    String parent,
    GoodsBomItem item,
    String field,
    Object? value, {
    String? label,
    String? replacementQuantity,
    GoodsListItem? replacementGoods,
  }) {
    _queued++;
    notifyListeners();
    final result = _queue
        .then((_) async {
          if (!canEdit(root, item, field)) {
            throw ApiException('FORBIDDEN', '当前没有修改该单元格的权限');
          }
          final draft = drafts[root]!;
          if (masterFields.contains(field)) {
            await draft.updateGoods(item.componentGoodsId, {
              field: value is String ? value.trim() : value,
            });
            _masters
                    .putIfAbsent(root, () => {})
                    .putIfAbsent(item.componentGoodsId, () => {})[field] =
                value;
          } else {
            final body = <String, dynamic>{
              'componentGoodsId': item.componentGoodsId,
            };
            if (field == 'qty' || field == 'basisOutputQty') {
              final raw = value?.toString().trim() ?? '';
              final number = double.tryParse(raw);
              if (!bomDesignQuantityValid(raw)) {
                throw ApiException('BOM_EDIT_QUANTITY', '请输入大于 0 的使用数量');
              }
              if (field == 'qty' && item.isPeriodicEdge) {
                body.addAll(
                  periodicBomQuantityBody(
                    item.componentGoodsId,
                    raw,
                    item.componentUnitName,
                  ),
                );
              } else {
                body[field] = financeExactDecimal(raw) ?? number;
              }
            } else {
              body[field] = value is String ? value.trim() : value;
            }
            if (field == 'colorId' && value == null) body['colorLegacyId'] = 0;
            if (field == 'componentGoodsId' && value != item.componentGoodsId) {
              body.addAll({
                'colorId': null,
                'colorLegacyId': 0,
                'defaultSupplierId': null,
                'vendLegacyId': 0,
              });
              if (replacementQuantity != null && replacementGoods != null) {
                if (!bomDesignQuantityValid(replacementQuantity)) {
                  throw ApiException('BOM_EDIT_QUANTITY', '请输入大于 0 的使用数量');
                }
                if (replacementGoods.isPeriodicIssue) {
                  body.addAll(
                    periodicBomQuantityBody(
                      replacementGoods.id,
                      replacementQuantity,
                      replacementGoods.unitName,
                    ),
                  );
                } else {
                  body['qty'] = financeExactDecimal(replacementQuantity);
                }
              }
            }
            await draft.update(parent, item.id, body);
            if (field == 'componentGoodsId') _colors.remove('$root|${item.id}');
            if (field == 'colorId') _colors['$root|${item.id}'] = label;
          }
          if (current) await onChanged();
        })
        .whenComplete(() {
          _queued--;
          if (current) notifyListeners();
        });
    _queue = result.catchError((Object _) {});
    return result;
  }

  Future<void> replaceComponent(
    String root,
    String parent,
    GoodsBomItem item,
    GoodsListItem chosen, {
    String? quantity,
  }) async {
    if (chosen.id == item.componentGoodsId) return;
    drafts[root]!.rememberItems([
      GoodsBomItem(
        id: item.id,
        componentGoodsId: chosen.id,
        componentCode: chosen.code,
        componentName: chosen.name,
        componentModel: chosen.model,
        componentSpec: chosen.spec,
        componentMaterial: chosen.material,
        componentUnitName: chosen.unitName,
        componentColorName: chosen.colorName,
        componentSourceType: chosen.sourceType,
        componentIssueMethod: chosen.issueMethod,
      ),
    ]);
    await edit(
      root,
      parent,
      item,
      'componentGoodsId',
      chosen.id,
      replacementQuantity: quantity,
      replacementGoods: chosen,
    );
  }

  Future<void> flush({String? root}) async {
    for (final entry in List.of(_inputs.entries)) {
      if ((root == null || entry.key.startsWith('$root|')) &&
          entry.value.pending) {
        await entry.value.flush();
      }
    }
    await _queue;
    if (root == null
        ? pending
        : _inputs.entries.any(
            (entry) => entry.key.startsWith('$root|') && entry.value.pending,
          )) {
      throw ApiException('BOM_EDIT_INPUT', '请先修正未完成的单元格输入，或放弃该侧修改');
    }
  }

  Future<void> reset(String root, {bool committed = false}) async {
    for (final key
        in _inputs.keys.where((key) => key.startsWith('$root|')).toList()) {
      _inputs.remove(key)!.dispose();
    }
    await _queue;
    if (committed && _masters[root] != null) {
      for (final entry in _masters[root]!.entries) {
        _committedMasters.putIfAbsent(entry.key, () => {}).addAll(entry.value);
      }
      _staleMasterRoots.addAll(
        details.keys.where((id) => id != root && changed(id)),
      );
    }
    final roots = {
      root,
      if (committed) ...details.keys.where((id) => id != root && !changed(id)),
    };
    generation++;
    for (final id in roots) {
      drafts.remove(id)?.close();
      _masters.remove(id);
      for (final key
          in _inputs.keys.where((key) => key.startsWith('$id|')).toList()) {
        _inputs.remove(key)!.dispose();
      }
      _masterWritable.removeWhere((key, _) => key.startsWith('$id|'));
      _staleMasterRoots.remove(id);
      _colors.removeWhere((key, _) => key.startsWith('$id|'));
      if (current) notifyListeners();
      await _openRoot(details[id]!);
    }
    if (current) {
      await onChanged();
      notifyListeners();
    }
  }

  Future<void> acceptReplacement(
    String root,
    GoodsBomEditDraft draft, {
    required String sourceRoot,
    required Set<String> components,
  }) async {
    await flush(root: root);
    if (!current || draft.rootGoodsId != root) {
      throw ApiException('BOM_EDIT_CHANGED', '对比对象已变化');
    }
    final source =
        await drafts[sourceRoot]?.list(sourceRoot) ?? const <GoodsBomItem>[];
    final targets = await draft.list(root);
    for (final key
        in _inputs.keys.where((key) => key.startsWith('$root|')).toList()) {
      _inputs.remove(key)!.dispose();
    }
    drafts.remove(root)?.close();
    drafts[root] = draft;
    generation++;
    for (final item in targets.where(
      (item) => components.contains(item.componentGoodsId),
    )) {
      final origin = source
          .where(
            (candidate) => candidate.componentGoodsId == item.componentGoodsId,
          )
          .firstOrNull;
      _colors.remove('$root|${item.id}');
      if (origin != null && _colors.containsKey('$sourceRoot|${origin.id}')) {
        _colors['$root|${item.id}'] = _colors['$sourceRoot|${origin.id}'];
      }
    }
    if (current) {
      await onChanged();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    for (final input in _inputs.values) {
      input.dispose();
    }
    for (final draft in drafts.values) {
      draft.close();
    }
    _inputs.clear();
    drafts.clear();
    super.dispose();
  }
}
