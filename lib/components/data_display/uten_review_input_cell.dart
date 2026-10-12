import 'package:flutter/material.dart';
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
    return Semantics(
      label: '原值 ${beforeLabel ?? before ?? "未填写"}，修改为 ${after ?? "未填写"}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            beforeLabel ?? before ?? '未填写',
            key: beforeKey,
            style: TextStyle(
              color: red,
              decoration: TextDecoration.lineThrough,
              decorationColor: red,
            ),
          ),
          child,
        ],
      ),
    );
  }
}
