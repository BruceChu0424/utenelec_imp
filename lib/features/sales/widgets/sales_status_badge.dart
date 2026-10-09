// 销售单据状态徽章（草稿/已审/红冲/待财务核价）。与采购 PurchaseStatusBadge 同构：
// ADR-169 后主状态渲染走共享 UtenStatusBadge 深色实底档位（原 UtenDocStatusPill +
// raw Color 浅底胶囊已收编）；副标药丸（已中止/应收已立帐）仍走 UtenDocStatusPill。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_doc_status_pill.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/theme/uten_colors.dart';
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
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        UtenStatusBadge(
          label: closed && status == 1 ? '已审·结案' : salesStatusLabel(status),
          type: salesStatusBadgeType(status),
        ),
        // 已中止=中性终态（ADR-169：GitHub「已关闭」改灰同款口径，终态不抢红）。
        if (stopped && status == 1)
          UtenDocStatusPill(
            label: '已中止',
            color: theme.colorScheme.onSurfaceVariant,
          ),
        // 应收已立帐=财务事实标注（非主状态）：保持青绿色相与主状态绿区分，
        // 裸 Colors.teal 已收编进 statusTeal。
        if (arPosted)
          const UtenDocStatusPill(label: '应收已立帐', color: UtenColors.statusTeal),
      ],
    );
  }
}
