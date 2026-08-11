import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/dashboard_overview.dart';

abstract interface class DashboardOverviewRepository {
  Future<DashboardOverview> load();
}

class ApiDashboardOverviewRepository implements DashboardOverviewRepository {
  const ApiDashboardOverviewRepository(this._api);

  final ApiClient _api;

  @override
  Future<DashboardOverview> load() async {
    final json = await _api.get(ApiEndpoints.dashboardOverview);
    return DashboardOverview.fromJson(json);
  }
}
