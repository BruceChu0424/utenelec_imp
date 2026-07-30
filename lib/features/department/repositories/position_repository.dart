// 岗位仓库：部门下岗位的查询与增删改。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/position.dart';

abstract interface class PositionRepository {
  Future<List<Position>> listByDepartment(String deptId);
  Future<Position> create(String deptId, PositionSaveInput input);
  Future<Position> update(String id, PositionUpdateInput input);
  Future<void> delete(String id);
}

class DioPositionRepository implements PositionRepository {
  DioPositionRepository(this.api);
  final ApiClient api;

  @override
  Future<List<Position>> listByDepartment(String deptId) async {
    final list = await api.getList(ApiEndpoints.departmentPositions(deptId));
    return list.map(Position.fromJson).toList();
  }

  @override
  Future<Position> create(String deptId, PositionSaveInput input) async {
    final json = await api.post(
      ApiEndpoints.departmentPositions(deptId),
      body: input.toJson(),
    );
    return Position.fromJson(json);
  }

  @override
  Future<Position> update(String id, PositionUpdateInput input) async {
    final json = await api.put(ApiEndpoints.position(id), body: input.toJson());
    return Position.fromJson(json);
  }

  @override
  Future<void> delete(String id) => api.delete(ApiEndpoints.position(id));
}

final positionRepositoryProvider = Provider<PositionRepository>(
  (ref) => DioPositionRepository(ref.watch(apiClientProvider)),
);
