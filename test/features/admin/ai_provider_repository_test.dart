import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/admin/models/ai_provider_models.dart';
import 'package:uten_imp/features/admin/repositories/ai_provider_repository.dart';

const _id = '5b0b3d1e-0000-4000-8000-000000000001';

const _secret = 'sk-live-0123456789abcdefghij';

AiProviderForm _form({
  String? apiKey,
  bool clearApiKey = false,
  AiRegion region = AiRegion.mainland,
  bool overseasAcknowledged = false,
}) => AiProviderForm(
  name: '  DeepSeek 正式  ',
  preset: 'DEEPSEEK',
  region: region,
  protocol: AiProtocol.openAiChat,
  baseUrl: ' https://api.deepseek.com ',
  model: 'deepseek-flash',
  apiKey: apiKey,
  clearApiKey: clearApiKey,
  jsonMode: AiJsonMode.jsonObject,
  thinkingControl: AiThinkingControl.deepseek,
  sendTemperature: true,
  supportsVision: true,
  maxOutputTokens: 8192,
  timeoutSeconds: 120,
  enabled: true,
  overseasAcknowledged: overseasAcknowledged,
);

Map<String, dynamic> _providerJson({Map<String, dynamic> extra = const {}}) => {
  'id': _id,
  'name': 'DeepSeek 正式',
  'preset': 'DEEPSEEK',
  'region': 'MAINLAND',
  'protocol': 'OPENAI_CHAT',
  'baseUrl': 'https://api.deepseek.com',
  'model': 'deepseek-flash',
  'apiKeyConfigured': true,
  'apiKeyMasked': '••••ghij',
  'apiKeyUnreadable': false,
  'jsonMode': 'JSON_OBJECT',
  'thinkingControl': 'DEEPSEEK',
  'sendTemperature': true,
  'supportsVision': true,
  'maxOutputTokens': 8192,
  'timeoutSeconds': 120,
  'enabled': true,
  'isDefault': true,
  'overseasAcknowledged': false,
  'lastTestAt': '2026-09-27T01:00:00Z',
  'lastTestOk': true,
  'lastTestMessage': null,
  'version': 3,
  'updatedAt': '2026-09-27T01:00:00Z',
  'updatedByName': '管理员',
  ...extra,
};

/// 服务端 `GET /admin/ai/presets` 的原样响应(AiProviderService.presets, 境外未开放时)。
const Map<String, dynamic> _serverPresetsJson = {
  'presets': [
    {
      'key': 'DEEPSEEK',
      'label': 'DeepSeek',
      'region': 'MAINLAND',
      'protocol': 'OPENAI_CHAT',
      'defaultBaseUrl': 'https://api.deepseek.com',
      'suggestedModels': ['deepseek-flash', 'deepseek-v4-pro'],
      'jsonMode': 'JSON_OBJECT',
      'thinkingControl': 'DEEPSEEK',
      'sendTemperature': true,
      'supportsVision': true,
      'requiresApiKey': true,
      'registeredDomains': ['deepseek.com'],
      'selectable': true,
      'unavailableReason': null,
    },
    {
      'key': 'OPENAI',
      'label': 'OpenAI',
      'region': 'OVERSEAS',
      'protocol': 'OPENAI_CHAT',
      'defaultBaseUrl': 'https://api.openai.com/v1',
      'suggestedModels': ['gpt-5.6-luna'],
      'jsonMode': 'JSON_SCHEMA',
      'thinkingControl': 'OPENAI_REASONING',
      'sendTemperature': true,
      'supportsVision': true,
      'requiresApiKey': true,
      'registeredDomains': ['openai.com'],
      'selectable': false,
      'unavailableReason': '服务器没有开启境外 AI 服务(客户资料会出境, 需要先完成数据出境评估, 再由运维开启)',
    },
    {
      'key': 'OLLAMA',
      'label': '本地部署(Ollama)',
      'region': 'LOCAL',
      'protocol': 'OPENAI_CHAT',
      'defaultBaseUrl': 'http://127.0.0.1:11434/v1',
      'suggestedModels': <String>[],
      'jsonMode': 'JSON_OBJECT',
      'thinkingControl': 'NONE',
      'sendTemperature': true,
      'supportsVision': false,
      'requiresApiKey': false,
      'registeredDomains': <String>[],
      'selectable': true,
      'unavailableReason': null,
    },
    {
      'key': 'CUSTOM',
      'label': '自定义(OpenAI 兼容)',
      'region': null,
      'protocol': 'OPENAI_CHAT',
      'defaultBaseUrl': '',
      'suggestedModels': <String>[],
      'jsonMode': 'JSON_OBJECT',
      'thinkingControl': 'NONE',
      'sendTemperature': true,
      'supportsVision': false,
      'requiresApiKey': true,
      'registeredDomains': <String>[],
      'selectable': true,
      'unavailableReason': null,
    },
  ],
  'allowOverseas': false,
  'allowLanHttp': false,
  'outboundEnabled': true,
  'overseasNotice': '客户资料(公司名、货品描述)会发送到境外服务商, 我已确认完成数据出境评估',
};

