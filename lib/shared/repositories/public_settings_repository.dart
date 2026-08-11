// 公共运行时设置仓库（仅需登录，非超管）。
//
// 拉前端需要的、非敏感的全局运行时配置（如会话空闲超时阈值）。
// 管理类设置走 SystemSettingRepository（authorization:manage + superAdmin）；本仓库对全体登录用户只读。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';

class PublicSettings {
  const PublicSettings({
    this.idleTimeoutMinutes = 30,
    this.auditReceiptRetentionMonths = 36,
  });
  final int idleTimeoutMinutes;
  final int auditReceiptRetentionMonths;

  factory PublicSettings.fromJson(Map<String, dynamic> j) => PublicSettings(
    idleTimeoutMinutes: (j['idleTimeoutMinutes'] as num?)?.toInt() ?? 30,
    auditReceiptRetentionMonths:
        (j['auditReceiptRetentionMonths'] as num?)?.toInt() ?? 36,
  );
}

abstract interface class PublicSettingsRepository {
  Future<PublicSettings> fetch();
}

class DioPublicSettingsRepository implements PublicSettingsRepository {
  DioPublicSettingsRepository(this.api);
  final ApiClient api;

  @override
  Future<PublicSettings> fetch() async {
    final json = await api.get(ApiEndpoints.publicSettings);
    return PublicSettings.fromJson(json);
  }
}

final publicSettingsRepositoryProvider = Provider<PublicSettingsRepository>(
  (ref) => DioPublicSettingsRepository(ref.watch(apiClientProvider)),
);
