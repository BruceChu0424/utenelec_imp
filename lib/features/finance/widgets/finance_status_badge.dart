// 钱流单据状态徽章（草稿/已审/红冲）。
import 'package:flutter/material.dart';

import '../models/finance_doc.dart';

class FinanceStatusBadge extends StatelessWidget {
  const FinanceStatusBadge({
    super.key,
    required this.status,
    this.closed = false,
  });
  final int? status;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = financeStatusColor(status, theme);
    final label = financeStatusLabel(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        closed && status == kFinanceStatusApproved ? '已结' : label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
