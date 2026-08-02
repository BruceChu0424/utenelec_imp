import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/dashboard_overview.dart';
import '../repositories/dashboard_overview_repository.dart';

final dashboardOverviewRepositoryProvider =
    Provider<DashboardOverviewRepository>((ref) {
      return ApiDashboardOverviewRepository(ref.watch(apiClientProvider));
    });

final dashboardOverviewDegradedRetryDelayProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 15),
);

final dashboardOverviewProvider = FutureProvider.autoDispose<DashboardOverview>(
  (ref) async {
    final repository = ref.watch(dashboardOverviewRepositoryProvider);
    final overview = await repository.load();
    final hasDegradedPartition = overview.todos.any(
      (todo) => todo.sourceType == 'FULFILLMENT_UNAVAILABLE',
    );
    if (hasDegradedPartition) {
      // A partial dashboard failure must heal without making office users
      // refresh the whole SPA. Only the degraded payload schedules this bounded
      // poll; normal dashboards generate no background traffic.
      final timer = Timer(
        ref.read(dashboardOverviewDegradedRetryDelayProvider),
        ref.invalidateSelf,
      );
      ref.onDispose(timer.cancel);
    }
    return overview;
  },
);
