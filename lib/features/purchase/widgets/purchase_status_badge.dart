// 采购单据状态徽章（草稿/已审/红冲/已取消 + 订货财务审批投影）。
// ADR-169 后渲染走共享 UtenStatusBadge 深色实底档位（原 UtenDocStatusPill +
// raw Color 浅底胶囊已收编）。订货单传 financeApproval 时按财务审批投影显示
// （等待财务审核/财务退回/财务已通过/待提交财务），与列表页状态列同口径——
// 在审单不再误显「草稿」。
import 'package:flutter/material.dart';

import '../../../components/data_display/doc_status_badge.dart';
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

  /// 订货单财务审批投影（服务端权威）：非空时按审批态显示文案/档位；
  /// 收货/退货/申请不传（无该投影），维持单据 0/1/-1/2 状态口径。
  final ProcurementFinanceApproval? financeApproval;

  @override
  Widget build(BuildContext context) {
    final label = financeApproval == null
        ? purchaseStatusLabel(status)
        : purchaseOrderDisplayLabel(status, financeApproval);
    final type = financeApproval == null
        ? docStatusBadgeType(status)
        : purchaseOrderDisplayBadgeType(status, financeApproval);
    return UtenStatusBadge(
      label: closed && status == kPurchaseStatusApproved ? '$label·结案' : label,
      type: type,
    );
  }
}

/// 订货单列表状态列的徽章语义（与 [purchaseOrderDisplayLabel] 同口径，
/// ADR-169 档位锚定）：
/// 等待财务审核=warning 亮琥珀（等外部、球在财务）/ 财务退回=danger 深红（驳回）/
/// 财务已通过=info 深蓝（已批流转、等收货——单据在流转中而非完成态）/
/// 待提交财务=neutral 灰；红冲/已取消终态与无投影/未知态回落单据 0/1/-1/2 语义
/// （已审=success、红冲=danger、草稿/已取消=neutral）。
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
    'APPROVED' => UtenStatusBadgeType.info,
    'DRAFT' => UtenStatusBadgeType.neutral,
    _ => docStatusBadgeType(status),
  };
}
