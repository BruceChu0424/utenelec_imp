// 系统设置仓库（authorization:manage + 后端 superAdmin）。
//
// list：拉全部设置（按 category 分组渲染表单，带服务端登记的取值范围）。
// updateBatch：一次保存全部修改 (唯一写入路径)；服务端要求再认证，统一密码框由网络层弹出 (ADR-110)。
// DioException 已在 ApiClient 层转 ApiException（如 CONFLICT 已被别人修改 / VALIDATION_FAILED 越界）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/system_setting_entry.dart';

abstract interface class SystemSettingRepository {
  Future<List<SystemSettingEntry>> list();
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
  );
}

class DioSystemSettingRepository implements SystemSettingRepository {
  DioSystemSettingRepository(this.api);
  final ApiClient api;

  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
  ) async {
    final rows = await api.putList(
      ApiEndpoints.adminSystemSettings,
      body: {
        'changes': [
          for (final change in changes)
            {
              'key': change.key,
              'value': change.value,
              'expectedValue': change.expectedValue,
            },
        ],
      },
    );
    final saved = rows.map(SystemSettingEntry.fromJson).toList();
    final byKey = {for (final entry in saved) entry.key: entry};
    if (saved.length != changes.length ||
        byKey.length != changes.length ||
        changes.any(
          (change) => byKey[change.key]?.value != change.value.trim(),
        )) {
      throw const FormatException('Incomplete system settings batch response');
    }
    return saved;
  }

  @override
  Future<List<SystemSettingEntry>> list() async {
    // 后端返回 JSON 数组（List<SystemSettingDto>），用 getList：
    // api.get 的 _asMap 会把数组当空 Map，导致 (json as List) 转型失败 → “加载失败”。
    final list = await api.getList(ApiEndpoints.adminSystemSettings);
    return list.map(SystemSettingEntry.fromJson).toList();
  }
}

final systemSettingRepositoryProvider = Provider<SystemSettingRepository>(
  (ref) => DioSystemSettingRepository(ref.watch(apiClientProvider)),
);
