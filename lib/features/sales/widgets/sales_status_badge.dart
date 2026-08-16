// 销售单据状态徽章（草稿/已审/红冲，复用主题色）。与采购 PurchaseStatusBadge 同构；
// 渲染走共享 UtenDocStatusPill（含已中止/应收已立帐副标药丸）。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_doc_status_pill.dart';
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
        UtenDocStatusPill(
          label: closed && status == 1 ? '已审·结案' : salesStatusLabel(status),
          color: salesStatusColor(status, theme),
        ),
        if (stopped && status == 1)
          UtenDocStatusPill(label: '已中止', color: theme.colorScheme.error),
        if (arPosted)
          const UtenDocStatusPill(label: '应收已立帐', color: Colors.teal),
      ],
    );
  }
}
