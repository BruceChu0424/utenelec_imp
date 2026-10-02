import 'package:flutter/material.dart';

import '../../features/basic_data/widgets/master_data_table_view.dart';
import 'uten_revision_table.dart';

/// One business line occupies one display row. Only actual deletions strike
/// the complete row; edited cells retain the old value beside new-value columns.
class UtenCellRevisionRow<T> {
  const UtenCellRevisionRow({
    this.before,
    this.after,
    this.changedKeys = const {},
  }) : assert(before != null || after != null);

  final T? before;
  final T? after;
  final Set<String> changedKeys;
  T get value => before ?? after as T;
  bool get removed => after == null;
  bool get added => before == null;
  String get label => removed
      ? '已删除'
      : added
      ? '新增'
      : changedKeys.isEmpty
      ? '未修改'
      : '已修改';
}

class UtenCellRevisionTable<T> extends StatelessWidget {
  const UtenCellRevisionTable({
    super.key,
    required this.columns,
    required this.rows,
  });

  final List<MasterColumnDef<T>> columns;
  final List<UtenCellRevisionRow<T>> rows;

  @override
  Widget build(BuildContext context) {
    final red = utenRevisionForeground(context, UtenRevisionKind.removed)!;
    final changed = {for (final row in rows) ...row.changedKeys};
    return MasterDataTableView<UtenCellRevisionRow<T>>(
      embedded: true,
      columns: [
        MasterColumnDef(
          key: '_revision',
          label: '变更',
          width: 96,
          value: (row) => row.label,
        ),
        for (final column in columns)
          MasterColumnDef(
            key: column.key,
            label: column.label,
            width: column.width,
            type: column.type,
            value: (row) => column.value(row.value),
            cellBuilder: (context, row) => Text(
              column.value(row.value) ?? '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: row.changedKeys.contains(column.key) && !row.removed
                  ? TextStyle(
                      color: red,
                      decoration: TextDecoration.lineThrough,
                      decorationColor: red,
                    )
                  : null,
            ),
          ),
        for (final column in columns)
          if (changed.contains(column.key))
            MasterColumnDef(
              key: '_new_${column.key}',
              label: '新${column.label}',
              width: column.width,
              type: column.type,
              value: (row) =>
                  row.after != null && row.changedKeys.contains(column.key)
                  ? column.value(row.after as T) ?? '未填写'
                  : '',
              cellBuilder: (context, row) => Text(
                row.after != null && row.changedKeys.contains(column.key)
                    ? column.value(row.after as T) ?? '未填写'
                    : '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: red, fontWeight: FontWeight.w700),
              ),
            ),
      ],
      items: rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      rowForegroundColor: (row) => row.removed ? red : null,
      rowDecorationBuilder: (context, row, child) =>
          row.removed ? UtenRevisionStrike(color: red, child: child) : child,
    );
  }
}
