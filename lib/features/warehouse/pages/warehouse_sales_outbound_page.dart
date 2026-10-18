// Legacy links use the same item rows, filters and workflow entry points as the task center.
import 'package:flutter/material.dart';

import 'warehouse_task_center_page.dart';

class WarehouseSalesOutboundPage extends StatelessWidget {
  const WarehouseSalesOutboundPage({super.key});

  @override
  Widget build(BuildContext context) => const WarehouseTaskCenterPage(
    initialGroup: 'outbound',
    initialSection: 'SALES',
  );
}
