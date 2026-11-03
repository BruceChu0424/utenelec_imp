import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/data_write_revision.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/date_range_defaults.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/paging/page_preparation_coordinator.dart';
import '../../../shared/paging/page_preparation_budget_provider.dart';
import '../../../shared/paging/prepared_page_read.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../models/warehouse_task_center_record.dart';
import '../repositories/warehouse_task_center_repository.dart';

/// The direction pages and their parent prepare only sources visible through
/// the same route grants. History remains a separately selected query.
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

/// Every parameter belongs to the handoff key, including the repository
/// instance, exact warehouse scope, row ordering, and search-column values.
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
    this.size = 20,
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

  Object _key(WarehouseTaskCenterGateway repository) => [
    repository,
    direction,
    source,
    view,
    status,
    keyword.trim(),
    billNo,
    dateFrom,
    dateTo,
    scope,
    page,
    size,
    sort,
    order,
    columns,
  ];

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
    WarehouseTaskCenterGateway repository, {
    bool preferPrepared = false,
  }) async {
    if (page != 1 || view != WarehouseTaskView.active) {
      return _fetch(repository);
    }
    final result = await ref
        .read(_warehouseTaskPreparedReadsProvider)
        .read(
          _key(repository),
          () => _fetch(repository),
          preferPrepared: preferPrepared,
        );
    return result as WarehouseTaskCenterPageResult;
  }

  Future<void> _prepare(WidgetRef ref, WarehouseTaskCenterGateway repository) =>
      ref
          .read(_warehouseTaskPreparedReadsProvider)
          .prepare(_key(repository), () => _fetch(repository));
}

final _warehouseTaskPreparedReadsProvider = Provider((ref) {
  ref.watch(exportContextEpochProvider);
  ref.watch(dataWriteRevisionProvider);
  final reads = PreparedPageRead<WarehouseTaskCenterRecord>();
  ref.onDispose(reads.dispose);
  return reads;
}, dependencies: [exportContextEpochProvider]);

final _warehouseTaskPreparationProvider = Provider.autoDispose((ref) {
  final coordinator = PagePreparationCoordinator(
    budget: ref.read(pagePreparationBudgetProvider),
  );
  final retire = pagePreparationRetirementCallback(ref, coordinator.retire);

  ref.listen(exportContextEpochProvider, (_, _) => retire());
  ref.listen(dataWriteRevisionProvider, (_, _) => retire());
  ref.onDispose(coordinator.dispose);
  return coordinator;
}, dependencies: [exportContextEpochProvider]);

void prepareWarehouseTaskPages(
  WidgetRef ref,
  BuildContext context, {
  required WarehouseTaskDirection direction,
  required Iterable<String> sources,
  required WarehouseTaskScope scope,
  String keyword = '',
  int refreshTick = 0,
  bool Function()? canPrepare,
}) {
  final repository = ref.watch(warehouseTaskCenterRepositoryProvider);
  final permissions = ref.watch(currentPermissionsProvider);
  final superAdmin = ref.watch(isSuperAdminProvider);
  bool can(String permission) => superAdmin || permissions.contains(permission);
  final canReadInbound =
      can(Perm.warehouseInboundView) ||
      locationAllowedFor(
        permissions,
        superAdmin,
        RouteName.warehouseQualityResults,
      );
  // A history-only grant exposes its source selector, but does not authorize
  // speculative active-task reads for that source.
  final visibleSources = sources.toList(growable: false);
  final allowedSources = visibleSources
      .where((source) {
        if (direction == WarehouseTaskDirection.outbound &&
            source == 'SUBCONTRACT') {
          return can(Perm.subcontractOutboundView);
        }
        if (direction == WarehouseTaskDirection.inbound &&
            const {'PURCHASE', 'SUBCONTRACT'}.contains(source)) {
          return canReadInbound;
        }
        return true;
      })
      .toList(growable: false);
  if (allowedSources.isEmpty) return;
  final canPrepareAll = allowedSources.length == visibleSources.length;
  final dates = recentMonthDateRange();
  final dateFrom = ChinaDateTime.formatDate(dates.start);
  final dateTo = ChinaDateTime.formatDate(dates.end);
  ref
      .watch(_warehouseTaskPreparationProvider)
      .prepare(
        [
          repository,
          direction,
          allowedSources,
          canPrepareAll,
          scope,
          keyword.trim(),
          dateFrom,
          dateTo,
          refreshTick,
        ],
        [
          for (final source in [...allowedSources, if (canPrepareAll) 'ALL'])
            () => WarehouseTaskPageQuery(
              direction: direction,
              source: source,
              keyword: keyword,
              dateFrom: dateFrom,
              dateTo: dateTo,
              scope: scope,
            )._prepare(ref, repository),
        ],
        canPrepare: () =>
            context.mounted &&
            (canPrepare?.call() ?? true) &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true),
      );
}
