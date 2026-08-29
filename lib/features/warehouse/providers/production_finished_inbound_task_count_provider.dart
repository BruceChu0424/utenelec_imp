import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/production_finished_inbound_task_repository.dart';

final warehouseProductionFinishedInboundPendingCountProvider =
    FutureProvider.autoDispose<int>((ref) async {
      final permissions = ref.watch(currentPermissionsProvider);
      if (!permissions.contains(Perm.stockDocView)) return 0;
      return ref
          .watch(productionFinishedInboundTaskRepositoryProvider)
          .pendingCount();
    });
