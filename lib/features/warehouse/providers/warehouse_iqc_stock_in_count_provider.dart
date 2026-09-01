import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/warehouse_iqc_stock_in_repository.dart';

final warehouseIqcStockInPendingCountProvider = FutureProvider.autoDispose<int>(
  (ref) async {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    if (!superAdmin && !permissions.contains(Perm.warehouseIqcStockInView)) {
      return 0;
    }
    final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
    return ref.watch(warehouseIqcStockInRepositoryProvider).pendingCount();
  },
);
