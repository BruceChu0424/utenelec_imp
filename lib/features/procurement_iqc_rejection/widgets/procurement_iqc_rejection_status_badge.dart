import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../models/procurement_iqc_rejection.dart';

/// 状态 → 徽章类型：徽章与表格状态列整格底色同源（2026-09-27 用户口径
/// 「格内胶囊改单元格背景色」，列表宽屏走 utenStatusBadgeCellColor 取同色）。
/// 档位锚定（ADR-169）：
/// - 待登记实物退回=danger：IQC 不合格已锁定（不良品隔离、未退回前流程锁死），
///   且是本页用户（采购/委外负责人）的红徽章待办；
/// - 实物已退回/待财务=warning：球在财务手上、无异常的等待外部；
/// - 贷项确认/零金额结案=success：闭环完成终态；
/// - 财务投影异常=danger：投影失败硬异常；
/// - 已反向/未知=neutral：任务被下游反向属中性终态（红冲发生在收货单上，
///   本任务记录本身没有负向财务事实）。
UtenStatusBadgeType procurementIqcRejectionBadgeType(
  ProcurementIqcRejectionStatus status,
) => switch (status) {
  ProcurementIqcRejectionStatus.pendingReturn => UtenStatusBadgeType.danger,
  ProcurementIqcRejectionStatus.returnRecorded => UtenStatusBadgeType.warning,
  ProcurementIqcRejectionStatus.creditConfirmed ||
  ProcurementIqcRejectionStatus.closedNoCredit => UtenStatusBadgeType.success,
  ProcurementIqcRejectionStatus.financeException => UtenStatusBadgeType.danger,
  ProcurementIqcRejectionStatus.reversed ||
  ProcurementIqcRejectionStatus.unknown => UtenStatusBadgeType.neutral,
};

class ProcurementIqcRejectionStatusBadge extends StatelessWidget {
  const ProcurementIqcRejectionStatusBadge({super.key, required this.status});

  final ProcurementIqcRejectionStatus status;

  @override
  Widget build(BuildContext context) => UtenStatusBadge(
    label: status.label,
    icon: switch (status) {
      ProcurementIqcRejectionStatus.pendingReturn =>
        Icons.assignment_return_outlined,
      ProcurementIqcRejectionStatus.returnRecorded =>
        Icons.local_shipping_outlined,
      ProcurementIqcRejectionStatus.creditConfirmed =>
        Icons.receipt_long_outlined,
      ProcurementIqcRejectionStatus.closedNoCredit =>
        Icons.money_off_csred_outlined,
      ProcurementIqcRejectionStatus.financeException =>
        Icons.error_outline_rounded,
      ProcurementIqcRejectionStatus.reversed => Icons.undo_rounded,
      ProcurementIqcRejectionStatus.unknown => Icons.help_outline_rounded,
    },
    type: procurementIqcRejectionBadgeType(status),
  );
}
