import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 生产领料待办徽章(ADR-108 起随徽章汇总带回): 口径登记在服务端目录的
// warehouseDrawCenter 入口, 来源是履约工作台仓库计数(原端点的 @PreAuthorize 原样生效,
// 无权限的身份拿不到该入口); 仓库写操作成功后徽章汇总立即重拉。
void main() {
  test('production draw badge is permission-gated and refreshed everywhere', () {
    final catalog = File(
      'server/src/main/java/com/uten/imp/features/workbench/badge/'
      'WorkbenchBadgeCatalog.java',
    ).readAsStringSync();
    final sources = File(
      'server/src/main/java/com/uten/imp/features/operations/workbench/'
      'FulfillmentWorkbenchBadgeSources.java',
    ).readAsStringSync();
    final warehouseHub = File(
      'lib/features/warehouse/pages/warehouse_hub_page.dart',
    ).readAsStringSync();
    final stockDetail = File(
      'lib/features/warehouse/pages/stock_doc_detail_page.dart',
    ).readAsStringSync();
    final taskCenterBadges = File(
      'lib/features/warehouse/widgets/warehouse_task_center_badges.dart',
    ).readAsStringSync();

    expect(
      catalog,
      matches(
        RegExp(
          r'warehouseDrawCenter\(Module\.warehouse, facts\(\s*"productionDraw\.count"',
        ),
      ),
    );
    // 来源经 controller 代理调用: 原计数端点的权限判定一并复用。
    expect(sources, contains('new Source("productionDraw"'));
    expect(sources, contains('controller.warehouseCount()'));
    expect(warehouseHub, contains('invalidateWarehouseTaskCounts'));
    expect(
      RegExp(
        r'refreshBadges\(ref\)|bumpListRefresh\(',
      ).allMatches(stockDetail).length,
      greaterThanOrEqualTo(2),
      reason:
          'approve/issue/reverse flows must refresh the warehouse draw badge',
    );
    expect(warehouseHub, contains('WarehouseDrawTaskBadge'));
    expect(taskCenterBadges, contains('BadgeEntry.warehouseDrawCenter'));
  });
}
