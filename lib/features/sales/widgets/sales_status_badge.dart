// 销售单据状态徽章（草稿/已审/红冲，复用主题色）。与采购 PurchaseStatusBadge 同构。
import 'package:flutter/material.dart';

import '../models/sales_doc.dart';

class SalesStatusBadge extends StatelessWidget {
  const SalesStatusBadge({
    super.key,
    required this.status,
    this.closed = false,
    this.stopped = false,
    this.arPosted = false,
  });
  final int? status;
  final bool closed;
  final bool stopped;
  final bool arPosted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = salesStatusColor(status, theme);
    final label = salesStatusLabel(status);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Text(
            closed && status == 1 ? '已审·结案' : label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (stopped && status == 1)
          _pill('已中止', theme.colorScheme.error, theme),
        if (arPosted) _pill('应收已立帐', Colors.teal, theme),
      ],
    );
  }

  Widget _pill(String text, Color color, ThemeData theme) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
