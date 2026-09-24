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
  });

  final List<MasterColumnDef<T>> columns;
  final List<UtenRevisionRow<T>> rows;
  final bool embedded;
  final bool primary;
  final Widget? summaryBar;
  final double bottomContentPadding;
  final ValueNotifier<bool>? stickyHeaderPinned;

  @override
  Widget build(BuildContext context) => MasterDataTableView<UtenRevisionRow<T>>(
    embedded: embedded,
    primary: primary,
    bottomContentPadding: bottomContentPadding,
    stickyHeaderPinned: stickyHeaderPinned,
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
          value: (row) => column.value(row.value),
          cellBuilder: (cellContext, row) => Text(
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
                : DefaultTextStyle.of(cellContext).style,
          ),
          // Diffs deliberately use plain, copyable values. A source column may
          // have an action or its own color; neither belongs in an old snapshot.
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
