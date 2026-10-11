import '../../shared/platform_tables/platform_table_binding.dart';
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../features/basic_data/widgets/master_data_table_view.dart';

enum UtenRevisionKind { unchanged, removed, added }

/// A complete document row. Revisions are represented by an old/new pair;
/// totals must always come from the current document, never these display rows.
class UtenRevisionRow<T> {
  const UtenRevisionRow({
    required this.value,
    required this.kind,
    this.label,
    this.changedKeys = const {},
  });

  final T value;
  final UtenRevisionKind kind;
  final String? label;

  /// Column keys whose actual business value changed in an old/new pair.
  /// Pure additions keep this empty so they remain entirely green.
  final Set<String> changedKeys;

  String get statusLabel =>
      label ??
      switch (kind) {
        UtenRevisionKind.unchanged => '未修改',
        UtenRevisionKind.removed => '修改前',
        UtenRevisionKind.added => '修改后',
      };
}

Color? utenRevisionForeground(BuildContext context, UtenRevisionKind kind) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (kind) {
    UtenRevisionKind.unchanged => null,
    UtenRevisionKind.removed =>
      dark ? UtenColors.errorOnDark : UtenColors.errorText,
    UtenRevisionKind.added =>
      dark ? UtenColors.successOnDark : UtenColors.successText,
  };
}

Color? utenRevisionBackground(BuildContext context, UtenRevisionKind kind) {
  if (kind == UtenRevisionKind.unchanged) return null;
  if (Theme.of(context).brightness == Brightness.dark) {
    return utenRevisionForeground(context, kind)!.withValues(alpha: 0.12);
  }
  return kind == UtenRevisionKind.removed
      ? UtenColors.errorBg
      : UtenColors.successBg;
}

/// The strike is painted across the entire row, including empty cells. It does
/// not intercept copying, horizontal scrolling, or screen-reader navigation.
class UtenRevisionStrike extends StatelessWidget {
  const UtenRevisionStrike({
    super.key,
    required this.color,
    required this.child,
  });

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    foregroundPainter: _RevisionStrikePainter(color),
    child: child,
  );
}

class _RevisionStrikePainter extends CustomPainter {
  const _RevisionStrikePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawLine(
    Offset(0, size.height / 2),
    Offset(size.width, size.height / 2),
    Paint()
      ..color = color.withValues(alpha: 0.65)
      ..strokeWidth = 1.2,
  );

  @override
  bool shouldRepaint(_RevisionStrikePainter oldDelegate) =>
      color != oldDelegate.color;
}

/// Uses the normal document table (same columns, scrolling and full screen).
/// Callers supply authoritative snapshots in original order, inserting each
/// changed row's new version directly below its old version.
class UtenRevisionTable<T> extends StatelessWidget {
  const UtenRevisionTable({
    super.key,
    required this.columns,
    required this.rows,
    this.embedded = false,
    this.primary = false,
    this.summaryBar,
    this.bottomContentPadding = 0,
    this.stickyHeaderPinned,
    this.tableKey,
    this.platformBinding,
    this.highlightColumnKeys = const {},
    this.cellBuilders,
    this.selectable = false,
    this.showSelectionColumn = true,
    this.singleSelection = false,
    this.idOf,
    this.selectedIds = const <String>{},
    this.onSelectedIdsChanged,
    this.showSelectionSummary = true,
  });

  final String? tableKey;
  final PlatformTableBinding<T>? platformBinding;
  final List<MasterColumnDef<T>> columns;
  final List<UtenRevisionRow<T>> rows;
  final bool embedded;
  final bool primary;
  final Widget? summaryBar;
  final double bottomContentPadding;
  final ValueNotifier<bool>? stickyHeaderPinned;

  /// 需要全程红色加粗强调的列 (2026-10-10 财务订货审批口径：数量/单价/总金额/
  /// 折合人民币/超收损耗比等关键核对值)。与修订对比的「+修改后」高亮同色同字重，
  /// 语义是「请逐行核对这些数字」，不参与增删行着色。
  final Set<String> highlightColumnKeys;

