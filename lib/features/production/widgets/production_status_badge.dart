// 生产单据状态徽章：草稿 / 已审 / 红冲 + 结案/中止/取消 副标。
//
// 与采购 PurchaseStatusBadge 同源（同 0/1/-1 状态机）；生产多出 is_closed/is_stopped/is_canceled
// 三个布尔，按优先级 中止 > 取消 > 结案 拼到主标签后。
import 'package:flutter/material.dart';

import '../models/production_plan.dart';

class ProductionStatusBadge extends StatelessWidget {
  const ProductionStatusBadge({
    super.key,
    required this.status,
    this.closed = false,
    this.stopped = false,
    this.canceled = false,
  });

  final int? status;
  final bool closed;
  final bool stopped;
  final bool canceled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = productionStatusColor(status, theme);
    // 副标优先级：红冲已反向，不再追加；草稿不追加；仅已审追加结案/中止/取消。
    String suffix = '';
    if (status == kProductionStatusApproved) {
      if (stopped) {
        suffix = '·中止';
      } else if (canceled) {
        suffix = '·取消';
      } else if (closed) {
        suffix = '·结案';
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
        '${productionStatusLabel(status)}$suffix',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
