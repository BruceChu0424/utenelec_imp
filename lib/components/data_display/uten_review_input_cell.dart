import 'package:flutter/material.dart';
import '../inputs/uten_table_cell_spec.dart';
import '../../shared/formatters/exact_decimal.dart';

/// Keeps the reviewed value visible while a reviewer edits its replacement.
/// The caller retains validation, permissions and persistence authority.
class UtenReviewInputCell extends StatelessWidget {
  const UtenReviewInputCell({
    super.key,
    required this.before,
    required this.after,
    required this.child,
    this.beforeLabel,
    this.beforeKey,
  });
  final String? before;
  final String? after;
  final String? beforeLabel;
  final Key? beforeKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (financeExactTrimmed(before) == financeExactTrimmed(after)) return child;
    final red = Theme.of(context).colorScheme.error;
    final inTable = UtenTableCellInputTheme.contains(context);
    final original = beforeLabel ?? before ?? '未填写';
    final retained = Text(
      original,
      key: beforeKey,
      maxLines: inTable ? 1 : null,
      overflow: inTable ? TextOverflow.ellipsis : null,
      style: TextStyle(
        color: red,
        decoration: TextDecoration.lineThrough,
        decorationColor: red,
      ),
    );
    return Semantics(
      label: '原值 ${beforeLabel ?? before ?? "未填写"}，修改为 ${after ?? "未填写"}',
      // Table hosts provide finite column widths. Avoid LayoutBuilder here:
      // stretch rows measure intrinsic height to draw continuous tree guides.
      child: inTable
          // Retain the reviewed value beside its replacement without adding
          // a second line to every editable row. Full text stays available on
          // hover and through the surrounding review semantics.
          ? Row(
              children: [
                Flexible(
                  child: Tooltip(message: original, child: retained),
                ),
                const SizedBox(width: 6),
                Expanded(flex: 2, child: child),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [retained, child],
            ),
    );
  }
}
