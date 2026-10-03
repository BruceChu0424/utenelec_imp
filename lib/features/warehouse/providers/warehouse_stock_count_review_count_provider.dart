import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../../stock/counts/repositories/stock_count_request_repository.dart';

/// Scoped counts use the same server predicate as the approval queue. They are
/// only a page projection and never enter the global module badge a second time.
final warehouseScopedStockCountReviewCountProvider = FutureProvider.autoDispose
    .family<int, WarehouseTaskScope>((ref, scope) async {
      ref.watch(authenticatedScopeProvider);
      // A refreshed global review fact also refreshes the selected scope,
      // including approvals performed on another page or another device.
      ref.watch(badgeEntryTodoProvider(BadgeEntry.warehouseStockCountReview));
      final params = scope.queryParameters;
      final result = await ref
          .watch(stockCountRequestRepositoryProvider)
          .list(
            reviewRoute: 'WAREHOUSE',
            status: 'PENDING',
            warehouseScope: params['warehouseScope'],
            scopeWarehouseId: params['scopeWarehouseId'],
            size: 1,
          );
      return result.total;
    });

/// Top shortcut, workshop group and approval tab share this single projection.
final warehouseStockCountReviewCountProvider = Provider<int?>((ref) {
  final allowed =
      ref.watch(isSuperAdminProvider) ||
      ref
          .watch(currentPermissionsProvider)
          .contains(Perm.stockCountWarehouseReview);
  if (!allowed) return null;
  final scope = ref.watch(warehouseTaskScopeProvider);
  if (scope.isAll) {
    return ref.watch(
      badgeEntryTodoProvider(BadgeEntry.warehouseStockCountReview),
    );
  }
  return ref
      .watch(warehouseScopedStockCountReviewCountProvider(scope))
      .valueOrNull;
});