void main() {
  test(
    'list parses the write-only DTO (mask, unreadable flag, version)',
    () async {
      final api = _Api()
        ..listResponse = [
          _providerJson(),
          _providerJson(
            extra: {
              'id': 'p-2',
              'apiKeyUnreadable': true,
              'region': 'OVERSEAS',
              'lastTestOk': false,
            },
          ),
        ];
      final providers = await DioAiProviderRepository(api).list();

      expect(api.calls, ['GET ${ApiEndpoints.adminAiProviders}']);
      expect(providers, hasLength(2));
      final first = providers.first;
      expect(first.apiKeyConfigured, isTrue);
      expect(first.apiKeyMasked, '••••ghij');
      expect(first.thinkingControl, AiThinkingControl.deepseek);
      expect(first.version, 3);
      expect(first.isDefault, isTrue);
      expect(first.lastTestOk, isTrue);
      expect(providers.last.apiKeyUnreadable, isTrue);
      expect(providers.last.region, AiRegion.overseas);
      expect(providers.last.lastTestOk, isFalse);
    },
  );

  // 与服务端 AiProviderDtos.PresetsView / PresetView 逐字段一致(ai-platform, ADR-133):
  // 预设代码字段叫 key, 地址/模型叫 defaultBaseUrl/suggestedModels, 另有 selectable/unavailableReason。
  test('presets parse the exact server PresetsView JSON', () async {
    final api = _Api()..getResponse = _serverPresetsJson;
    final catalog = await DioAiProviderRepository(api).presets();

    expect(api.calls, ['GET ${ApiEndpoints.adminAiPresets}']);
    expect(catalog.presets.map((p) => p.code), [
      'DEEPSEEK',
      'OPENAI',
      'OLLAMA',
      'CUSTOM',
    ]);
    expect(catalog.allowOverseas, isFalse);
    expect(catalog.outboundEnabled, isTrue);

    final deepseek = catalog.byCode('DEEPSEEK')!;
    expect(deepseek.label, 'DeepSeek');
    expect(deepseek.baseUrl, 'https://api.deepseek.com');
    expect(deepseek.models, ['deepseek-flash', 'deepseek-v4-pro']);
    expect(deepseek.thinkingControl, AiThinkingControl.deepseek);
    expect(deepseek.requiresApiKey, isTrue);
    expect(deepseek.regionEditable, isFalse);
    expect(catalog.isSelectable(deepseek), isTrue);

    final openai = catalog.byCode('OPENAI')!;
    expect(openai.region, AiRegion.overseas);
    expect(openai.jsonMode, AiJsonMode.jsonSchema);
    expect(catalog.isSelectable(openai), isFalse);
    expect(catalog.isOverseasLocked(openai), isTrue);
    expect(openai.unavailableReason, startsWith('服务器没有开启境外 AI 服务'));

    final ollama = catalog.byCode('OLLAMA')!;
    expect(ollama.region, AiRegion.local);
    expect(ollama.requiresApiKey, isFalse);
    expect(ollama.models, isEmpty);

    // 自定义: 服务端区域为 null, 由管理员自己选。
    final custom = catalog.byCode('CUSTOM')!;
    expect(custom.regionEditable, isTrue);
    expect(custom.region, AiRegion.mainland);
    expect(catalog.isSelectable(custom), isTrue);
  });

  test('an outbound-off server locks mainland presets with its own reason', () {
    final catalog = AiPresetCatalog.fromJson({
      ..._serverPresetsJson,
      'outboundEnabled': false,
      'presets': [
        {
          ...(_serverPresetsJson['presets'] as List).first
              as Map<String, dynamic>,
          'selectable': false,
          'unavailableReason': '这台服务器关闭了对外 AI 调用, 只能使用本机部署的服务',
        },
      ],
    });
    final deepseek = catalog.byCode('DEEPSEEK')!;
    expect(catalog.isSelectable(deepseek), isFalse);
    expect(catalog.isOverseasLocked(deepseek), isFalse);
    expect(deepseek.unavailableReason, contains('只能使用本机部署'));
  });

  test('a provider without a loaded preset still falls back sensibly', () {
    final ollama = AiProviderConfig.fromJson(
      _providerJson(
        extra: {
          'preset': 'OLLAMA',
          'presetLabel': '本地部署(Ollama)',
          'region': 'LOCAL',
          'apiKeyConfigured': false,
          'apiKeyMasked': null,
        },
      ),
    );
    expect(ollama.presetLabel, '本地部署(Ollama)');
    // 预设目录没加载到, 本机部署也不需要密钥。
    expect(ollama.keyRequiredWith(null), isFalse);
    expect(ollama.usableWith(null), isTrue);
    // 自定义 + 本机部署: 服务端按区域免密钥(预设本身 requiresApiKey=true)。
    final catalog = AiPresetCatalog.fromJson(_serverPresetsJson);
    final customLocal = AiProviderConfig.fromJson(
      _providerJson(
        extra: {
          'preset': 'CUSTOM',
          'region': 'LOCAL',
          'apiKeyConfigured': false,
        },
      ),
    );
    expect(customLocal.usableWith(catalog.byCode('CUSTOM')), isTrue);
    final customMainland = AiProviderConfig.fromJson(
      _providerJson(extra: {'preset': 'CUSTOM', 'apiKeyConfigured': false}),
    );
    expect(customMainland.usableWith(catalog.byCode('CUSTOM')), isFalse);
  });

  // 与服务端 AiConnectionTester / AiProviderDtos.TestResult 逐字段一致:
  // {ok, summary, steps: [{key, status: OK|FAILED|SKIPPED|WARN, message, latencyMs}], testedAt}。
  test('connection test results parse the exact server TestResult JSON', () {
    final warned = AiConnectionTestResult.fromJson({
      'ok': true,
      'summary': '连接成功, 但有需要注意的地方',
      'steps': [
        {
          'key': 'NETWORK',
          'status': 'OK',
          'message': '服务器能连上 AI 服务',
          'latencyMs': 120,
        },
        {'key': 'AUTH', 'status': 'OK', 'message': '密钥有效', 'latencyMs': 120},
        {
          'key': 'MODEL',
          'status': 'OK',
          'message': '模型「deepseek-flash」可以正常调用',
          'latencyMs': 300,
        },
        {
          'key': 'JSON',
          'status': 'WARN',
          'message': '返回了 JSON 但内容和要求不一致, 识别客户文件可能不稳定',
          'latencyMs': 300,
        },
      ],
      'testedAt': '2026-09-27T12:00:00+08:00',
    });
    expect(warned.ok, isTrue);
    expect(warned.message, '连接成功, 但有需要注意的地方');
    expect(warned.testedAt, '2026-09-27T12:00:00+08:00');
    expect(warned.orderedSteps.map((s) => s.status), [
      AiTestStepStatus.passed,
      AiTestStepStatus.passed,
      AiTestStepStatus.passed,
      AiTestStepStatus.warning,
    ]);
    expect(warned.orderedSteps.last.message, contains('识别客户文件可能不稳定'));
    expect(warned.outcome, AiTestOutcome.warning);

    const authAdvice = '密钥无效或没有权限。请到服务商后台重新复制密钥; 通义、Kimi 的密钥还要和账号所在区域一致';
    final failed = AiConnectionTestResult.fromJson({
      'ok': false,
      'summary': authAdvice,
      'steps': [
        {
          'key': 'NETWORK',
          'status': 'OK',
          'message': '服务器能连上 AI 服务',
          'latencyMs': 90,
        },
        {
          'key': 'AUTH',
          'status': 'FAILED',
          'message': authAdvice,
          'latencyMs': 90,
        },
      ],
      'testedAt': '2026-09-27T12:00:00+08:00',
    });
    expect(failed.outcome, AiTestOutcome.failed);
    expect(failed.message, authAdvice);
    expect(failed.firstFailure?.key, 'AUTH');
    expect(failed.firstFailure?.message, authAdvice);

    // 还没填模型: 服务端 ok=false, 但没有失败步骤 —— 是「要留意」不是「没通过」。
    final skipped = AiConnectionTestResult.fromJson({
      'ok': false,
      'summary': '连接成功, 还没有测试模型',
      'steps': [
        {'key': 'NETWORK', 'status': 'OK', 'message': 'ok', 'latencyMs': 90},
        {'key': 'AUTH', 'status': 'OK', 'message': '密钥有效', 'latencyMs': 90},
        {'key': 'MODEL', 'status': 'SKIPPED', 'message': '还没有填写模型名称'},
      ],
    });
    expect(skipped.outcome, AiTestOutcome.warning);
    expect(skipped.orderedSteps[2].message, '还没有填写模型名称');
  });

  test('an empty model list carries the server reason', () async {
    final api = _Api()
      ..postResponse = {
        'models': <String>[],
        'message': '这个服务商没有模型列表接口, 请手动填写模型名称',
      };
    final list = await DioAiProviderRepository(
      api,
    ).modelsForForm(_form(apiKey: _secret));
    expect(list.models, isEmpty);
    expect(list.message, '这个服务商没有模型列表接口, 请手动填写模型名称');
  });

  test('presets carry the server region switches', () async {
    final api = _Api()
      ..getResponse = {
        'allowOverseas': false,
        'allowLanHttp': true,
        'outboundEnabled': false,
        'presets': [
          {
            'preset': 'DEEPSEEK',
            'label': 'DeepSeek',
            'region': 'MAINLAND',
            'protocol': 'OPENAI_CHAT',
            'baseUrl': 'https://api.deepseek.com',
            'models': ['deepseek-flash', 'deepseek-v4-pro'],
            'jsonMode': 'JSON_OBJECT',
            'thinkingControl': 'DEEPSEEK',
            'sendTemperature': true,
            'supportsVision': true,
            'requiresApiKey': true,
          },
          {
            'preset': 'OLLAMA',
            'label': '本地部署(Ollama)',
            'region': 'LOCAL',
            'baseUrl': 'http://127.0.0.1:11434/v1',
            'requiresApiKey': false,
          },
          {'preset': 'CUSTOM', 'label': '自定义(OpenAI 兼容)', 'baseUrl': ''},
        ],
      };
    final catalog = await DioAiProviderRepository(api).presets();

    expect(api.calls, ['GET ${ApiEndpoints.adminAiPresets}']);
    expect(catalog.allowOverseas, isFalse);
    expect(catalog.allowLanHttp, isTrue);
    expect(catalog.outboundEnabled, isFalse);
    expect(catalog.presets.map((p) => p.code), [
      'DEEPSEEK',
      'OLLAMA',
      'CUSTOM',
    ]);
    expect(catalog.byCode('DEEPSEEK')!.models, [
      'deepseek-flash',
      'deepseek-v4-pro',
    ]);
    expect(catalog.byCode('OLLAMA')!.requiresApiKey, isFalse);
    expect(catalog.byCode('OLLAMA')!.region, AiRegion.local);
    expect(catalog.byCode('CUSTOM')!.regionEditable, isTrue);
    expect(catalog.byCode('DEEPSEEK')!.regionEditable, isFalse);
  });

  test('usage reads the last 30 days per provider', () async {
    final api = _Api()
      ..getResponse = {
        'days': 30,
        'providers': [
          {
            'providerId': _id,
            'providerName': 'DeepSeek 正式',
            'calls': 120,
            'okCalls': 114,
            'inputTokens': 1200000,
            'outputTokens': 90000,
            'avgLatencyMs': 3400,
          },
        ],
      };
    final usage = await DioAiProviderRepository(api).usage();
    expect(api.calls, ['GET ${ApiEndpoints.adminAiUsage}']);
    expect(api.lastQuery, {'days': 30});
    final row = usage.providers.single;
    expect(row.successRate, closeTo(0.95, 1e-9));
    expect(row.avgLatencyMs, 3400);
  });

  test('create sends the typed key once; blank keys are never sent', () async {
    final api = _Api();
    final repository = DioAiProviderRepository(api);

    await repository.create(_form(apiKey: '  $_secret  '));
    await repository.create(_form(apiKey: '   '));

    expect(api.calls, [
      'POST ${ApiEndpoints.adminAiProviders}',
      'POST ${ApiEndpoints.adminAiProviders}',
    ]);
    final withKey = api.bodies[0]! as Map<String, dynamic>;
    expect(withKey['apiKey'], _secret);
    expect(withKey['name'], 'DeepSeek 正式');
    expect(withKey['baseUrl'], 'https://api.deepseek.com');
    expect(withKey['region'], 'MAINLAND');
    expect(withKey['thinkingControl'], 'DEEPSEEK');
    expect(withKey.containsKey('version'), isFalse);
    expect(withKey['overseasAcknowledged'], isFalse);
    final blank = api.bodies[1]! as Map<String, dynamic>;
    expect(blank.containsKey('apiKey'), isFalse);
    expect(blank.containsKey('clearApiKey'), isFalse);
  });

  test(
    'update carries the version, keeps the key unless replaced or cleared',
    () async {
      final api = _Api();
      final repository = DioAiProviderRepository(api);

      await repository.update(_id, _form(), version: 3);
      await repository.update(_id, _form(clearApiKey: true), version: 4);
      await repository.update(
        _id,
        _form(apiKey: _secret, clearApiKey: true),
        version: 5,
      );

      expect(
        api.calls,
        List.filled(3, 'PUT ${ApiEndpoints.adminAiProvider(_id)}'),
      );
      final keep = api.bodies[0]! as Map<String, dynamic>;
      expect(keep['version'], 3);
      expect(keep.containsKey('apiKey'), isFalse);
      expect(keep.containsKey('clearApiKey'), isFalse);
      final clear = api.bodies[1]! as Map<String, dynamic>;
      expect(clear['clearApiKey'], isTrue);
      // 新填了密钥就是「换密钥」, 不再同时声明清除。
      final replace = api.bodies[2]! as Map<String, dynamic>;
      expect(replace['apiKey'], _secret);
      expect(replace.containsKey('clearApiKey'), isFalse);
    },
  );

  test('overseas acknowledgment is only sent for overseas providers', () {
    expect(
      _form(overseasAcknowledged: true).toJson()['overseasAcknowledged'],
      isFalse,
    );
    expect(
      _form(
        region: AiRegion.overseas,
        overseasAcknowledged: true,
      ).toJson()['overseasAcknowledged'],
      isTrue,
    );
  });

  test(
    'typed-key probes use the exempt endpoints with the form body',
    () async {
      final api = _Api()
        ..postResponse = {
          'ok': false,
          'steps': [
            {'key': 'NETWORK', 'status': 'OK', 'latencyMs': 120},
            {
              'key': 'AUTH',
              'status': 'FAILED',
              'latencyMs': 80,
              'message': '密钥无效或没有权限',
              'advice': '请检查密钥是否复制完整',
            },
          ],
        };
      final repository = DioAiProviderRepository(api);

      final result = await repository.testForm(_form(apiKey: _secret));

      expect(api.calls, ['POST ${ApiEndpoints.adminAiProvidersTest}']);
      expect((api.bodies.single! as Map)['apiKey'], _secret);
      // 服务端 ProbeRequest 的组件, 不多不少(保存用字段不进探测请求)。
      expect((api.bodies.single! as Map).keys.toSet(), {
        'preset',
        'region',
        'protocol',
        'baseUrl',
        'model',
        'apiKey',
        'jsonMode',
        'thinkingControl',
        'sendTemperature',
        'timeoutSeconds',
        'overseasAcknowledged',
      });
      expect(api.lastTimeout, DioAiProviderRepository.probeTimeout);
      expect(result.ok, isFalse);
      expect(result.orderedSteps.map((s) => s.key), [
        'NETWORK',
        'AUTH',
        'MODEL',
        'JSON',
      ]);
      expect(result.orderedSteps[2].status, AiTestStepStatus.skipped);
      expect(result.firstFailure?.advice, '请检查密钥是否复制完整');
    },
  );

  test(
    'stored-key probes hit the per-provider endpoints without any key',
    () async {
      final api = _Api()
        ..postResponse = {
          'models': [
            'deepseek-flash',
            {'id': 'deepseek-v4-pro'},
            'deepseek-flash',
            '',
          ],
        };
      final repository = DioAiProviderRepository(api);

      await repository.testStored(_id);
      final models = await repository.modelsStored(_id);
      final formModels = await repository.modelsForForm(_form(apiKey: _secret));
      // 从编辑面板发起: 带上当前的协议/地址(/模型)让服务端核对, 绝不带密钥。
      await repository.testStored(_id, current: _form(apiKey: _secret));
      await repository.modelsStored(_id, current: _form(apiKey: _secret));

      expect(api.calls, [
        'POST ${ApiEndpoints.adminAiProviderTest(_id)}',
        'POST ${ApiEndpoints.adminAiProviderModels(_id)}',
        'POST ${ApiEndpoints.adminAiProvidersModels}',
        'POST ${ApiEndpoints.adminAiProviderTest(_id)}',
        'POST ${ApiEndpoints.adminAiProviderModels(_id)}',
      ]);
      expect(api.bodies[0], isNull);
      expect(api.bodies[1], isNull);
      expect(models.models, ['deepseek-flash', 'deepseek-v4-pro']);
      expect(models.message, isNull);
      expect(formModels.models, models.models);
      expect(api.bodies[3], {
        'protocol': 'OPENAI_CHAT',
        'baseUrl': 'https://api.deepseek.com',
        'model': 'deepseek-flash',
      });
      // 取模型不核对模型名(换模型前正需要先看列表)。
      expect(api.bodies[4], {
        'protocol': 'OPENAI_CHAT',
        'baseUrl': 'https://api.deepseek.com',
      });
    },
  );

  test('default, enable and delete hit their own endpoints', () async {
    final api = _Api();
    final repository = DioAiProviderRepository(api);

    await repository.setDefault(_id);
    await repository.setEnabled(_id, enabled: false);
    await repository.delete(_id);
    await repository.setDefault(_id, version: 7);
    await repository.setEnabled(_id, enabled: true, version: 7);

    expect(api.calls, [
      'POST ${ApiEndpoints.adminAiProviderDefault(_id)}',
      'POST ${ApiEndpoints.adminAiProviderEnabled(_id)}',
      'DELETE ${ApiEndpoints.adminAiProvider(_id)}',
      'POST ${ApiEndpoints.adminAiProviderDefault(_id)}',
      'POST ${ApiEndpoints.adminAiProviderEnabled(_id)}',
    ]);
    // 服务端 VersionRequest{version} / EnabledRequest{enabled, version}: 版本号选填。
    expect(api.bodies[0], isNull);
    expect(api.bodies[1], {'enabled': false});
    expect(api.bodies[3], {'version': 7});
    expect(api.bodies[4], {'enabled': true, 'version': 7});
  });

  test('provider ids with path characters are rejected', () async {
    final api = _Api();
    final repository = DioAiProviderRepository(api);
    await expectLater(repository.delete('../x'), throwsArgumentError);
    await expectLater(repository.testStored('a/b'), throwsArgumentError);
    expect(api.calls, isEmpty);
  });

  test(
    'base URL normalisation ignores case, default port and trailing slash',
    () {
      expect(
        normalizeAiBaseUrl('HTTPS://API.DeepSeek.com/'),
        normalizeAiBaseUrl('https://api.deepseek.com:443'),
      );
      expect(
        normalizeAiBaseUrl('https://api.deepseek.com/v1'),
        isNot(normalizeAiBaseUrl('https://api.deepseek.com')),
      );
      expect(
        normalizeAiBaseUrl('https://api.deepseek.com'),
        isNot(normalizeAiBaseUrl('https://api.deepseek.com.evil.example')),
      );
    },
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  final List<String> calls = [];
  final List<Object?> bodies = [];
  List<Map<String, dynamic>> listResponse = const [];
  Map<String, dynamic> getResponse = const {};
  Map<String, dynamic> postResponse = const {};
  Map<String, dynamic>? lastQuery;
  Duration? lastTimeout;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls.add('GET $path');
    return listResponse;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls.add('GET $path');
    lastQuery = query;
    return getResponse;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    calls.add('POST $path');
    bodies.add(body);
    return postResponse;
  }

  @override
  Future<Map<String, dynamic>> postLongRunning(
    String path, {
    Object? body,
    required Duration receiveTimeout,
  }) async {
    calls.add('POST $path');
    bodies.add(body);
    lastTimeout = receiveTimeout;
    return postResponse;
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    calls.add('PUT $path');
    bodies.add(body);
    return const {};
  }

  @override
  Future<void> delete(String path) async {
    calls.add('DELETE $path');
    bodies.add(null);
  }
}
