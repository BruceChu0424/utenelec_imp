// 仓库任务计数（任务中心分段徽章 / hub 卡 / 工作台仓库卡角标）的统一失效入口。
//
// 背景：这些计数是 `FutureProvider.autoDispose`（60s 轮询），若操作完成后不主动
// 失效，徽章要等下一轮轮询或手动刷新才变化。任何仓库写操作（到货登记/送检、
// 异常一键入库、产成品点收、销售出库交接、委外出仓、领料出入库等）成功后都应
// 调用 [invalidateWarehouseTaskCounts]，让正在监听的徽章立即重拉。
//
// 无权限的 provider 内部自卫（返回 0、不发请求），统一失效不会产生多余请求；
// 未被监听的 autoDispose 计数失效即销毁，重新可见时自然取新值。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/production_fqc_pending_count_provider.dart'
    show productionFqcPendingCountProvider;
import 'procurement_inbound_count_providers.dart';
import 'production_draw_count_provider.dart';
import 'production_finished_inbound_task_count_provider.dart';
import 'warehouse_quality_result_count_provider.dart';
import 'warehouse_sales_outbound_count_provider.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart'
    show warehouseSubcontractOutboundCountProvider;

/// 失效仓库任务中心的全部计数源（出库/入库/领料/品质结果 + 分来源预计到货）。
/// 在写操作成功返回后调用；各 provider 按权限自卫，调用方无需按域挑拣。
void invalidateWarehouseTaskCounts(WidgetRef ref) {
  // 出库：销售待出库 + 委外待出仓。
  ref.invalidate(warehouseSalesOutboundPendingCountProvider);
  ref.invalidate(warehouseSubcontractOutboundCountProvider);
  // 入库：预计到货（总量 + 采购/委外分来源）+ 到货异常 + 产成品待点收。
  ref.invalidate(warehouseInboundExpectationCountProvider);
  ref.invalidate(warehouseInboundExpectationTypeCountsProvider);
  ref.invalidate(warehouseArrivalExceptionCountProvider);
  ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
  // 领料：履约待领（DRAW open_qty 投影）。
  ref.invalidate(warehouseProductionDrawPendingCountProvider);
  // 品质部检查结果（仓库 hub 第四张任务卡）：未完结总数 + 父分类（来源）分段。
  ref.invalidate(warehouseQualityResultPendingCountProvider);
  ref.invalidate(warehouseQualityResultTypeCountsProvider);
}

/// 品质域联动失效：IQC 放行/退回与 FQC 决定会改变仓库侧待入库/待点收计数。
/// 供品质处置页在决定成功后与品质自身计数一并失效。
void invalidateQualityLinkedWarehouseCounts(WidgetRef ref) {
  ref.invalidate(productionFqcPendingCountProvider);
  invalidateWarehouseTaskCounts(ref);
}
