import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../repositories/warehouse_quality_result_repository.dart';

/// 品质部检查结果合并页角标（统一口径 = 未完结任务数：等待检查结果 + 待入库 +
/// 需退回；与页内父分类/状态分段徽章、hub 卡、工作台仓库卡同源同口径）。
final warehouseQualityResultPendingCountProvider =
    FutureProvider.autoDispose<int>((ref) async {
      final permissions = ref.watch(currentPermissionsProvider);
      final superAdmin = ref.watch(isSuperAdminProvider);
      final canView =
          superAdmin ||
          permissions.contains(Perm.warehouseIqcStockInView) ||
          permissions.contains(Perm.warehouseIqcReturnView);
      if (!canView) return 0;
      final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref
          .watch(warehouseQualityResultRepositoryProvider)
          .pendingCount();
    });

/// 父分类（来源类型）分段计数：各来源未完结任务数（页内大类徽章用；
/// 「父分类徽章 = 其子类待办之和」，此处即该来源全部未完结状态之和）。
final warehouseQualityResultTypeCountsProvider =
    FutureProvider.autoDispose<Map<WarehouseIqcStockInReceiptType, int>>(
      (ref) async {
        final permissions = ref.watch(currentPermissionsProvider);
        final superAdmin = ref.watch(isSuperAdminProvider);
        final canView =
            superAdmin ||
            permissions.contains(Perm.warehouseIqcStockInView) ||
            permissions.contains(Perm.warehouseIqcReturnView);
        if (!canView) {
          return const <WarehouseIqcStockInReceiptType, int>{};
        }
        final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
        ref.onDispose(timer.cancel);
        return ref
            .watch(warehouseQualityResultRepositoryProvider)
            .typeCounts();
      },
    );
