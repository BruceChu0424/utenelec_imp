import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production draw badge is permission-gated and refreshed everywhere',
    () {
      final provider = File(
        'lib/features/warehouse/providers/production_draw_count_provider.dart',
      ).readAsStringSync();
      final globalRefresh = File(
        'lib/features/dashboard/providers/workbench_refresh.dart',
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
        contains(
          'ref.invalidate(warehouseProductionDrawPendingCountProvider);',
        ),
      );
      expect(
        warehouseHub,
        contains(
          'ref.invalidate(warehouseProductionDrawPendingCountProvider);',
        ),
      );
      expect(
        RegExp(
          r'ref\.invalidate\(warehouseProductionDrawPendingCountProvider\);',
        ).allMatches(stockDetail).length,
        greaterThanOrEqualTo(2),
        reason:
            'approve/issue/reverse flows must refresh the warehouse draw badge',
      );
      expect(warehouseHub, contains('WarehouseProductionDrawPendingBadge'));
    },
  );
}