  /// 指定列的自定义单元格（逃生口）：本表默认把每列强制包成纯 Text（修订对比
  /// 用可复制纯值），个别列需要交互控件（如订货审批的汇率编辑格）时经此注入。
  /// 命中的列不再套红字/highlight 替换，样式由调用方自带；[MasterColumnDef.value]
  /// 仍是排序/列宽/无障碍的真值。
  final Map<
    String,
    Widget Function(BuildContext context, UtenRevisionRow<T> row)
  >?
  cellBuilders;

  /// 多选（2026-10-10 审核页防看岔行口径）：与 MasterDataTableView 同一套
  /// 勾选/全选/选中行高亮；[idOf] 作用于行业务值（同一行的「修改前/修改后」
  /// 两条快照共用同一 id，勾一条即视为勾中该行业务行）。
  final bool selectable;

  /// 多选时是否渲染最前列勾选框列（透传 MasterDataTableView 同名参数；
  /// 纯阅读勾选的审核页传 false——行单击切选中，不画勾选框列）。
  final bool showSelectionColumn;

  /// 选中互斥（单选，透传 MasterDataTableView 同名参数）：点击行选中该行并
  /// 取消其他；审核页防看岔纯阅读勾选传 true。
  final bool singleSelection;
  final String? Function(T item)? idOf;
  final Set<String> selectedIds;
  final void Function(Set<String> next)? onSelectedIdsChanged;
  final bool showSelectionSummary;

