import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/data_write_revision.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/paging/page_preparation_budget_provider.dart';
import '../../../shared/paging/page_preparation_coordinator.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../repositories/production_execution_workbench_repository.dart';
import '../repositories/production_repository.dart';
import 'production_prepared_page_provider.dart';
export 'production_prepared_page_provider.dart';

final _productionPagePreparationProvider = Provider.autoDispose((ref) {
  final coordinator = PagePreparationCoordinator(
    budget: ref.read(pagePreparationBudgetProvider),
  );
  final retire = pagePreparationRetirementCallback(ref, coordinator.retire);

  ref.listen(exportContextEpochProvider, (_, _) => retire());
  ref.listen(dataWriteRevisionProvider, (_, _) => retire());
  ref.onDispose(coordinator.dispose);
  return coordinator;
}, dependencies: [exportContextEpochProvider]);

bool _active(BuildContext context) =>
    context.mounted &&
    TickerMode.valuesOf(context).enabled &&
    (ModalRoute.of(context)?.isCurrent ?? true);

void prepareProductionBoardPages(
  WidgetRef ref,
  BuildContext context, {
  String keyword = '',
  int refreshRevision = 0,
  bool Function()? canPrepare,
}) {
  final permissions = ref.watch(currentPermissionsProvider);
  final plan = ref.watch(productionPlanRepositoryProvider);
  final execution = ref.watch(productionExecutionWorkbenchRepositoryProvider);
  ref
      .watch(_productionPagePreparationProvider)
      .prepare(
        ['board', plan, execution, keyword.trim(), refreshRevision],
        [
          if (permissions.contains(Perm.productionPlanView))
            () => plan.prepareSchedulePending(
              keyword: keyword,
              preparedRead: ref.read(productionSchedulePreparedPageProvider),
            ),
          if (permissions.contains(Perm.productionExecutionOverview))
            () => execution.prepareGroups(
              keyword: keyword,
              preparedRead: ref.read(productionGroupsPreparedPageProvider),
            ),
        ],
        canPrepare: () => _active(context) && (canPrepare?.call() ?? true),
      );
}

void prepareProductionWorkshopPages(
  WidgetRef ref,
  BuildContext context, {
  String keyword = '',
  String? workshopDepartmentId,
  String? activeStatus,
  bool Function()? canPrepare,
}) {
  if (!ref
      .watch(currentPermissionsProvider)
      .contains(Perm.productionExecutionView)) {
    return;
  }
  final repository = ref.watch(productionExecutionWorkbenchRepositoryProvider);
  ref
      .watch(_productionPagePreparationProvider)
      .prepare(
        [
          'workshop',
          repository,
          keyword.trim(),
          workshopDepartmentId,
          activeStatus,
        ],
        [
          for (final status in const [
            'PREPARING',
            'IN_PROGRESS',
            'REPORT_INSPECTION',
          ])
            // The visible queue owns its authoritative refresh, including a
            // return after a write. Preparing it first would issue two reads.
            if (status != activeStatus)
              () => repository.prepareWorkshopTasks(
                status: status,
                keyword: keyword,
                workshopDepartmentId: workshopDepartmentId,
                preparedRead: ref.read(productionWorkshopPreparedPageProvider),
              ),
        ],
        canPrepare: () => _active(context) && (canPrepare?.call() ?? true),
      );
}
