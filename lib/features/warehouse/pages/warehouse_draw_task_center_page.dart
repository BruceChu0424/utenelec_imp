import 'package:flutter/material.dart';

import 'warehouse_outbound_task_center_page.dart';

/// The legacy draw entry uses the same physical rows and selection contract as outbound.
class WarehouseDrawTaskCenterPage extends StatelessWidget {
  const WarehouseDrawTaskCenterPage({
    super.key,
    this.embedded = false,
    this.externalKeyword,
    this.externalRefreshTick,
    this.externalHeader,
  });

  final bool embedded;
  final String? externalKeyword;
  final int? externalRefreshTick;
  final Widget? externalHeader;

  @override
  Widget build(BuildContext context) => WarehouseOutboundTaskCenterPage(
    embedded: embedded,
    externalKeyword: externalKeyword,
    externalRefreshTick: externalRefreshTick,
    externalHeader: externalHeader,
    initialSection: 'DRAW',
  );
}