  @override
  Widget build(BuildContext context) {
    final binding =
        platformBinding ??
        PlatformTableCatalogScope.resolve(
          context,
          PlatformTableDescriptor<T>(
            kind: 'revision',
            tableKey: tableKey,
            columnKeys: columns.map((c) => c.key).toList(),
            rows: rows.map((row) => row.value).toList(),
          ),
        );
    final interactiveKeys = cellBuilders?.keys.toSet() ?? const <String>{};
    return MasterDataTableView<UtenRevisionRow<T>>(
      tableKey: tableKey,
      platformBinding: binding == null
          ? null
          : PlatformTableBinding<UtenRevisionRow<T>>(
              tableKey: binding.tableKey,
              scope: binding.scope,
              columnAliases: binding.columnAliases,
              defaultColumnOrder: binding.defaultColumnOrder,
              defaultVisibleColumnKeys: binding.defaultVisibleColumnKeys == null
                  ? null
                  : ['_revision', ...binding.defaultVisibleColumnKeys!],
              revealPopulatedColumnKeys: binding.revealPopulatedColumnKeys,
              recordIdOf: (row) => binding.recordIdOf(row.value),
              snapshotOf: (row) => binding.snapshotOf?.call(row.value),
              factListenablesOf: binding.factListenablesOf == null
                  ? null
                  : (row) => binding.factListenablesOf!(row.value),
              factValuesOf: binding.factValuesOf == null
                  ? null
                  : (row) => binding.factValuesOf!(row.value),
            ),
      embedded: embedded,
      platformCellDecorator: (context, row, key, value, child) =>
          interactiveKeys.contains(key)
          ? child
          : row.kind == UtenRevisionKind.added && row.changedKeys.contains(key)
          ? Text(
              value?.isNotEmpty == true ? value! : '未填写',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: utenRevisionForeground(
                  context,
                  UtenRevisionKind.removed,
                ),
                fontWeight: FontWeight.w800,
              ),
            )
          : highlightColumnKeys.contains(key)
          ? Text(
              value?.isNotEmpty == true ? value! : '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: utenRevisionForeground(
                  context,
                  UtenRevisionKind.removed,
                ),
                fontWeight: FontWeight.w800,
              ),
            )
          : child,
      primary: primary,
      bottomContentPadding: bottomContentPadding,
      stickyHeaderPinned: stickyHeaderPinned,
      selectable: selectable,
      showSelectionColumn: showSelectionColumn,
      singleSelection: singleSelection,
      idOf: idOf == null
          ? null
          : (row) =>
                row.kind == UtenRevisionKind.removed ? null : idOf!(row.value),
      selectedIds: selectedIds,
      onSelectedIdsChanged: onSelectedIdsChanged,
      showSelectionSummary: showSelectionSummary,
      columns: [
        MasterColumnDef(
          key: '_revision',
          label: '变更',
          width: 108,
          value: (row) =>
              '${switch (row.kind) {
                UtenRevisionKind.unchanged => '=',
                UtenRevisionKind.removed => '−',
                UtenRevisionKind.added => '+',
              }} ${row.statusLabel}',
        ),
        for (final column in columns)
          MasterColumnDef(
            key: column.key,
            label: column.label,
            width: column.width,
            type: column.type,
            info: column.info,
            defaultVisible: column.defaultVisible,
            exportDefinition: column.exportDefinition,
            exactListenableOf: column.exactListenableOf == null
                ? null
                : (row) => column.exactListenableOf!(row.value),
            exactValueOf: column.exactValueOf == null
                ? null
                : (row) => column.exactValueOf!(row.value),
            value: (row) => column.value(row.value),
            cellBuilder:
                cellBuilders != null && cellBuilders!.containsKey(column.key)
                ? (cellContext, row) =>
                      cellBuilders![column.key]!(cellContext, row)
                : (cellContext, row) => Text(
                    row.kind == UtenRevisionKind.added &&
                            row.changedKeys.contains(column.key) &&
                            (column.value(row.value)?.isEmpty ?? true)
                        ? '未填写'
                        : column.value(row.value) ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        row.kind == UtenRevisionKind.added &&
                            row.changedKeys.contains(column.key)
                        ? TextStyle(
                            color: utenRevisionForeground(
                              cellContext,
                              UtenRevisionKind.removed,
                            ),
                            fontWeight: FontWeight.w800,
                          )
                        : highlightColumnKeys.contains(column.key)
                        ? TextStyle(
                            color: utenRevisionForeground(
                              cellContext,
                              UtenRevisionKind.removed,
                            ),
                            fontWeight: FontWeight.w800,
                          )
                        : DefaultTextStyle.of(cellContext).style,
                  ),
            // Diffs deliberately use plain, copyable values. A source column may
            // have an action or its own color; neither belongs in an old snapshot.
            // [cellBuilders] is the sanctioned escape hatch for interactive cells
            // (e.g. the finance rate editor); highlight decoration is skipped for
            // those keys so it cannot clobber the caller's widget.
          ),
      ],
      items: rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      rowColor: (row) => utenRevisionBackground(context, row.kind),
      rowForegroundColor: (row) => utenRevisionForeground(context, row.kind),
      rowDecorationBuilder: (context, row, child) => Semantics(
        label: row.statusLabel,
        child: row.kind == UtenRevisionKind.removed
            ? UtenRevisionStrike(
                color: utenRevisionForeground(context, row.kind)!,
                child: child,
              )
            : child,
      ),
      summaryBar: summaryBar,
      summaryBarInline: true,
    );
  }
}

class UtenRevisionField {
  const UtenRevisionField({
    required this.label,
    required this.before,
    required this.after,
  });
  final String label;
  final String before;
  final String after;
}

/// Header-only changes remain compact and wrap long addresses/remarks, without
/// repeating item changes above the document table.
class UtenRevisionFields extends StatelessWidget {
  const UtenRevisionFields({super.key, required this.changes});
  final List<UtenRevisionField> changes;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final field in changes)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(field.label, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              _value(context, field.before, UtenRevisionKind.removed),
              _value(context, field.after, UtenRevisionKind.added),
            ],
          ),
        ),
    ],
  );

  Widget _value(BuildContext context, String value, UtenRevisionKind kind) {
    final color = utenRevisionForeground(context, kind)!;
    final old = kind == UtenRevisionKind.removed;
    final child = Container(
      color: utenRevisionBackground(context, kind),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(old ? '−' : '+', style: TextStyle(color: color)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value.isEmpty ? '未填写' : value,
              style: TextStyle(
                color: old
                    ? color
                    : utenRevisionForeground(context, UtenRevisionKind.removed),
                fontWeight: old ? null : FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      label: old ? '修改前' : '修改后',
      child: old ? UtenRevisionStrike(color: color, child: child) : child,
    );
  }
}
