// 订货明细「重复货品」保存前复核（销售/采购/委外订货编辑页共用，2026-09-25）。
//
// 用户可能在明细里把同一货品加了多行（货品多选、复制粘贴、再次从上游引入都会
// 产生）。保存时先按页面给的组键聚合出重复组，弹窗列出清单让用户三选一：
//   汇总合并   —— 同组数量相加合并成一行，单价等其余内容沿用组内首行；
//   删除重复行 —— 每组只保留第一行（仅当全部组各行内容完全一致时提供，无损）；
//   返回修改   —— 不保存，页面把重复行整行标红（EditableGridRow.flagged）供检查。
// 弹窗被 ESC/点蒙层关闭按「返回修改」处理（返回 null），绝不静默保存。
import 'package:flutter/material.dart';

import '../../components/buttons/uten_button.dart';

/// 用户在重复货品复核弹窗里的决策。
enum DuplicateGoodsReviewAction { merge, dedupe, back }

/// 一组重复行（同组键出现 ≥2 行）。[rows] 保持明细原顺序；[identical] 表示
/// 组内各行除行号外内容完全一致（删除多余行不丢任何信息）。
class DuplicateGoodsGroup<T> {
  DuplicateGoodsGroup({
    required this.rows,
    required this.identityLabel,
    required this.rowSummaries,
    required this.identical,
  });

  final List<T> rows;

  /// 货品身份行（名称/编号/颜色/单位，采购/委外再含供应商），展示用。
  final String identityLabel;

  /// 每行摘要（含明细行号，如「第 2 行 · 数量 10 · 单价 3.5」），与 [rows] 对齐。
  final List<String> rowSummaries;

  final bool identical;
}

/// 按 [groupKey] 把「将提交」的行聚出重复组：只保留出现 ≥2 行的键；组序与组内
/// 行序都跟随明细原顺序（键首次出现的位置决定组的位置）。
List<DuplicateGoodsGroup<T>> collectDuplicateGoodsGroups<T>({
  required Iterable<T> rows,
  required int Function(T) rowNoOf,
  required String Function(T) groupKey,
  required String Function(T) identityLabel,
  required String Function(T row, int rowNo) rowSummary,
  required String Function(T) identicalSignature,
}) {
  final byKey = <String, List<T>>{};
  for (final row in rows) {
    byKey.putIfAbsent(groupKey(row), () => []).add(row);
  }
  return [
    for (final group in byKey.values.where((list) => list.length > 1))
      DuplicateGoodsGroup<T>(
        rows: group,
        identityLabel: identityLabel(group.first),
        rowSummaries: [
          for (final row in group) rowSummary(row, rowNoOf(row)),
        ],
        identical: group.map(identicalSignature).toSet().length == 1,
      ),
  ];
}

/// 重复货品复核弹窗。返回用户决策；null（ESC/蒙层关闭）按返回修改处理。
Future<DuplicateGoodsReviewAction?> showDuplicateGoodsReviewDialog<T>(
  BuildContext context, {
  required List<DuplicateGoodsGroup<T>> groups,
}) {
  assert(groups.isNotEmpty, '无重复组时不应弹出复核弹窗');
  // 只有每一组都「内容完全一致」时才提供删除重复行——组内数量/单价不同的话，
  // 删行就是丢数据，只能汇总或回去改。
  final dedupeAvailable = groups.every((g) => g.identical);
  return showDialog<DuplicateGoodsReviewAction>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final small = Theme.of(ctx).textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      );
      return SelectionArea(
        child: AlertDialog(
          title: Text(
            groups.length == 1 ? '发现重复货品' : '发现 ${groups.length} 组重复货品',
          ),
          // 比例护栏与 UtenDialog 同款：限宽限高、内容自滚（2026-09-11 弹窗规范）。
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 460,
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('以下货品在明细中出现了多行，请确认处理方式：'),
                  for (final g in groups) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(
                          alpha: 0.45,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            g.identityLabel,
                            style: Theme.of(ctx)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          for (final line in g.rowSummaries)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(line),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            g.identical
                                ? '各行内容完全一致'
                                : '各行数量或单价不同，汇总后单价沿用第一行',
                            style: small,
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    '汇总合并：同组数量相加合并为一行，其余内容沿用组内第一行。\n'
                    '${dedupeAvailable ? '删除重复行：每组只保留第一行。\n' : ''}'
                    '返回修改：不保存，重复行将在明细中整行标红。',
                    style: small,
                  ),
                ],
              ),
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () =>
                  Navigator.pop(ctx, DuplicateGoodsReviewAction.back),
              child: const Text('返回修改'),
            ),
            if (dedupeAvailable)
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () =>
                    Navigator.pop(ctx, DuplicateGoodsReviewAction.dedupe),
                child: const Text('删除重复行'),
              ),
            UtenButton(
              onPressed: () => Navigator.pop(ctx, DuplicateGoodsReviewAction.merge),
              child: const Text('汇总合并'),
            ),
          ],
        ),
      );
    },
  );
}
