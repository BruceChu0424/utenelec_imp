import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../models/procurement_iqc_rejection.dart';

/// 状态 → 徽章类型：徽章与表格状态列整格底色同源（2026-09-27 用户口径
/// 「格内胶囊改单元格背景色」，列表宽屏走 udenStatusBadgeCellColor 取同色）。
UtenStatusBadgeType procurementIqcRejectionBadgeType(
  ProcurementIqcRejectionStatus status,
) => switch (status) {
  ProcurementIqcRejectionStatus.pendingReturn => UtenStatusBadgeType.warning,
  ProcurementIqcRejectionStatus.returnRecorded => UtenStatusBadgeType.info,
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
