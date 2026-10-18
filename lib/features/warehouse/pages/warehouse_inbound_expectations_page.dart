// Legacy links use the same item rows, filters and workflow entry points as the task center.
import 'package:flutter/material.dart';

import 'warehouse_task_center_page.dart';

class WarehouseInboundExpectationsPage extends StatelessWidget {
  const WarehouseInboundExpectationsPage({super.key});

  @override
  Widget build(BuildContext context) => const WarehouseTaskCenterPage(
    initialGroup: 'inbound',
    initialSection: 'ALL',
  );
}
