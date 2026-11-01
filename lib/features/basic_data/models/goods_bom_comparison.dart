import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../repositories/goods_bom_edit_repository.dart';
import '../repositories/goods_bom_repository.dart';
import 'goods_bom_copy.dart';
import 'goods_bom_item.dart';

enum BomDifference { same, changed, leftOnly, rightOnly }

/// Recipe comparison only. Stock, learned consumption and audit are contextual
/// facts belonging to each relationship, never fields to merge.
Map<String, String> bomComparisonValues(GoodsBomItem item) {
  String decimal(String? raw, num? value) =>
      financeExactTrimmed(raw ?? value?.toString()) ?? '—';
  return {
    '设计使用数量': decimal(item.qtyExactText, item.qty),
    '单价': decimal(item.priceExactText, item.price),
    '金额': decimal(item.totalExactText, item.total),
    '颜色':
        item.colorId ??
        (item.colorLegacyId == null ? '—' : '历史关联 #${item.colorLegacyId}'),
    '默认供应商':
        item.defaultSupplierId ??
        (item.vendLegacyId == null ? '—' : '历史关联 #${item.vendLegacyId}'),
    '管控阶段': item.controlStage.label,
    '计量方式': item.consumptionBasis.label,
    '基准产量': decimal(item.basisOutputQtyExactText, item.basisOutputQty),
    '允许尾包': item.allowPartialPackage ? '允许' : '整包',
    '齐套门槛': item.hardGate ? '启用' : '关闭',
    '备注': item.summary ?? '',
  };
}

class BomComparisonRow {
  BomComparisonRow({
    required this.left,
    required this.right,
    this.orderChanged = false,
  }) {
    final a = left == null ? <String, String>{} : bomComparisonValues(left!);
    final b = right == null ? <String, String>{} : bomComparisonValues(right!);
    fields = {
      for (final key in {...a.keys, ...b.keys})
        if (a[key] != b[key]) key,
    };
  }

  final GoodsBomItem? left, right;
  final bool orderChanged;
  late final Set<String> fields;
  String get key => (left ?? right)!.componentGoodsId;
  BomDifference get difference => left == null
      ? BomDifference.rightOnly
      : right == null
      ? BomDifference.leftOnly
      : fields.isNotEmpty || orderChanged
      ? BomDifference.changed
      : BomDifference.same;
}

class GoodsBomComparison {
  GoodsBomComparison._(
    this.leftId,
    this.rightId,
    this.left,
    this.right,
    this.rows,
  );
  final String leftId, rightId;
  final List<GoodsBomItem> left, right;
  final List<BomComparisonRow> rows;

  static Future<GoodsBomComparison> build({
    required String leftId,
    required String rightId,
    required List<GoodsBomItem> left,
    required List<GoodsBomItem> right,
    required bool Function() isCurrent,
  }) async {
    final leftMap = {for (final item in left) item.componentGoodsId: item};
    final rightMap = {for (final item in right) item.componentGoodsId: item};
    if (leftMap.length != left.length || rightMap.length != right.length) {
      throw ApiException('BOM_COMPARE_DUPLICATE', '同层存在重复组件，请先修复 BOM 后再对比');
    }
    final commonLeft = leftMap.keys.where(rightMap.containsKey).toList();
    final commonRight = rightMap.keys.where(leftMap.containsKey).toList();
    final rightRanks = {
      for (var i = 0; i < commonRight.length; i++) commonRight[i]: i,
    };
    final reordered = {
      for (var i = 0; i < commonLeft.length; i++)
        if (rightRanks[commonLeft[i]] != i) commonLeft[i],
    };
    final rows = <BomComparisonRow>[];
    for (final id in {...leftMap.keys, ...rightMap.keys}) {
      if (rows.length % 128 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (!isCurrent()) {
          throw ApiException('BOM_COMPARE_CHANGED', '对比对象已变化，请重新分析');
        }
      }
      rows.add(
        BomComparisonRow(
          left: leftMap[id],
          right: rightMap[id],
          orderChanged: reordered.contains(id),
        ),
      );
    }
    return GoodsBomComparison._(
      leftId,
      rightId,
      List.unmodifiable(left),
      List.unmodifiable(right),
      List.unmodifiable(rows),
    );
  }

  int count(BomDifference kind) =>
      rows.where((row) => row.difference == kind).length;

