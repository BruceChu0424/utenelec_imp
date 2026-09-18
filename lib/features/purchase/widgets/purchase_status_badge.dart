// 采购单据状态徽章（草稿/已审/红冲）。渲染走共享 UtenDocStatusPill。
// 订货单传 financeApproval 时按财务审批投影显示（等待财务审核/财务退回/
// 财务已通过/待提交财务），与列表页状态列同口径——在审单不再误显「草稿」。
import 'package:flutter/material.dart';

import '../../../components/data_display/doc_status_badge.dart';
import '../../../components/data_display/uten_doc_status_pill.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../shared/models/procurement_finance_approval.dart';
import '../models/purchase_doc.dart';

class PurchaseStatusBadge extends StatelessWidget {
  const PurchaseStatusBadge({
    super.key,
    required this.status,
    this.closed = false,
    this.financeApproval,
  });
  final int? status;
  final bool closed;

  /// 订货单财务审批投影（服务端权威）：非空时按审批态显示文案/颜色；
  /// 收货/退货/申请不传（无该投影），维持单据 0/1/-1/2 状态口径。
  final ProcurementFinanceApproval? financeApproval;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = financeApproval == null
        ? purchaseStatusLabel(status)
        : purchaseOrderDisplayLabel(status, financeApproval);
    final color = financeApproval == null
        ? purchaseStatusColor(status, theme)
        : purchaseOrderDisplayColor(status, financeApproval, theme);
    return UtenDocStatusPill(
      label: closed && status == kPurchaseStatusApproved ? '$label·结案' : label,
      color: color,
    );
  }
}

/// 订货单列表状态列的徽章语义（与 [purchaseOrderDisplayLabel] 同口径）：
/// 等待财务审核=警告 / 财务退回=危险 / 财务已通过=成功 / 待提交财务=中性；
/// 红冲/已取消终态与无投影/未知态回落单据 0/1/-1/2 语义。
UtenStatusBadgeType purchaseOrderDisplayBadgeType(
  int? status,
  ProcurementFinanceApproval? financeApproval,
) {
  if (status == kPurchaseStatusReversed || status == kPurchaseStatusCanceled) {
    return docStatusBadgeType(status);
  }
  return switch (financeApproval?.status) {
    'PENDING' => UtenStatusBadgeType.warning,
    'REJECTED' => UtenStatusBadgeType.danger,
    'APPROVED' => UtenStatusBadgeType.success,
    'DRAFT' => UtenStatusBadgeType.neutral,
    _ => docStatusBadgeType(status),
  };
}
