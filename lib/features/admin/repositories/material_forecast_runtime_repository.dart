import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../models/material_forecast_runtime_status.dart';

abstract interface class MaterialForecastRuntimeRepository {
  Future<MaterialForecastRuntimeStatus> status();
}

class ApiMaterialForecastRuntimeRepository
    implements MaterialForecastRuntimeRepository {
  ApiMaterialForecastRuntimeRepository(this.api);
  final ApiClient api;
  @override
  Future<MaterialForecastRuntimeStatus> status() async =>
      MaterialForecastRuntimeStatus(
        await api.get('/admin/system-settings/material-forecast-status'),
      );
}

final materialForecastRuntimeRepositoryProvider =
    Provider<MaterialForecastRuntimeRepository>(
      (ref) =>
          ApiMaterialForecastRuntimeRepository(ref.watch(apiClientProvider)),
    );
final materialForecastRuntimeClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);
