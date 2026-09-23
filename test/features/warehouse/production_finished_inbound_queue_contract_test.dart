import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test(
    'finished inbound queue is recoverable and refreshed after stock actions',
    () {
      // ADR-108: 待点收数随徽章汇总带回(入库任务中心入口), 口径登记在服务端目录。
      final catalog = File(
        'server/src/main/java/com/uten/imp/features/workbench/badge/'
        'WorkbenchBadgeCatalog.java',
      ).readAsStringSync();
      final sources = File(
        'server/src/main/java/com/uten/imp/features/warehouse/'
        'WarehouseWorkbenchBadgeSources.java',
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

      expect(catalog, contains('"finishedInbound.count"'));
      expect(sources, contains('new Source("finishedInbound"'));
      // 工作台模块卡按容器取服务端算好的和, 不在前端逐个求和。
      expect(moduleBadge, contains('BadgeModule.warehouse'));
      // 2026-09-01 重组：hub 卡角标由 WarehouseInboundTaskBadge（入库任务中心）
      // 渲染；独立任务页路由保留(深链)，入口改为 /warehouse/tasks/inbound。
      expect(warehouseHub, contains('WarehouseInboundTaskBadge'));
      expect(
        File(
          'lib/features/warehouse/widgets/warehouse_task_center_badges.dart',
        ).readAsStringSync(),
        contains('BadgeEntry.warehouseInboundCenter'),
      );
      expect(
        RegExp(
          r'refreshBadges\(ref\)|bumpListRefresh\(',
        ).allMatches(stockDetail).length,
        greaterThanOrEqualTo(3),
        reason:
            'approve/issue/finished-in confirm and reverse paths must refresh '
            'the authoritative queue badge',
      );
    },
  );

  test('arrival registration deep link keeps stock view boundary', () {
    const reportId = '20000000-0000-0000-0000-000000000001';
    final location = RoutePath.warehouseProductionFinishedArrivalRegistration(
      reportId,
      returnTo: RouteName.warehouseProductionFinishedInboundTasks,
    );
    final uri = Uri.parse(location);

    expect(
      uri.path,
      '${RouteName.warehouseProductionFinishedArrivalRegistrationBase}/'
      '$reportId',
    );
    expect(
      uri.queryParameters['returnTo'],
      RouteName.warehouseProductionFinishedInboundTasks,
    );
    expect(requiredAnyPermFor(uri.path), const [Perm.stockDocView]);
    expect(
      requiredAnyPermFor(
        '${RouteName.warehouseProductionFinishedArrivalRegistrationBase}'
        '-shadow/$reportId',
      ),
      isNot(contains(Perm.stockDocView)),
    );
  });
}
