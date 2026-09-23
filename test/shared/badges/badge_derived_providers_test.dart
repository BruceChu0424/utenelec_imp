// 页内分段计数 provider 全部从徽章汇总派生(ADR-108): 不再各自请求/轮询原计数端点。
// 这里锁「事实数键 → 分段字段」的映射, 以及「来源无权/未到 = null(不渲染), 不伪装成 0」。
// 取代原各 provider 的请求/身份隔离用例: 身份隔离与迟到响应作废已由
// badge_summary_provider_test 在唯一的数据源上锁定。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/expense/providers/expense_counts_provider.dart';
import 'package:uten_imp/features/production/providers/production_workshop_task_count_provider.dart';
import 'package:uten_imp/features/visitor_approval/providers/visitor_pending_count_provider.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/providers/warehouse_quality_result_count_provider.dart';
import 'package:uten_imp/features/warehouse/providers/warehouse_sales_outbound_count_provider.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_subcontract_outbound_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../helpers/badge_summary_fixture.dart';

ProviderContainer _container(Map<String, int> facts) {
  final container = ProviderContainer(
    overrides: [fixedBadgeSummaryOverride(badgeSummaryFixture(facts: facts))],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('报销五档取自汇总事实数', () {
    final container = _container({
      BadgeFact.expenseDraft: 2,
      BadgeFact.expenseRejected: 1,
      BadgeFact.expensePendingApproval: 4,
      BadgeFact.expensePendingPayment: 3,
      BadgeFact.expenseProcessing: 5,
    });
    expect(
      container.read(expenseCountsProvider),
      const ExpenseCounts(
        draftCount: 2,
        rejectedCount: 1,
        pendingApprovalCount: 4,
        pendingPaymentCount: 3,
        processingCount: 5,
      ),
    );
  });

  test('车间任务分段: 总数 / 等待物料 / 生产中', () {
    final container = _container({
      BadgeFact.workshopTotal: 9,
      BadgeFact.workshopPreparing: 2,
      BadgeFact.workshopInProgress: 6,
    });
    final breakdown = container.read(productionWorkshopTaskCountProvider);
    expect(breakdown.count, 9);
    expect(breakdown.preparing, 2);
    expect(breakdown.inProgress, 6);
  });

  test('委外待出仓: 无该来源时为 null(分段不渲染数字); 有则红黄两数各取其键', () {
    expect(
      _container({}).read(warehouseSubcontractOutboundCountProvider),
      isNull,
    );

    final container = _container({
      BadgeFact.subcontractOutbound: 3,
      BadgeFact.subcontractOutboundWaitingComponent: 1,
    });
    expect(container.read(warehouseSubcontractOutboundCountProvider), 3);
    expect(
      container.read(warehouseSubcontractOutboundWaitingComponentCountProvider),
      1,
    );
  });

  test('销售出库分组: 无来源为 null; 有来源按三档取数', () {
    expect(_container({}).read(warehouseSalesOutboundCountsProvider), isNull);

    final counts = _container({
      BadgeFact.warehouseSalesOutboundPendingPick: 4,
      BadgeFact.warehouseSalesOutboundLegacyPending: 1,
      BadgeFact.warehouseSalesOutboundShipped: 7,
    }).read(warehouseSalesOutboundCountsProvider)!;
    expect(counts.pendingPick, 4);
    expect(counts.legacyPending, 1);
    expect(counts.shipped, 7);
  });

  test('品质结果按来源大类分开取红黄两数', () {
    final purchase = WarehouseIqcStockInReceiptType.values.first;
    final counts = _container({
      BadgeFact.qualityResultActionable(purchase.apiValue): 2,
      BadgeFact.qualityResultInProgress(purchase.apiValue): 5,
    }).read(warehouseQualityResultTypeCountsProvider);
    expect(counts.actionable[purchase], 2);
    expect(counts.inProgress[purchase], 5);
  });

  test('我的访客四档取自汇总', () {
    final counts = _container({
      BadgeFact.visitorHostPending: 1,
      BadgeFact.visitorHostOngoing: 3,
      BadgeFact.visitorHostHrReviewing: 2,
      BadgeFact.visitorHostAwaitingVisit: 1,
    }).read(visitorHostCountsProvider);
    expect(counts.pending, 1);
    expect(counts.ongoing, 3);
    expect(counts.hrReviewing + counts.awaitingVisit, counts.ongoing);
  });
}
