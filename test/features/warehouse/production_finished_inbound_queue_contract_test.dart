import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'finished inbound queue is recoverable and refreshed after stock actions',
    () {
      final provider = File(
        'lib/features/warehouse/providers/'
        'production_finished_inbound_task_count_provider.dart',
      ).readAsStringSync();
      final globalRefresh = File(
        'lib/features/dashboard/providers/workbench_refresh.dart',
      ).readAsStringSync();
      final moduleBadge = File(
        'lib/features/dashboard/widgets/module_badge_sum.dart',
      ).readAsStringSync();
      final warehouseHub = File(
        'lib/features/warehouse/pages/warehouse_hub_page.dart',
      ).readAsStringSync();
      final stockDetail = File(
        'lib/features/warehouse/pages/stock_doc_detail_page.dart',
      ).readAsStringSync();

      expect(provider, contains('Perm.stockDocView'));
      expect(provider, contains('.pendingCount()'));
      expect(
        globalRefresh,
        contains('warehouseProductionFinishedInboundPendingCountProvider'),
      );
      expect(
        moduleBadge,
        contains('warehouseProductionFinishedInboundPendingCountProvider'),
      );
      expect(
        warehouseHub,
        contains('WarehouseProductionFinishedInboundPendingBadge'),
      );
      expect(warehouseHub, contains('warehouseProductionFinishedInboundTasks'));
      expect(
        RegExp(
          r'warehouseProductionFinishedInboundPendingCountProvider',
        ).allMatches(stockDetail).length,
        greaterThanOrEqualTo(3),
        reason:
            'approve/issue/finished-in confirm and reverse paths must refresh '
            'the authoritative queue badge',
      );
    },
  );
}
