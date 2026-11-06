import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/paging/scoped_category_read.dart';
import '../../../../shared/warehouse/warehouse_task_scope.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';

/// This endpoint is a compact authoritative bin/period-status aggregate, not a
/// stock-row snapshot. Never use its aggregate result to skip a write/settlement check.
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
