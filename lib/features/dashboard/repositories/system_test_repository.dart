import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';

/// 工作台「系统测试 · 清空业务数据」结果摘要（与后端 Result 一一对应）。
class BusinessDataResetResult {
  const BusinessDataResetResult({
    required this.clearedTableCount,
    required this.clearedRows,
    required this.preservedTableCount,
    required this.authorizationEpochAfter,
  });

  factory BusinessDataResetResult.fromJson(Map<String, dynamic> json) {
    return BusinessDataResetResult(
      clearedTableCount: (json['clearedTableCount'] as num).toInt(),
      clearedRows: (json['clearedRows'] as num).toInt(),
      preservedTableCount: (json['preservedTableCount'] as num).toInt(),
      authorizationEpochAfter: (json['authorizationEpochAfter'] as num).toInt(),
    );
  }

  /// 清空的业务表张数（后端白名单口径，当前 222）。
  final int clearedTableCount;

  /// 清空前业务表合计行数。
  final int clearedRows;

  /// 校验行数不变而保留的主档/治理表张数（当前 96）。
  final int preservedTableCount;

  /// 清空完成后的全局 authorization epoch（所有旧会话已被其踢出）。
  final int authorizationEpochAfter;
}

abstract interface class SystemTestRepository {
  /// 执行清空业务数据。成功后服务端已让所有人（含当前账号）下线，
  /// 调用方应立即本地登出并跳登录页。
  Future<BusinessDataResetResult> resetBusinessData();
}

class ApiSystemTestRepository implements SystemTestRepository {
  const ApiSystemTestRepository(this._api);

  final ApiClient _api;

  @override
  Future<BusinessDataResetResult> resetBusinessData() async {
    final json = await _api.post(
      ApiEndpoints.systemTestBusinessDataReset,
      body: const {'confirm': '清空业务数据'},
    );
    return BusinessDataResetResult.fromJson(json);
  }
}

final systemTestRepositoryProvider = Provider<SystemTestRepository>((ref) {
  return ApiSystemTestRepository(ref.watch(apiClientProvider));
});
