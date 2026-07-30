// 采购单据状态徽章（草稿/已审/红冲）。复用主题色。
import 'package:flutter/material.dart';

import '../models/purchase_doc.dart';

class PurchaseStatusBadge extends StatelessWidget {
  const PurchaseStatusBadge({
    super.key,
    required this.status,
    this.closed = false,
  });
  final int? status;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = purchaseStatusColor(status, theme);
    final label = purchaseStatusLabel(status);
    return Container(
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
    );
  }
}
