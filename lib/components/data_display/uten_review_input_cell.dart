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
    this.decimalValues = true,
    this.replacementEnabled = true,
    this.showValueLabels = false,
  });
  final String? before;
  final String? after;
  final String? beforeLabel;
  final Key? beforeKey;

  /// Numeric review cells compare equivalent decimal scales by default.
  /// Identifiers and other text preserve every character when this is false.
  final bool decimalValues;

  /// A reviewed conflict can retain the original until replacement is chosen.
  final bool replacementEnabled;

  /// Use a visible original/imported pair when the review needs more context
  /// than a compact inline comparison. Other table callers keep their layout.
  final bool showValueLabels;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final changed = decimalValues
        ? financeExactTrimmed(before) != financeExactTrimmed(after)
        : (before ?? '') != (after ?? '');
    final red = Theme.of(context).colorScheme.error;
    final inTable = UtenTableCellInputTheme.contains(context);
    final original = beforeLabel ?? before ?? '未填写';
    final retained = Text(
      original,
      key: beforeKey,
      maxLines: inTable ? 1 : null,
      overflow: inTable ? TextOverflow.ellipsis : null,
      style: TextStyle(
        color: replacementEnabled
            ? red
            : Theme.of(context).colorScheme.onSurface,
        decoration: replacementEnabled
            ? TextDecoration.lineThrough
            : TextDecoration.none,
        decorationColor: red,
      ),
    );
    return Semantics(
      label: changed
          ? replacementEnabled
                ? '原值 ${beforeLabel ?? before ?? "未填写"}，修改为 ${after ?? "未填写"}'
                : '保留原值 ${beforeLabel ?? before ?? "未填写"}，导入值 ${after ?? "未填写"}尚未采用'
          : null,
      // Table hosts provide finite column widths. Avoid LayoutBuilder here:
      // stretch rows measure intrinsic height to draw continuous tree guides.
      child: showValueLabels
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                changed
                    ? Row(
                        children: [
                          Text(
                            '原值',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: ExcludeSemantics(
                              child: Tooltip(
                                message: original,
                                child: retained,
                              ),
                            ),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
                SizedBox(height: changed ? 4 : 0),
                Row(
                  children: [
                    changed
                        ? Text(
                            '导入值',
                            style: Theme.of(context).textTheme.bodySmall,
                          )
                        : const SizedBox.shrink(),
                    SizedBox(width: changed ? 6 : 0),
                    Expanded(child: child),
                  ],
                ),
              ],
            )
          : inTable
          // Retain the reviewed value beside its replacement without adding
          // a second line to every editable row. Full text stays available on
          // hover and through the surrounding review semantics.
          ? Row(
              children: [
                Flexible(
                  flex: changed ? 1 : 0,
                  child: changed
                      // The enclosing label already states the original value.
                      // Its visual disclosure must not lend an OverlayPortal
                      // traversal owner to the adjacent native text editor.
                      ? ExcludeSemantics(
                          child: Tooltip(message: original, child: retained),
                        )
                      : const SizedBox.shrink(),
                ),
                SizedBox(width: changed ? 6 : 0),
                Expanded(flex: changed ? 2 : 1, child: child),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              // Keep the input in the same slot before, during and after an
              // edit. Switching between the bare child and this layout would
              // recreate its state and disconnect the active text input.
              children: [changed ? retained : const SizedBox.shrink(), child],
            ),
    );
  }
}
