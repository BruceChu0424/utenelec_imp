import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/data_write_revision.dart';
import '../../../../shared/paging/page_preparation_budget_provider.dart';
import '../../../../shared/paging/page_preparation_coordinator.dart';
import '../../../../shared/paging/scoped_category_read.dart';
import '../../../../shared/providers/export_context_epoch_provider.dart';
import '../../../../shared/warehouse/warehouse_task_scope.dart';
import '../../../stock/counts/repositories/stock_count_request_repository.dart';
import '../../../stock/counts/providers/stock_count_prepared_page_provider.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';

/// This endpoint is a compact authoritative bin/period-status aggregate, not a
/// stock-row snapshot. Never use its handoff to skip a write/settlement check.
Future<List<WmSetting>> readWorkshopBinTaskStatus(
  WidgetRef ref,
  WorkshopMaterialRepository repository,
  WarehouseTaskScope scope, {
  bool force = false,
}) => ref
    .read(scopedCategoryReadProvider)
    .read(
      query: [repository, 'workshop-bin-task-status', scope],
      fetch: () => repository.taskStatus(scope: scope.queryParameters),
      force: force,
    );

final _workshopMaterialPreparationProvider = Provider.autoDispose((ref) {
  final coordinator = PagePreparationCoordinator(
    budget: ref.read(pagePreparationBudgetProvider),
  );
  final retire = pagePreparationRetirementCallback(ref, coordinator.retire);

  ref.listen(exportContextEpochProvider, (_, _) => retire());
  ref.listen(dataWriteRevisionProvider, (_, _) => retire());
  ref.onDispose(coordinator.dispose);
  return coordinator;
}, dependencies: [exportContextEpochProvider]);

void prepareWorkshopMaterialPages(
  WidgetRef ref,
  BuildContext context, {
  required bool canReview,
  required bool canCycleCount,
  required WarehouseTaskScope scope,
  String keyword = '',
  bool Function()? canPrepare,
}) {
  final reviews = ref.watch(stockCountRequestRepositoryProvider);
  final materials = ref.watch(workshopMaterialRepositoryProvider);
  ref
      .watch(_workshopMaterialPreparationProvider)
      .prepare(
        [reviews, materials, canReview, canCycleCount, scope, keyword.trim()],
        [
          if (canReview)
            () => reviews.prepareReviewList(
              preparedRead: ref.read(stockCountPreparedPageProvider),
              reviewRoute: 'WAREHOUSE',
              scopeWarehouseId: scope.warehouseId,
              keyword: keyword,
            ),
          if (canCycleCount)
            () async {
              await readWorkshopBinTaskStatus(ref, materials, scope);
            },
        ],
        canPrepare: () =>
            context.mounted &&
            (canPrepare?.call() ?? true) &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true),
      );
}
