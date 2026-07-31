import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/dashboard_overview.dart';
import '../repositories/dashboard_overview_repository.dart';

final dashboardOverviewRepositoryProvider =
    Provider<DashboardOverviewRepository>((ref) {
      return ApiDashboardOverviewRepository(ref.watch(apiClientProvider));
    });

final dashboardOverviewProvider = FutureProvider.autoDispose<DashboardOverview>(
  (ref) {
    return ref.watch(dashboardOverviewRepositoryProvider).load();
  },
);
