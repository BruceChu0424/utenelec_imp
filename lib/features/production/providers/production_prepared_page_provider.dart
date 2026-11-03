import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/data_write_revision.dart';
import '../../../shared/paging/prepared_page_read.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../models/production_execution_workbench.dart';
import '../repositories/production_repository.dart' show SchedulePendingRow;

// Bounded container-owned data needs no idle timer. Adoption still expires
// after 15 seconds; every reader/write revision disposes its entire lease.
PreparedPageRead<T> _lease<T>(Ref ref, {int maximumRows = 50}) {
  ref.watch(exportContextEpochProvider);
  ref.watch(dataWriteRevisionProvider);
  final reads = PreparedPageRead<T>(maximumRowsPerPage: maximumRows);
  ref.onDispose(reads.dispose);
  return reads;
}

final productionSchedulePreparedPageProvider = Provider(
  (ref) => _lease<SchedulePendingRow>(ref, maximumRows: 100),
  dependencies: [exportContextEpochProvider],
);

final productionGroupsPreparedPageProvider = Provider(
  (ref) => _lease<ProductionExecutionWorkbenchGroup>(ref),
  dependencies: [exportContextEpochProvider],
);

final productionWorkshopPreparedPageProvider = Provider(
  (ref) => _lease<ProductionExecutionWorkbenchSegment>(ref),
  dependencies: [exportContextEpochProvider],
);
