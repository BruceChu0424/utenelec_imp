import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../models/procurement_iqc_rejection.dart';

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
    type: switch (status) {
      ProcurementIqcRejectionStatus.pendingReturn =>
        UtenStatusBadgeType.warning,
      ProcurementIqcRejectionStatus.returnRecorded => UtenStatusBadgeType.info,
      ProcurementIqcRejectionStatus.creditConfirmed ||
      ProcurementIqcRejectionStatus.closedNoCredit =>
        UtenStatusBadgeType.success,
      ProcurementIqcRejectionStatus.financeException =>
        UtenStatusBadgeType.danger,
      ProcurementIqcRejectionStatus.reversed ||
      ProcurementIqcRejectionStatus.unknown => UtenStatusBadgeType.neutral,
    },
  );
}
