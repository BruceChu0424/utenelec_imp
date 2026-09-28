// AI 服务设置(ADR-133)仓储: /api/admin/ai/*。
//
// 服务端 Controller 类级别要求 authorization:manage + superAdmin。
// 增删改、设默认、启停、用已存密钥测试/取模型都要求再认证(403 REAUTH_REQUIRED →
// 网络层弹统一密码框后自动重发一次), 本仓储与页面都不自己问密码。
// 用本次新填密钥做连接测试/取模型走免再认证端点(不读已存密钥、不改配置)。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/ai_provider_models.dart';

abstract interface class AiProviderRepository {
  /// 已配置的全部服务(默认的排最前由服务端决定)。
  Future<List<AiProviderConfig>> list();

  /// 预设与服务器开关(是否允许境外、是否允许外呼)。
  Future<AiPresetCatalog> presets();

  /// 近 [days] 天的调用统计。
  Future<AiUsageSummary> usage({int days = 30});

  Future<void> create(AiProviderForm form);

  /// [version] 为打开编辑时读到的版本号, 期间被别人改过服务端回 409。
  Future<void> update(String id, AiProviderForm form, {required int version});

  Future<void> delete(String id);

  /// [version] 为页面读到的版本号(服务端 `{version}`), 期间被别人改过服务端回 409。
  Future<void> setDefault(String id, {int? version});

  /// 请求体 `{enabled, version}`; [version] 同 [setDefault]。
  Future<void> setEnabled(String id, {required bool enabled, int? version});

  /// 用表单里本次新填的密钥测试(未保存的配置)。
  Future<AiConnectionTestResult> testForm(AiProviderForm form);

  /// 用已保存的配置和密钥测试(结果记到这条配置上)。
  ///
  /// 从编辑面板发起时传 [current]: 只把其中的协议/接口地址/模型带给服务端核对
  /// (与已保存的不一致即 422), 保证已存密钥只发往保存时的地址; 绝不带密钥。
  Future<AiConnectionTestResult> testStored(
    String id, {
    AiProviderForm? current,
  });

  /// 用表单里本次新填的密钥获取模型列表。
  Future<AiModelList> modelsForForm(AiProviderForm form);

  /// 用已保存的配置和密钥获取模型列表; [current] 同 [testStored], 但不核对模型名。
  Future<AiModelList> modelsStored(String id, {AiProviderForm? current});
}

final aiProviderRepositoryProvider = Provider<AiProviderRepository>(
  (ref) => DioAiProviderRepository(ref.watch(apiClientProvider)),
);

class DioAiProviderRepository implements AiProviderRepository {
  DioAiProviderRepository(this.api);

  final ApiClient api;

  /// 连接测试要依次请求服务商好几次, 慢的服务商单次就要几十秒。
  static const probeTimeout = Duration(seconds: 150);

  @override
  Future<List<AiProviderConfig>> list() async {
    final rows = await api.getList(ApiEndpoints.adminAiProviders);
    return [
      for (final row in rows) AiProviderConfig.fromJson(row),
    ].where((provider) => provider.id.isNotEmpty).toList();
  }

  @override
  Future<AiPresetCatalog> presets() async =>
      AiPresetCatalog.fromJson(await api.get(ApiEndpoints.adminAiPresets));

  @override
  Future<AiUsageSummary> usage({int days = 30}) async =>
      AiUsageSummary.fromJson(
        await api.get(ApiEndpoints.adminAiUsage, query: {'days': days}),
      );

  @override
  Future<void> create(AiProviderForm form) async {
    await api.post(ApiEndpoints.adminAiProviders, body: form.toJson());
  }

  @override
  Future<void> update(
    String id,
    AiProviderForm form, {
    required int version,
  }) async {
    await api.put(
      ApiEndpoints.adminAiProvider(_checkedId(id)),
      body: form.toJson(version: version),
    );
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.adminAiProvider(_checkedId(id)));
  }

  @override
  Future<void> setDefault(String id, {int? version}) async {
    await api.post(
      ApiEndpoints.adminAiProviderDefault(_checkedId(id)),
      body: version == null ? null : {'version': version},
    );
  }

  @override
  Future<void> setEnabled(
    String id, {
    required bool enabled,
    int? version,
  }) async {
    await api.post(
      ApiEndpoints.adminAiProviderEnabled(_checkedId(id)),
      body: {'enabled': enabled, 'version': ?version},
    );
  }

  @override
  Future<AiConnectionTestResult> testForm(AiProviderForm form) async =>
      AiConnectionTestResult.fromJson(
        await api.postLongRunning(
          ApiEndpoints.adminAiProvidersTest,
          body: form.toProbeJson(),
          receiveTimeout: probeTimeout,
        ),
      );

  @override
  Future<AiConnectionTestResult> testStored(
    String id, {
    AiProviderForm? current,
  }) async => AiConnectionTestResult.fromJson(
    await api.postLongRunning(
      ApiEndpoints.adminAiProviderTest(_checkedId(id)),
      body: _storedCheck(current, withModel: true),
      receiveTimeout: probeTimeout,
    ),
  );

  @override
  Future<AiModelList> modelsForForm(AiProviderForm form) async =>
      AiModelList.fromJson(
        await api.postLongRunning(
          ApiEndpoints.adminAiProvidersModels,
          body: form.toProbeJson(),
          receiveTimeout: probeTimeout,
        ),
      );

  @override
  Future<AiModelList> modelsStored(
    String id, {
    AiProviderForm? current,
  }) async => AiModelList.fromJson(
    await api.postLongRunning(
      ApiEndpoints.adminAiProviderModels(_checkedId(id)),
      body: _storedCheck(current, withModel: false),
      receiveTimeout: probeTimeout,
    ),
  );

  /// 服务端 `StoredProbeRequest{protocol, baseUrl, model}`: 只用于核对, 永不带密钥。
  static Map<String, dynamic>? _storedCheck(
    AiProviderForm? current, {
    required bool withModel,
  }) {
    if (current == null) return null;
    final model = current.model.trim();
    return {
      'protocol': current.protocol.code,
      'baseUrl': current.baseUrl.trim(),
      if (withModel && model.isNotEmpty) 'model': model,
    };
  }

  /// id 直接拼进路径: 只接受 UUID 形态。
  static String _checkedId(String id) {
    if (!RegExp(r'^[0-9A-Za-z-]{1,64}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'not a provider id');
    }
    return id;
  }
}
