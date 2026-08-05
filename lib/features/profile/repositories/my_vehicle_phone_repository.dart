// 员工自助：本人车辆 / 备用手机号（ADR-021；/api/profile/me/**，仅本人）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../employee/models/employee_api_models.dart';

class MyVehiclePhoneRepository {
  const MyVehiclePhoneRepository(this._api);

  final ApiClient _api;

  Future<List<EmployeeVehicleView>> vehicles() async {
    final json = await _api.getList(ApiEndpoints.myVehicles);
    return json.map(EmployeeVehicleView.fromJson).toList();
  }

  Future<List<EmployeeVehicleView>> replaceVehicles(
    List<Map<String, dynamic>> inputs,
  ) async {
    final json = await _api.putList(ApiEndpoints.myVehicles, body: inputs);
    return json.map(EmployeeVehicleView.fromJson).toList();
  }

  Future<List<EmployeePhoneView>> phones() async {
    final json = await _api.getList(ApiEndpoints.myPhones);
    return json.map(EmployeePhoneView.fromJson).toList();
  }

  Future<List<EmployeePhoneView>> replacePhones(
    List<Map<String, dynamic>> inputs,
  ) async {
    final json = await _api.putList(ApiEndpoints.myPhones, body: inputs);
    return json.map(EmployeePhoneView.fromJson).toList();
  }
}

final myVehiclePhoneRepositoryProvider = Provider<MyVehiclePhoneRepository>(
  (ref) => MyVehiclePhoneRepository(ref.watch(apiClientProvider)),
);
