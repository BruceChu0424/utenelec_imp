// 仓库任务计数即时刷新契约：任一写操作成功后必须调用统一失效入口
// invalidateWarehouseTaskCounts，保证分段徽章 / hub 卡 / 工作台角标立即联动，
// 不等 60s 轮询或手动刷新。（源码契约测试风格与 production_draw_badge_contract 一致。）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('warehouse task counts refresh immediately after every mutation', () {
    String source(String path) => File(path).readAsStringSync();
    int count(String path, String needle) =>
        source(path).split(needle).length - 1;

    // 统一入口必须失效全部计数源（含分来源预计到货与品质结果父分类分段）。
    final helper = source(
      'lib/features/warehouse/providers/warehouse_count_refresh.dart',
    );
    for (final provider in [
      'warehouseSalesOutboundPendingCountProvider',
      'warehouseSubcontractOutboundCountProvider',
      'warehouseInboundExpectationCountProvider',
      'warehouseInboundExpectationTypeCountsProvider',
      'warehouseArrivalExceptionCountProvider',
      'warehouseProductionDrawPendingCountProvider',
      'warehouseProductionFinishedInboundPendingCountProvider',
      'warehouseQualityResultPendingCountProvider',
      'warehouseQualityResultTypeCountsProvider',
    ]) {
      expect(
        helper,
        contains('ref.invalidate($provider)'),
        reason: '统一失效入口漏了 $provider',
      );
    }

    // 2026-09-01 口径：所有草稿不计入数量徽章——草稿计数 provider 已删除，
    // 任何徽章聚合/刷新链路不得再引用。
    expect(
      helper,
      isNot(contains('stockDocDraftCountProvider')),
      reason: '草稿不计入徽章，刷新入口不得引用草稿计数',
    );

    // 写操作成功点必须接线（数量与各页成功链路数一致）。
    final sites = <String, int>{
      // 到货登记/继续送检（_announceRegistration 是两条链路共同出口）。
      'lib/features/warehouse/widgets/warehouse_inbound_expectations_view.dart':
          1,
      // 到货异常：单条一键入库 + 批量按批准量处理。
      'lib/features/warehouse/widgets/warehouse_arrival_exceptions_view.dart':
          2,
      // 产成品：批量点收 + 登记页返回变更。
      'lib/features/warehouse/widgets/production_finished_inbound_tasks_view.dart':
          2,
      'lib/features/warehouse/pages/warehouse_arrival_receipt_page.dart': 1,
      'lib/features/warehouse/pages/production_finished_arrival_registration_page.dart':
          1,
      // 销售出库详情：拣货/交接状态流转。
      'lib/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart':
          1,
      // 委外出仓：保存草稿 / 审核出仓 / 关闭计划。
      'lib/features/warehouse/pages/warehouse_subcontract_outbound_edit_page.dart':
          3,
      // 三张任务中心页返回即刷新 + hub 返回即刷新。
      'lib/features/warehouse/pages/warehouse_outbound_task_center_page.dart':
          1,
      'lib/features/warehouse/pages/warehouse_inbound_task_center_page.dart': 1,
      'lib/features/warehouse/pages/warehouse_draw_task_center_page.dart': 1,
      'lib/features/warehouse/pages/warehouse_hub_page.dart': 1,
    };
    for (final entry in sites.entries) {
      expect(
        count(entry.key, 'invalidateWarehouseTaskCounts('),
        greaterThanOrEqualTo(entry.value),
        reason: '${entry.key} 的写操作成功点漏接统一失效入口',
      );
    }

    // 工作台「返回即刷新」也要覆盖分来源预计到货计数。
    expect(
      source('lib/features/dashboard/providers/workbench_refresh.dart'),
      contains(
        'ref.invalidate(warehouseInboundExpectationTypeCountsProvider);',
      ),
    );
  });
}
