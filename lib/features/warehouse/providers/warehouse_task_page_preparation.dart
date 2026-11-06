import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../models/warehouse_task_center_record.dart';
import '../repositories/warehouse_task_center_repository.dart';

/// Source choices use the same route grants. Only the selected query reads rows;
/// history remains a separately selected scope.
Map<String, String> warehouseTaskSources(
  WarehouseTaskDirection direction,
  Set<String> permissions,
  bool superAdmin,
) {
  bool can(String permission) => superAdmin || permissions.contains(permission);
  final stock = can(Perm.stockDocView);
  final workshop = can(Perm.workshopMaterialView);
  if (direction == WarehouseTaskDirection.outbound) {
    return {
      if (can(Perm.warehouseSalesOutboundView)) 'SALES': '销售出库',
      if (can(Perm.subcontractOutboundView) ||
          can(Perm.warehouseSubcontractOutboundHistoryView))
        'SUBCONTRACT': '委外出库',
      if (stock || workshop) 'DRAW': '生产领料',
      if (stock) 'OTHER': '其它出库',
      if (stock) 'FINISHED': '产成品出库',
    };
  }
  final arrival = can(Perm.warehouseInboundView);
  final quality = locationAllowedFor(
    permissions,
    superAdmin,
    RouteName.warehouseQualityResults,
  );
  return {
    if (arrival || quality || can(Perm.warehousePurchaseReceiptHistoryView))
      'PURCHASE': '采购入库',
    if (arrival || quality || can(Perm.warehouseSubcontractReceiptHistoryView))
      'SUBCONTRACT': '委外入库',
    if (stock) 'FINISHED': '产成品入库',
    if (stock) 'OTHER': '其它入库',
    if (stock || workshop) 'RETURN': '生产退料',
  };
}

/// The selected reader captures this exact warehouse/source/order/filter query;
/// the outer ScopedPagedRead owns completeness, cancellation and accepted rows.
class WarehouseTaskPageQuery {
  const WarehouseTaskPageQuery({
    required this.direction,
    this.source = 'ALL',
    this.view = WarehouseTaskView.active,
    this.status,
    this.keyword = '',
    this.billNo,
    this.dateFrom,
    this.dateTo,
    this.scope = const WarehouseTaskScope.all(),
    this.page = 1,
    this.size = 100,
    this.sort = 'businessDate',
    this.order = 'desc',
    this.columns = const {},
  });

  final WarehouseTaskDirection direction;
  final String source;
  final WarehouseTaskView view;
  final String? status, billNo, dateFrom, dateTo, sort, order;
  final String keyword;
  final WarehouseTaskScope scope;
  final int page, size;
  final Map<String, String?> columns;

  Future<WarehouseTaskCenterPageResult> _fetch(
    WarehouseTaskCenterGateway repository,
  ) => repository.list(
    direction: direction,
    source: source,
    view: view,
    status: status,
    keyword: keyword,
    billNo: billNo,
    dateFrom: dateFrom,
    dateTo: dateTo,
    warehouseScope: scope,
    page: page,
    size: size,
    sort: sort,
    order: order,
    columns: columns,
  );

  Future<WarehouseTaskCenterPageResult> read(
    WidgetRef ref,
    WarehouseTaskCenterGateway repository,
  ) => _fetch(repository);
}
