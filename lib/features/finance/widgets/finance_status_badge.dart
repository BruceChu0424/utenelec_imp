// 钱流单据状态徽章（草稿/已审/红冲）。渲染走共享 UtenStatusBadge
//（ADR-169：状态一律走十档深色实底，草稿=灰 / 已审=绿 / 红冲=红，
// 与列表状态列 docStatusBadgeType 同一档位映射；旧的 xStatusColor
// 裸色映射已随之删除）。
import 'package:flutter/material.dart';

import '../../../components/data_display/doc_status_badge.dart';
import '../../../components/data_display/uten_status_badge.dart';
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
    return UtenStatusBadge(
      label: closed && status == kFinanceStatusApproved
          ? '已结'
          : financeStatusLabel(status),
      type: docStatusBadgeType(status),
    );
  }
}
