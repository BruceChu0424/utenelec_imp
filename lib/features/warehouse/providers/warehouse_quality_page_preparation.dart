import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/data_write_revision.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/page_preparation_budget_provider.dart';
import '../../../shared/paging/page_preparation_coordinator.dart';
import '../../../shared/paging/prepared_page_read.dart';
import '../../../shared/paging/scoped_category_read.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../models/warehouse_quality_result.dart';
import '../repositories/warehouse_quality_result_repository.dart';

class WarehouseQualityPageQuery {
  const WarehouseQualityPageQuery({
    this.page = 1,
    this.view = WarehouseTaskView.active,
    this.receiptType,
    this.workStatus,
    this.keyword,
    this.dateFrom,
    this.dateTo,
    this.sort,
    this.order,
    this.billNo,
    this.scopeWarehouseId,
  });
  final int page;
  final WarehouseTaskView view;
  final WarehouseIqcStockInReceiptType? receiptType;
  final WarehouseQualityWorkStatus? workStatus;
  final String? keyword,
      dateFrom,
      dateTo,
      sort,
      order,
      billNo,
      scopeWarehouseId;

  Object _key(WarehouseQualityResultGateway repository) => [
    repository,
    page,
    view,
    receiptType,
    workStatus,
    keyword?.trim() ?? '',
    dateFrom,
    dateTo,
    sort,
    order,
    billNo,
    scopeWarehouseId,
  ];

  Future<PagedResult<WarehouseQualityResultTask>> _fetch(
    WarehouseQualityResultGateway repository,
  ) => repository.list(
    page: page,
    size: 40,
    view: view,
    receiptType: receiptType,
    workStatus: workStatus,
    keyword: keyword,
    dateFrom: dateFrom,
    dateTo: dateTo,
    sort: sort,
    order: order,
    billNo: billNo,
    scopeWarehouseId: scopeWarehouseId,
  );

  Future<PagedResult<WarehouseQualityResultTask>> read(
    WidgetRef ref,
    WarehouseQualityResultGateway repository, {
    bool preferPrepared = false,
  }) {
    if (page != 1 || view != WarehouseTaskView.active) {
      return _fetch(repository);
    }
    return ref
        .read(_qualityPreparedProvider)
        .read(
          _key(repository),
          () => _fetch(repository),
          preferPrepared: preferPrepared,
        );
  }

  Future<void> prepare(
    WidgetRef ref,
    WarehouseQualityResultGateway repository,
  ) => ref
      .read(_qualityPreparedProvider)
      .prepare(_key(repository), () => _fetch(repository));
}

Future<Map<WarehouseQualityWorkStatus, int>> readWarehouseQualityCounts(
  WidgetRef ref,
  WarehouseQualityResultGateway repository, {
  WarehouseIqcStockInReceiptType? receiptType,
  String keyword = '',
  String? scopeWarehouseId,
  bool force = false,
}) => ref
    .read(scopedCategoryReadProvider)
    .read(
      query: [
        repository,
        'quality-status-counts',
        receiptType,
        keyword.trim(),
        scopeWarehouseId,
      ],
      fetch: () => repository.statusCounts(
        receiptType: receiptType,
        keyword: keyword.trim().isEmpty ? null : keyword.trim(),
        scopeWarehouseId: scopeWarehouseId,
      ),
      force: force,
    );

final _qualityPreparedProvider = Provider((ref) {
  ref.watch(exportContextEpochProvider);
  ref.watch(dataWriteRevisionProvider);
  final reads = PreparedPageRead<WarehouseQualityResultTask>();
  ref.onDispose(reads.dispose);
  return reads;
}, dependencies: [exportContextEpochProvider]);

final _qualityPreparationProvider = Provider.autoDispose((ref) {
  final coordinator = PagePreparationCoordinator(
    budget: ref.read(pagePreparationBudgetProvider),
  );
  final retire = pagePreparationRetirementCallback(ref, coordinator.retire);

  ref.listen(exportContextEpochProvider, (_, _) => retire());
  ref.listen(dataWriteRevisionProvider, (_, _) => retire());
  ref.onDispose(coordinator.dispose);
  return coordinator;
}, dependencies: [exportContextEpochProvider]);

void prepareWarehouseQualityPages(
  WidgetRef ref,
  BuildContext context, {
  String keyword = '',
  WarehouseIqcStockInReceiptType? receiptType,
  String? scopeWarehouseId,
  bool Function()? canPrepare,
}) {
  if (!locationAllowedFor(
    ref.watch(currentPermissionsProvider),
    ref.watch(isSuperAdminProvider),
    RouteName.warehouseQualityResults,
  )) {
    return;
  }
  final repository = ref.watch(warehouseQualityResultRepositoryProvider);
  final scope =
      scopeWarehouseId ?? ref.watch(warehouseTaskScopeProvider).warehouseId;
  ref
      .watch(_qualityPreparationProvider)
      .prepare(
        [repository, receiptType, keyword.trim(), scope],
        [
          () async {
            await readWarehouseQualityCounts(
              ref,
              repository,
              receiptType: receiptType,
              keyword: keyword,
              scopeWarehouseId: scope,
            );
          },
          for (final status in [
            null,
            ...WarehouseQualityWorkStatus.values.where(
              (value) => !value.isCompleted,
            ),
          ])
            () => WarehouseQualityPageQuery(
              receiptType: receiptType,
              workStatus: status,
              keyword: keyword,
              scopeWarehouseId: scope,
            ).prepare(ref, repository),
        ],
        canPrepare: () =>
            context.mounted &&
            (canPrepare?.call() ?? true) &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true),
      );
}
