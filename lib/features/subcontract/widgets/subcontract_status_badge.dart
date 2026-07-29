// 委外单据状态徽章（草稿/已审/红冲；已审·立应付 / 已审·结案 复合标签）。
// 复用 subcontractStatusColor/Label（providers），主题色驱动。
import 'package:flutter/material.dart';

import '../models/subcontract_doc.dart';
import '../providers/subcontract_providers.dart';

class SubcontractStatusBadge extends StatelessWidget {
  const SubcontractStatusBadge({
    super.key,
    required this.status,
    this.closed = false,
    this.apPosted = false,
  });
  final int? status;
  final bool closed;
  final bool apPosted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = subcontractStatusColor(status, theme);
    var label = subcontractStatusLabel(status);
    if (status == kSubcontractStatusApproved) {
      if (apPosted && closed) {
        label = '已审·立账·结案';
      } else if (apPosted) {
        label = '已审·已立账';
      } else if (closed) {
        label = '已审·结案';
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
