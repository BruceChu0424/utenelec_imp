import 'package:flutter/material.dart';

import '../../sales/widgets/sales_shipment_task_workbench.dart';

/// 财税部销售出货人工放行专页；不承载销售新建/编辑信息架构。
class FinanceSalesShipmentAuditPage extends StatelessWidget {
  const FinanceSalesShipmentAuditPage({super.key});

  @override
  Widget build(BuildContext context) => const SalesShipmentTaskWorkbench(
    mode: SalesShipmentTaskWorkbenchMode.financeAudit,
  );
}
