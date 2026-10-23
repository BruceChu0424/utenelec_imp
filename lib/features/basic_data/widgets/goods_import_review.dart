import 'package:flutter/material.dart';

import '../models/goods_import.dart';
import '../pages/import_review_page.dart';
import 'basic_data_l10n.dart';

/// 货品与组件共用同一个差异页；选项只引用服务端检测计划里的稳定行键。
Future<Set<String>?> reviewGoodsImport(
  BuildContext context, {
  required String title,
  required List<GoodsImportReviewRow> rows,
  required int added,
  required int filled,
  required int conflicts,
  required int unchanged,
  String? filename,
}) {
  final l = basicDataL10n(context);
  return showImportReviewPage(
    context,
    title: title,
    description: [
      if (filename?.isNotEmpty == true) filename!,
      l.importReviewSummary(added, filled, conflicts, unchanged),
    ].join('\n'),
    ignoreDescription: l.importReviewIgnoreExplanation,
    rows: [
      for (final row in rows)
        ImportReviewRow(
          rowKey: row.rowKey,
          sourceRow: row.rowNum,
          identityLabel: [
            row.code,
            row.name,
            if (row.seq?.isNotEmpty == true) row.seq!,
            row.categoryPath,
          ].where((value) => value.isNotEmpty).join(' / '),
          matchReason: switch (row.matchType) {
            'UUID' => l.importMatchUuid,
            'PATH_NAME' => l.importMatchPathName,
            _ => l.importMatchCode,
          },
          selectable: row.hasConflicts,
          cells: [
            for (final change in row.changes)
              ImportReviewCell(
                key: change.field,
                label: change.label,
                before: change.oldValue,
                after: change.newValue,
              ),
          ],
        ),
    ],
  );
}