  /// New snapshots bind BOTH source and destination to preview/commit. A stale
  /// comparison must never silently adopt newer source or target values.
  Future<BomComparisonReplacement> prepare({
    required bool toLeft,
    required Set<String>? selected,
    required GoodsBomRepository repository,
    required ApiClient api,
    required bool Function() isCurrent,
  }) async {
    if (leftId == rightId) {
      throw ApiException('BOM_COMPARE_SAME', '两侧是同一货品，无需替换');
    }
    final targetId = toLeft ? leftId : rightId;
    final sourceId = toLeft ? rightId : leftId;
    final target = toLeft ? left : right;
    final source = toLeft ? right : left;
    final draft = GoodsBomEditDraft(
      base: repository,
      api: api,
      rootGoodsId: targetId,
      isCurrent: isCurrent,
    );
    try {
      final currentTarget = await draft.list(targetId);
      final currentSource = await draft.list(sourceId);
      bool unchanged(List<GoodsBomItem> a, List<GoodsBomItem> b) {
        if (a.length != b.length) return false;
        for (var i = 0; i < a.length; i++) {
          if (a[i].id != b[i].id ||
              a[i].componentGoodsId != b[i].componentGoodsId ||
              a[i].componentIssueMethod != b[i].componentIssueMethod ||
              a[i].componentUnitName != b[i].componentUnitName ||
              a[i].componentModel != b[i].componentModel ||
              a[i].componentSpec != b[i].componentSpec ||
              a[i].componentMaterial != b[i].componentMaterial) {
            return false;
          }
          final av = bomComparisonValues(a[i]), bv = bomComparisonValues(b[i]);
          if (av.keys.any((key) => av[key] != bv[key])) return false;
        }
        return true;
      }

      if (!unchanged(target, currentTarget) ||
          !unchanged(source, currentSource)) {
        throw ApiException('BOM_COMPARE_STALE', '源或目标 BOM 已被修改，请重新分析后再替换');
      }
      final targetMap = {
        for (final item in target) item.componentGoodsId: item,
      };
      final sourceMap = {
        for (final item in source) item.componentGoodsId: item,
      };
      final chosen = selected ?? rows.map((row) => row.key).toSet();
      final removed = target
          .where(
            (item) =>
                chosen.contains(item.componentGoodsId) &&
                !sourceMap.containsKey(item.componentGoodsId),
          )
          .toList();
      final added = source
          .where(
            (item) =>
                chosen.contains(item.componentGoodsId) &&
                !targetMap.containsKey(item.componentGoodsId),
          )
          .toList();
      var updated = 0;
      if (removed.isNotEmpty) {
        await draft.deleteMany(targetId, removed.map((e) => e.id).toList());
      }
      var processed = 0;
      for (final item in source) {
        if (++processed % 32 == 0) await Future<void>.delayed(Duration.zero);
        final old = targetMap[item.componentGoodsId];
        if (old == null || !chosen.contains(item.componentGoodsId)) continue;
        final a = bomComparisonValues(old), b = bomComparisonValues(item);
        if (a.keys.every((key) => a[key] == b[key])) continue;
        // New assignments need canonical UUIDs. Existing equal legacy-only
        // references may be retained, never silently cleared or matched by name.
        final legacyColor = item.colorId == null && item.colorLegacyId != null;
        final legacySupplier =
            item.defaultSupplierId == null && item.vendLegacyId != null;
        if ((legacyColor && item.colorLegacyId != old.colorLegacyId) ||
            (legacySupplier && item.vendLegacyId != old.vendLegacyId)) {
          throw ApiException(
            'BOM_COMPARE_REFERENCE_UNRESOLVED',
            '来源组件仍有未关联主档的历史颜色或供应商，请先补全关联后再替换',
          );
        }
        await draft.update(targetId, old.id, {
          ...bomComponentCopyBody(item),
          // UPDATE must clear these fields when the source has no override.
          if (!legacyColor) 'colorId': item.colorId,
          if (!legacySupplier) 'defaultSupplierId': item.defaultSupplierId,
        });
        updated++;
      }
      if (added.isNotEmpty) {
        draft.rememberItems(added);
        await draft.paste(
          mode: BomPasteMode.append,
          targets: [BomPasteTarget(targetId)],
          items: added.map(bomComponentCopyBody).toList(),
        );
      }
      // Resolve new relationship IDs from the draft, retaining unchanged edges.
      final effective = await draft.list(targetId);
      final byId = {for (final item in effective) item.componentGoodsId: item};
      final desired = effective.map((e) => e.componentGoodsId).toList();
      final moveKeys = selected == null
          ? sourceMap.keys.toSet()
          : {
              ...added.map((item) => item.componentGoodsId),
              for (final row in rows)
                if (row.orderChanged && chosen.contains(row.key)) row.key,
            };
      // A field-only merge never repositions the selected relationship.
      for (var index = source.length - 1; index >= 0; index--) {
        final id = source[index].componentGoodsId;
        if (!moveKeys.contains(id) || !byId.containsKey(id)) continue;
        desired.remove(id);
        final anchor = source
            .skip(index + 1)
            .map((e) => e.componentGoodsId)
            .where(desired.contains)
            .firstOrNull;
        desired.insert(
          anchor == null ? desired.length : desired.indexOf(anchor),
          id,
        );
      }
      final moves = <GoodsBomMove>[];
      final order = effective.map((e) => e.componentGoodsId).toList();
      for (var i = desired.length - 1; i >= 0; i--) {
        final id = desired[i];
        if (!moveKeys.contains(id)) continue;
        final anchor = i + 1 < desired.length ? desired[i + 1] : null;
        final oldIndex = order.indexOf(id);
        order.removeAt(oldIndex);
        final nextIndex = anchor == null ? order.length : order.indexOf(anchor);
        order.insert(nextIndex, id);
        if (oldIndex == nextIndex) continue;
        moves.add(
          GoodsBomMove(
            itemId: byId[id]!.id,
            targetParentGoodsId: targetId,
            anchorItemId: anchor == null ? null : byId[anchor]!.id,
          ),
        );
      }
      if (moves.isNotEmpty) await draft.move(targetId, moves);
      if (draft.operationCount > 500 ||
          moves.length > 500 ||
          removed.length > 500) {
        throw ApiException(
          'BOM_COMPARE_LIMIT',
          '本次替换超出单次 500 条操作限制，请分批勾选差异后替换',
        );
      }
      return BomComparisonReplacement(
        draft: draft,
        added: added.length,
        removed: removed.length,
        updated: updated,
        moved: moves.length,
      );
    } catch (_) {
      draft.close();
      rethrow;
    }
  }
}

class BomComparisonReplacement {
  const BomComparisonReplacement({
    required this.draft,
    required this.added,
    required this.removed,
    required this.updated,
    required this.moved,
  });
  final GoodsBomEditDraft draft;
  final int added, removed, updated, moved;
}
