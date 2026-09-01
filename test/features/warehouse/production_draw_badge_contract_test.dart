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
      // 2026-09-01 下午起 hub 的计数失效统一走 invalidateWarehouseTaskCounts
      //（内含领料待办失效），不再逐条写在 hub 里。
      expect(warehouseHub, contains('invalidateWarehouseTaskCounts'));
      expect(
        RegExp(
          r'ref\.invalidate\(warehouseProductionDrawPendingCountProvider\);',
        ).allMatches(stockDetail).length,
        greaterThanOrEqualTo(2),
        reason:
            'approve/issue/reverse flows must refresh the warehouse draw badge',
      );
      // 2026-09-01 重组：hub「生产领料任务中心」卡角标由
      // WarehouseDrawTaskBadge 渲染（同 provider，任一加载中不显示半程合计）。
      expect(warehouseHub, contains('WarehouseDrawTaskBadge'));
      final taskCenterBadges = File(
        'lib/features/warehouse/widgets/warehouse_task_center_badges.dart',
      ).readAsStringSync();
      expect(
        taskCenterBadges,
        contains('warehouseProductionDrawPendingCountProvider'),
      );
    },
  );
}
