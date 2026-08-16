// 钱流单据状态徽章（草稿/已审/红冲）。渲染走共享 UtenDocStatusPill
//（2026-08-16 起统一带描边/labelSmall 的共享口径）。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_doc_status_pill.dart';
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
    return UtenDocStatusPill(
      label: closed && status == kFinanceStatusApproved
          ? '已结'
          : financeStatusLabel(status),
      color: financeStatusColor(status, Theme.of(context)),
    );
  }
}
