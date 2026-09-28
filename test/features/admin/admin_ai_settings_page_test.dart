import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/admin/models/ai_provider_models.dart';
import 'package:uten_imp/features/admin/pages/admin_ai_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/ai_provider_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _zh = lookupAppLocalizations(const Locale('zh'));

const _secret = 'sk-live-0123456789abcdefghij';
const _deepseekId = '5b0b3d1e-0000-4000-8000-000000000001';
const _ollamaId = '5b0b3d1e-0000-4000-8000-000000000002';

const _deepseek = AiProviderPreset(
  code: 'DEEPSEEK',
  label: 'DeepSeek',
  region: AiRegion.mainland,
  protocol: AiProtocol.openAiChat,
  baseUrl: 'https://api.deepseek.com',
  models: ['deepseek-flash', 'deepseek-v4-pro'],
  jsonMode: AiJsonMode.jsonObject,
  thinkingControl: AiThinkingControl.deepseek,
  sendTemperature: true,
  supportsVision: true,
  requiresApiKey: true,
  regionEditable: false,
);

const _openai = AiProviderPreset(
  code: 'OPENAI',
  label: 'OpenAI',
  region: AiRegion.overseas,
  protocol: AiProtocol.openAiChat,
  baseUrl: 'https://api.openai.com/v1',
  models: ['gpt-5.6-luna'],
  jsonMode: AiJsonMode.jsonSchema,
  thinkingControl: AiThinkingControl.openAiReasoning,
  sendTemperature: true,
  supportsVision: true,
  requiresApiKey: true,
  regionEditable: false,
);

const _ollama = AiProviderPreset(
  code: 'OLLAMA',
  label: '本地部署(Ollama)',
  region: AiRegion.local,
  protocol: AiProtocol.openAiChat,
  baseUrl: 'http://127.0.0.1:11434/v1',
  models: [],
  jsonMode: AiJsonMode.jsonObject,
  thinkingControl: AiThinkingControl.none,
  sendTemperature: true,
  supportsVision: false,
  requiresApiKey: false,
  regionEditable: false,
);

AiPresetCatalog _catalog({bool allowOverseas = false, bool outbound = true}) =>
    AiPresetCatalog(
      presets: const [_deepseek, _openai, _ollama],
      allowOverseas: allowOverseas,
      allowLanHttp: false,
      outboundEnabled: outbound,
    );

AiProviderConfig _provider({
  String id = _deepseekId,
  String name = 'DeepSeek 正式',
  String preset = 'DEEPSEEK',
  AiRegion region = AiRegion.mainland,
  String baseUrl = 'https://api.deepseek.com',
  String model = 'deepseek-flash',
  bool keyConfigured = true,
  String? mask = '••••ghij',
  bool unreadable = false,
  bool isDefault = true,
  bool enabled = true,
  bool? lastTestOk = true,
  String? presetLabel,
}) => AiProviderConfig(
  id: id,
  name: name,
  preset: preset,
  presetLabel: presetLabel,
  region: region,
  protocol: AiProtocol.openAiChat,
  baseUrl: baseUrl,
  model: model,
  apiKeyConfigured: keyConfigured,
  apiKeyMasked: keyConfigured ? mask : null,
  apiKeyUnreadable: unreadable,
  jsonMode: AiJsonMode.jsonObject,
  thinkingControl: AiThinkingControl.deepseek,
  sendTemperature: true,
  supportsVision: true,
  maxOutputTokens: 8192,
  timeoutSeconds: 120,
  enabled: enabled,
  isDefault: isDefault,
  overseasAcknowledged: false,
  version: 7,
  lastTestAt: lastTestOk == null ? null : '2026-09-27T01:00:00Z',
  lastTestOk: lastTestOk,
  updatedAt: '2026-09-27T01:00:00Z',
  updatedByName: '管理员',
);

const _failedAuth = AiConnectionTestResult(
  ok: false,
  steps: [
    AiConnectionTestStep(
      key: AiConnectionTestStep.network,
      status: AiTestStepStatus.passed,
      latencyMs: 120,
    ),
    AiConnectionTestStep(
      key: AiConnectionTestStep.auth,
      status: AiTestStepStatus.failed,
      latencyMs: 80,
      message: '密钥无效或没有权限',
      advice: '请检查密钥是否复制完整, 或到服务商后台重新生成',
    ),
  ],
);

const _allPassed = AiConnectionTestResult(
  ok: true,
  steps: [
    AiConnectionTestStep(
      key: AiConnectionTestStep.network,
      status: AiTestStepStatus.passed,
      latencyMs: 90,
    ),
    AiConnectionTestStep(
      key: AiConnectionTestStep.auth,
      status: AiTestStepStatus.passed,
      latencyMs: 300,
    ),
    AiConnectionTestStep(
      key: AiConnectionTestStep.model,
      status: AiTestStepStatus.passed,
      latencyMs: 210,
    ),
    AiConnectionTestStep(
      key: AiConnectionTestStep.json,
      status: AiTestStepStatus.passed,
      latencyMs: 1400,
    ),
  ],
);

/// 服务端 PresetView 的原样形状(预设代码字段叫 key, 地址/模型叫 defaultBaseUrl/suggestedModels)。
Map<String, dynamic> _serverPreset(
  String key,
  String label,
  String region,
  String baseUrl, {
  List<String> models = const [],
  bool requiresApiKey = true,
  bool selectable = true,
  String? reason,
}) => {
  'key': key,
  'label': label,
  'region': region,
  'protocol': 'OPENAI_CHAT',
  'defaultBaseUrl': baseUrl,
  'suggestedModels': models,
  'jsonMode': 'JSON_OBJECT',
  'thinkingControl': 'NONE',
  'sendTemperature': true,
  'supportsVision': false,
  'requiresApiKey': requiresApiKey,
  'registeredDomains': const <String>[],
  'selectable': selectable,
  'unavailableReason': reason,
};

const _overseasReason = '服务器没有开启境外 AI 服务(客户资料会出境, 需要先完成数据出境评估, 再由运维开启)';
const _outboundReason = '这台服务器关闭了对外 AI 调用, 只能使用本机部署的服务';

AiPresetCatalog _serverCatalog({bool outbound = true}) =>
    AiPresetCatalog.fromJson({
      'presets': [
        _serverPreset(
          'DEEPSEEK',
          'DeepSeek',
          'MAINLAND',
          'https://api.deepseek.com',
          models: const ['deepseek-flash', 'deepseek-v4-pro'],
          selectable: outbound,
          reason: outbound ? null : _outboundReason,
        ),
        _serverPreset(
          'OPENAI',
          'OpenAI',
          'OVERSEAS',
          'https://api.openai.com/v1',
          models: const ['gpt-5.6-luna'],
          selectable: false,
          reason: _overseasReason,
        ),
        _serverPreset(
          'OLLAMA',
          '本地部署(Ollama)',
          'LOCAL',
          'http://127.0.0.1:11434/v1',
          requiresApiKey: false,
        ),
      ],
      'allowOverseas': false,
      'allowLanHttp': false,
      'outboundEnabled': outbound,
      'overseasNotice': '客户资料(公司名、货品描述)会发送到境外服务商, 我已确认完成数据出境评估',
    });

/// 服务端 AiConnectionTester 的原样结果: JSON 一步 WARN。
final _serverWarnResult = AiConnectionTestResult.fromJson({
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

const _serverAuthAdvice = '密钥无效或没有权限。请到服务商后台重新复制密钥; 通义、Kimi 的密钥还要和账号所在区域一致';

/// 服务端的失败结果: 没有单独的 advice, summary 就是第一条失败步骤的 message。
final _serverAuthFailed = AiConnectionTestResult.fromJson({
  'ok': false,
  'summary': _serverAuthAdvice,
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
      'message': _serverAuthAdvice,
      'latencyMs': 90,
    },
  ],
  'testedAt': '2026-09-27T12:00:00+08:00',
});

class _Repo implements AiProviderRepository {
  _Repo({List<AiProviderConfig>? providers, AiPresetCatalog? catalog})
    : providers = providers ?? [],
      catalog = catalog ?? _catalog();

  List<AiProviderConfig> providers;
  AiPresetCatalog catalog;
  Object? listError;
  AiConnectionTestResult storedResult = _failedAuth;
  AiConnectionTestResult formResult = _allPassed;
  Completer<void>? holdEnabled;
  AiModelList modelList = const AiModelList(
    models: ['deepseek-flash', 'deepseek-v4-pro'],
  );
  final List<String> calls = [];
  final List<AiProviderForm> forms = [];
  final List<int> versions = [];

  /// 「用已存密钥」探测时面板带上的当前表单(只用来让服务端核对地址)。
  final List<AiProviderForm?> storedChecks = [];

  @override
  Future<List<AiProviderConfig>> list() async {
    calls.add('list');
    if (listError != null) throw listError!;
    return List.of(providers);
  }

  @override
  Future<AiPresetCatalog> presets() async => catalog;

  @override
  Future<AiUsageSummary> usage({int days = 30}) async => AiUsageSummary(
    days: days,
    providers: const [
      AiProviderUsage(
        providerId: _deepseekId,
        providerName: 'DeepSeek 正式',
        calls: 128,
        okCalls: 125,
        inputTokens: 1204500,
        outputTokens: 88210,
        avgLatencyMs: 3420,
      ),
    ],
  );

  @override
  Future<void> create(AiProviderForm form) async {
    calls.add('create');
    forms.add(form);
  }

  @override
  Future<void> update(
    String id,
    AiProviderForm form, {
    required int version,
  }) async {
    calls.add('update $id');
    forms.add(form);
    versions.add(version);
  }

  @override
  Future<void> delete(String id) async => calls.add('delete $id');

  @override
  Future<void> setDefault(String id, {int? version}) async =>
      calls.add('default $id');

  @override
  Future<void> setEnabled(
    String id, {
    required bool enabled,
    int? version,
  }) async {
    calls.add('enabled $id $enabled');
    await holdEnabled?.future;
  }

  @override
  Future<AiConnectionTestResult> testForm(AiProviderForm form) async {
    calls.add('testForm');
    forms.add(form);
    return formResult;
  }

  @override
  Future<AiConnectionTestResult> testStored(
    String id, {
    AiProviderForm? current,
  }) async {
    calls.add('testStored $id');
    storedChecks.add(current);
    return storedResult;
  }

  @override
  Future<AiModelList> modelsForForm(AiProviderForm form) async {
    calls.add('modelsForForm');
    return modelList;
  }

  @override
  Future<AiModelList> modelsStored(String id, {AiProviderForm? current}) async {
    calls.add('modelsStored $id');
    storedChecks.add(current);
    return modelList;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repo repo, {
  bool compact = false,
  bool dark = false,
}) async {
  tester.view.physicalSize = compact
      ? const Size(420, 1500)
      : const Size(1400, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        aiProviderRepositoryProvider.overrideWithValue(repo),
      ],
      // 截图边界包住整个应用: 面板/弹窗在导航浮层里, 也要进截图。
      child: RepaintBoundary(
        key: const Key('ai-settings-capture'),
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: dark ? buildDarkTheme() : buildLightTheme(),
          home: const AdminAiSettingsPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
}

List<String> _messages(ProviderContainer container) => [
  for (final n in container.read(appNotificationProvider)) n.message,
];

Future<void> _openEditorFor(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('ai-provider-edit-$id')));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(TextFormField),
    ),
    text,
  );
  await tester.pumpAndSettle();
}

Future<void> _tapEditor(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test('route inherits the system-administration guard', () {
    expect(requiredAnyPermFor(RouteName.adminAiSettings), const [
      Perm.authorizationManage,
    ]);
    expect(requiredAllPermsFor(RouteName.adminAiSettings), isEmpty);
  });

  testWidgets('empty state explains what to do next', (tester) async {
    await _pump(tester, _Repo());
    expect(find.text(_zh.aiSettingsEmptyTitle), findsOneWidget);
    expect(find.text(_zh.aiSettingsHeroNone), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-settings-empty-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-settings-add')), findsOneWidget);
    expect(find.text(_zh.aiSettingsUsageEmpty), findsNothing);
    await _capture(tester, 'empty-light.png');
  });

  for (final (compact, dark) in [(false, false), (true, true)]) {
    testWidgets(
      '${compact ? 'compact dark' : 'desktop light'} cards show only the key mask',
      (tester) async {
        final repo = _Repo(
          providers: [
            _provider(),
            _provider(
              id: _ollamaId,
              name: '本机模型',
              preset: 'OLLAMA',
              region: AiRegion.local,
              baseUrl: 'http://127.0.0.1:11434/v1',
              model: 'qwen3:32b',
              keyConfigured: false,
              isDefault: false,
              lastTestOk: null,
            ),
          ],
        );
        await _pump(tester, repo, compact: compact, dark: dark);

        expect(
          find.text(_zh.aiSettingsHeroActive('DeepSeek 正式', 'deepseek-flash')),
          findsOneWidget,
        );
        expect(
          find.text(_zh.aiSettingsKeyConfigured('••••ghij')),
          findsOneWidget,
        );
        expect(find.text(_zh.aiSettingsKeyNotNeeded), findsOneWidget);
        expect(find.textContaining(_secret), findsNothing);
        expect(find.textContaining('abcdefghij'), findsNothing);
        expect(find.text(_zh.aiSettingsRegionMainland), findsWidgets);
        expect(find.text(_zh.aiSettingsRegionLocal), findsOneWidget);
        expect(
          find.byKey(const ValueKey('ai-provider-default-badge')),
          findsOneWidget,
        );
        // 默认服务没有「设为默认」, 另一项有。
        expect(
          find.byKey(const ValueKey('ai-provider-default-$_deepseekId')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('ai-provider-default-$_ollamaId')),
          findsOneWidget,
        );
        expect(find.text('128'), findsOneWidget);
        expect(find.text('97.7%'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          compact ? 'cards-compact-dark.png' : 'cards-desktop-light.png',
        );
      },
    );
  }

  testWidgets('an undecryptable key is flagged in red on the card', (
    tester,
  ) async {
    await _pump(tester, _Repo(providers: [_provider(unreadable: true)]));
    expect(
      find.byKey(const ValueKey('ai-provider-key-unreadable')),
      findsOneWidget,
    );
    expect(find.text(_zh.aiSettingsKeyUnreadable), findsWidgets);
  });

  testWidgets('a short key without a tail reads just as set', (tester) async {
    final repo = _Repo(providers: [_provider(mask: '已配置')]);
    await _pump(tester, repo);
    expect(find.text(_zh.aiSettingsKeyConfiguredPlain), findsOneWidget);
    expect(find.textContaining('已配置 已配置'), findsNothing);
    await _openEditorFor(tester, _deepseekId);
    expect(find.text(_zh.aiSettingsApiKeyKeepHintPlain), findsOneWidget);
  });

  testWidgets('testing a stored provider shows each step with advice', (
    tester,
  ) async {
    final repo = _Repo(providers: [_provider()]);
    await _pump(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('ai-provider-test-$_deepseekId')),
    );
    await tester.pumpAndSettle();

    expect(repo.calls, contains('testStored $_deepseekId'));
    expect(find.text(_zh.aiSettingsStepNetwork), findsOneWidget);
    expect(find.text(_zh.aiSettingsStepAuth), findsOneWidget);
    expect(find.text(_zh.aiSettingsStepModel), findsOneWidget);
    expect(find.text(_zh.aiSettingsStepJson), findsOneWidget);
    expect(find.text(_zh.aiSettingsLatency(120)), findsOneWidget);
    expect(find.text('请检查密钥是否复制完整, 或到服务商后台重新生成'), findsWidgets);
    // 步骤下写问题, 建议只在底部总结出现一次。
    expect(find.text('密钥无效或没有权限'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.cancel_rounded), findsOneWidget);
    expect(find.text(_zh.aiSettingsTestFailedShort), findsOneWidget);
    await _capture(tester, 'test-result-light.png');
  });

  testWidgets(
    'changing the endpoint of a stored key requires the key again before saving',
    (tester) async {
      final repo = _Repo(providers: [_provider()]);
      final container = await _pump(tester, repo);
      await _openEditorFor(tester, _deepseekId);

      // 编辑时只显示掩码提示, 输入框为空、遮挡、不接自动填充。
      final keyField = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('ai-editor-api-key')),
          matching: find.byType(EditableText),
        ),
      );
      expect(keyField.controller.text, isEmpty);
      expect(keyField.obscureText, isTrue);
      expect(keyField.autofillHints, isNull);
      expect(
        find.text(_zh.aiSettingsApiKeyKeepHint('••••ghij')),
        findsOneWidget,
      );
      expect(find.text(_zh.aiSettingsUrlChangedNeedKey), findsNothing);

      await _enter(tester, 'ai-editor-base-url', 'https://api.deepseek.cn');
      expect(
        find.byKey(const ValueKey('ai-editor-url-changed')),
        findsOneWidget,
      );
      await _capture(tester, 'editor-url-changed-light.png');

      await _tapEditor(tester, 'ai-editor-save');
      expect(repo.calls.where((c) => c.startsWith('update')), isEmpty);
      expect(_messages(container), contains(_zh.aiSettingsFixFields));

      // 测试也不能拿旧密钥去新地址。
      await _tapEditor(tester, 'ai-editor-test');
      expect(repo.calls.where((c) => c.startsWith('test')), isEmpty);
      expect(
        find.byKey(const ValueKey('ai-editor-probe-notice')),
        findsOneWidget,
      );

      await _enter(tester, 'ai-editor-api-key', _secret);
      expect(find.byKey(const ValueKey('ai-editor-url-changed')), findsNothing);
      await _tapEditor(tester, 'ai-editor-save');

      expect(repo.calls, contains('update $_deepseekId'));
      expect(repo.versions, [7]);
      final saved = repo.forms.last;
      expect(saved.apiKey, _secret);
      expect(saved.baseUrl, 'https://api.deepseek.cn');
      // 面板已关闭, 页面重新读取。
      expect(find.byKey(const ValueKey('ai-editor-save')), findsNothing);
      expect(_messages(container), contains(_zh.aiSettingsSaved));
    },
  );

  testWidgets('a leaked key can be removed without typing a new one', (
    tester,
  ) async {
    final repo = _Repo(providers: [_provider(unreadable: true)]);
    await _pump(tester, repo);
    await _openEditorFor(tester, _deepseekId);
    expect(
      find.byKey(const ValueKey('ai-editor-key-unreadable')),
      findsOneWidget,
    );

    await _tapEditor(tester, 'ai-editor-clear-key');
    expect(find.text(_zh.aiSettingsKeyWillClear), findsOneWidget);
    expect(find.text(_zh.aiSettingsUndoClear), findsOneWidget);
    await _tapEditor(tester, 'ai-editor-save');

    expect(repo.calls, contains('update $_deepseekId'));
    final body = repo.forms.last.toJson(version: 7);
    expect(body['clearApiKey'], isTrue);
    expect(body.containsKey('apiKey'), isFalse);
  });

  testWidgets('an unchanged stored config is tested with the stored key', (
    tester,
  ) async {
    final repo = _Repo(providers: [_provider()]);
    await _pump(tester, repo);
    await _openEditorFor(tester, _deepseekId);

    await _tapEditor(tester, 'ai-editor-test');
    expect(repo.calls, contains('testStored $_deepseekId'));
    // 带上当前地址让服务端再核对一遍, 但不带任何密钥。
    final check = repo.storedChecks.single!;
    expect(check.baseUrl, 'https://api.deepseek.com');
    expect(check.model, 'deepseek-flash');
    expect(check.hasNewApiKey, isFalse);

    // 改了模型又没填密钥: 不能用旧配置冒充新模型的结果。
    await _enter(tester, 'ai-editor-model', 'deepseek-v4-pro');
    repo.calls.clear();
    await _tapEditor(tester, 'ai-editor-test');
    expect(repo.calls, isEmpty);
    expect(find.text(_zh.aiSettingsTestStoredMismatch), findsOneWidget);
  });

  testWidgets('unsaved advanced settings are not passed off as tested', (
    tester,
  ) async {
    final repo = _Repo(providers: [_provider()]);
    await _pump(tester, repo);
    await _openEditorFor(tester, _deepseekId);

    final advanced = find.text(_zh.aiSettingsAdvanced);
    await tester.ensureVisible(advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    await _tapEditor(tester, 'ai-editor-temperature');

    // 已存密钥的测试只会按已保存的设置跑: 先说清楚, 不假装测过新设置。
    await _tapEditor(tester, 'ai-editor-test');
    expect(repo.calls.where((c) => c.startsWith('test')), isEmpty);
    expect(find.text(_zh.aiSettingsTestStoredUnsavedAdvanced), findsOneWidget);

    // 取模型不受这些设置影响, 照常可用。
    await _tapEditor(tester, 'ai-editor-fetch-models');
    expect(repo.calls, contains('modelsStored $_deepseekId'));

    // 重新填了密钥就按当前表单(含新设置)测试。
    await _enter(tester, 'ai-editor-api-key', _secret);
    await _tapEditor(tester, 'ai-editor-test');
    expect(repo.calls, contains('testForm'));
    expect(repo.forms.last.sendTemperature, isFalse);
  });

  testWidgets('an empty model list shows the reason the server gave', (
    tester,
  ) async {
    const reason = '这个服务商没有模型列表接口, 请手动填写模型名称';
    final repo = _Repo(providers: [_provider()])
      ..modelList = const AiModelList(models: [], message: reason);
    await _pump(tester, repo);
    await _openEditorFor(tester, _deepseekId);

    await _tapEditor(tester, 'ai-editor-fetch-models');
    expect(repo.calls, contains('modelsStored $_deepseekId'));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-editor-probe-notice')),
        matching: find.text(reason),
      ),
      findsOneWidget,
    );
    expect(find.text(_zh.aiSettingsModelsEmpty), findsNothing);
  });

  testWidgets('a WARN step is shown as a note, not as "not run"', (
    tester,
  ) async {
    final repo = _Repo(providers: [_provider()])
      ..storedResult = _serverWarnResult;
    await _pump(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('ai-provider-test-$_deepseekId')),
    );
    await tester.pumpAndSettle();

    expect(find.text('返回了 JSON 但内容和要求不一致, 识别客户文件可能不稳定'), findsOneWidget);
    expect(find.byIcon(Icons.error_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(3));
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
    // 总结用服务端的话, 徽标是「需留意」, 不再说「连接正常, 可以使用」。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-connection-test-summary')),
        matching: find.text('连接成功, 但有需要注意的地方'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-connection-test-badge')),
        matching: find.text(_zh.aiSettingsTestWarnShort),
      ),
      findsOneWidget,
    );
    expect(find.text(_zh.aiSettingsTestPassed), findsNothing);
    expect(find.text('模型「deepseek-flash」可以正常调用'), findsOneWidget);
  });

  testWidgets('a server failure shows its advice once, at the bottom', (
    tester,
  ) async {
    final repo = _Repo(providers: [_provider()])
      ..storedResult = _serverAuthFailed;
    await _pump(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('ai-provider-test-$_deepseekId')),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-connection-test-summary')),
        matching: find.text(_serverAuthAdvice),
      ),
      findsOneWidget,
    );
    // 步骤下不重复同一句话, 也不退回笼统的「没有通过」。
    expect(find.text(_serverAuthAdvice), findsOneWidget);
    expect(find.text(_zh.aiSettingsTestFailed), findsNothing);
    expect(find.byIcon(Icons.cancel_rounded), findsOneWidget);
    expect(find.text(_zh.aiSettingsTestFailedShort), findsOneWidget);
  });

  testWidgets('real server presets prefill DeepSeek and explain locked ones', (
    tester,
  ) async {
    final repo = _Repo(catalog: _serverCatalog());
    await _pump(tester, repo);
    await tester.tap(find.byKey(const ValueKey('ai-settings-add')));
    await tester.pumpAndSettle();

    final baseUrl = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('ai-editor-base-url')),
        matching: find.byType(EditableText),
      ),
    );
    expect(baseUrl.controller.text, 'https://api.deepseek.com');
    expect(find.widgetWithText(ChoiceChip, 'deepseek-flash'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-editor-preset-locked-0')),
        matching: find.text(_overseasReason),
      ),
      findsOneWidget,
    );

    await _tapEditor(tester, 'ai-editor-preset');
    expect(
      find.text(_zh.aiSettingsPresetOverseasOff('OpenAI')),
      findsOneWidget,
    );
    expect(find.text('本地部署(Ollama)'), findsOneWidget);
  });

  testWidgets('a server without outbound calls only offers local deployment', (
    tester,
  ) async {
    final repo = _Repo(catalog: _serverCatalog(outbound: false));
    await _pump(tester, repo);
    await tester.tap(find.byKey(const ValueKey('ai-settings-add')));
    await tester.pumpAndSettle();

    // 第一个能选的预设是本机部署。
    final baseUrl = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('ai-editor-base-url')),
        matching: find.byType(EditableText),
      ),
    );
    expect(baseUrl.controller.text, 'http://127.0.0.1:11434/v1');
    expect(find.text(_outboundReason), findsOneWidget);
    expect(find.text(_overseasReason), findsOneWidget);
    expect(find.text(_zh.aiSettingsApiKeyNotNeededHint), findsOneWidget);

    await _tapEditor(tester, 'ai-editor-preset');
    expect(
      find.text(_zh.aiSettingsPresetUnavailable('DeepSeek')),
      findsOneWidget,
    );
    expect(
      find.text(_zh.aiSettingsPresetOverseasOff('OpenAI')),
      findsOneWidget,
    );
  });

  testWidgets('a local provider without a key reads as ready', (tester) async {
    // 预设目录没加载到时也不能把本机部署误判成「缺密钥」, 也不露出预设代码。
    final repo = _Repo(
      providers: [
        _provider(
          id: _ollamaId,
          name: '本机模型',
          preset: 'OLLAMA',
          presetLabel: '本地部署(Ollama)',
          region: AiRegion.local,
          baseUrl: 'http://127.0.0.1:11434/v1',
          model: 'qwen3:32b',
          keyConfigured: false,
        ),
      ],
      catalog: AiPresetCatalog.empty,
    );
    await _pump(tester, repo);

    expect(find.text(_zh.aiSettingsHeroReady), findsOneWidget);
    expect(find.text(_zh.aiSettingsHeroNeedsKey), findsNothing);
    expect(find.text(_zh.aiSettingsKeyNotNeeded), findsOneWidget);
    expect(find.text(_zh.aiSettingsKeyMissing), findsNothing);
    expect(find.text('本地部署(Ollama)'), findsOneWidget);
    expect(find.text('OLLAMA'), findsNothing);
  });

  testWidgets('adding a provider: preset prefill, typed-key test, save', (
    tester,
  ) async {
    final repo = _Repo();
    final container = await _pump(tester, repo);
    await tester.tap(find.byKey(const ValueKey('ai-settings-add')));
    await tester.pumpAndSettle();

    // 第一个可选预设(DeepSeek)已预填。
    final baseUrl = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('ai-editor-base-url')),
        matching: find.byType(EditableText),
      ),
    );
    expect(baseUrl.controller.text, 'https://api.deepseek.com');
    // 境外预设未开放时给出原因(服务端没给原因时用本地说明)。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-editor-preset-locked-0')),
        matching: find.text(_zh.aiSettingsOverseasLockedShort),
      ),
      findsOneWidget,
    );

    // 预设推荐的模型直接点选。
    expect(find.byKey(const ValueKey('ai-editor-model-chips')), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'deepseek-v4-pro'));
    await tester.pumpAndSettle();
    final model = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('ai-editor-model')),
        matching: find.byType(EditableText),
      ),
    );
    expect(model.controller.text, 'deepseek-v4-pro');

    await _tapEditor(tester, 'ai-editor-test');
    expect(repo.calls.where((c) => c.startsWith('test')), isEmpty);
    expect(find.text(_zh.aiSettingsTestNeedsKey), findsOneWidget);

    await _enter(tester, 'ai-editor-api-key', _secret);
    await _tapEditor(tester, 'ai-editor-test');
    expect(repo.calls, contains('testForm'));
    expect(repo.forms.last.apiKey, _secret);
    expect(repo.forms.last.baseUrl, 'https://api.deepseek.com');
    expect(find.text(_zh.aiSettingsTestPassed), findsOneWidget);
    await _capture(tester, 'editor-create-light.png');

    await _tapEditor(tester, 'ai-editor-save');
    expect(repo.calls, contains('create'));
    final created = repo.forms.last;
    expect(created.name, 'DeepSeek');
    expect(created.preset, 'DEEPSEEK');
    expect(created.model, 'deepseek-v4-pro');
    expect(created.apiKey, _secret);
    expect(created.region, AiRegion.mainland);
    expect(find.byKey(const ValueKey('ai-editor-save')), findsNothing);
    expect(_messages(container), contains(_zh.aiSettingsSaved));
  });

  testWidgets(
    'overseas presets are locked when the server does not allow them',
    (tester) async {
      await _pump(tester, _Repo());
      await tester.tap(find.byKey(const ValueKey('ai-settings-add')));
      await tester.pumpAndSettle();
      await _tapEditor(tester, 'ai-editor-preset');
      expect(
        find.text(_zh.aiSettingsPresetOverseasOff('OpenAI')),
        findsOneWidget,
      );
      // 点被锁定的项不会切换。
      await tester.tap(find.text(_zh.aiSettingsPresetOverseasOff('OpenAI')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ai-editor-overseas-ack')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'allowed overseas providers need the data-export acknowledgment',
    (tester) async {
      final repo = _Repo(catalog: _catalog(allowOverseas: true));
      await _pump(tester, repo);
      await tester.tap(find.byKey(const ValueKey('ai-settings-add')));
      await tester.pumpAndSettle();
      await _tapEditor(tester, 'ai-editor-preset');
      await tester.tap(find.text('OpenAI').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('ai-editor-overseas-ack')),
        findsOneWidget,
      );
      await _enter(tester, 'ai-editor-api-key', _secret);
      await _tapEditor(tester, 'ai-editor-save');
      expect(repo.calls.where((c) => c == 'create'), isEmpty);
      expect(find.text(_zh.aiSettingsOverseasAckRequired), findsOneWidget);

      await _tapEditor(tester, 'ai-editor-overseas-ack');
      await _tapEditor(tester, 'ai-editor-save');
      expect(repo.calls, contains('create'));
      expect(repo.forms.last.region, AiRegion.overseas);
      expect(repo.forms.last.toJson()['overseasAcknowledged'], isTrue);
    },
  );

  testWidgets('a non-superadmin sees a plain no-access message', (
    tester,
  ) async {
    final repo = _Repo()
      ..listError = ApiException('FORBIDDEN', '无权限访问', httpStatus: 403);
    await _pump(tester, repo);
    expect(find.text(_zh.aiSettingsNoAccess), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-settings-add')), findsNothing);
  });

  testWidgets('outbound-disabled servers explain that nothing will be called', (
    tester,
  ) async {
    await _pump(
      tester,
      _Repo(providers: [_provider()], catalog: _catalog(outbound: false)),
    );
    expect(
      find.byKey(const ValueKey('ai-settings-outbound-off')),
      findsOneWidget,
    );
  });

  testWidgets('the default provider cannot be deleted while others exist', (
    tester,
  ) async {
    final repo = _Repo(
      providers: [
        _provider(),
        _provider(id: _ollamaId, name: '备用', isDefault: false),
      ],
    );
    final container = await _pump(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('ai-provider-delete-$_deepseekId')),
    );
    await tester.pumpAndSettle();
    expect(_messages(container), contains(_zh.aiSettingsDeleteDefaultBlocked));
    expect(repo.calls.where((c) => c.startsWith('delete')), isEmpty);

    await tester.tap(
      find.byKey(const ValueKey('ai-provider-delete-$_ollamaId')),
    );
    await tester.pumpAndSettle();
    expect(find.text(_zh.aiSettingsDeleteTitle), findsOneWidget);
    await tester.tap(find.text(_zh.aiSettingsDelete).last);
    await tester.pumpAndSettle();
    expect(repo.calls, contains('delete $_ollamaId'));
    expect(_messages(container), contains(_zh.aiSettingsDeleted));
  });

  testWidgets(
    'switching a provider off shows the busy overlay only while saving',
    (tester) async {
      final repo = _Repo(providers: [_provider()])..holdEnabled = Completer();
      await _pump(tester, repo);

      await tester.tap(
        find.byKey(const ValueKey('ai-provider-enabled-$_deepseekId')),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.bySemanticsLabel(RegExp(_zh.aiSettingsBusySaving)),
        findsOneWidget,
      );
      expect(repo.calls, contains('enabled $_deepseekId false'));

      repo.holdEnabled!.complete();
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp(_zh.aiSettingsBusySaving)),
        findsNothing,
      );
    },
  );
}

/// 只在显式要求时落盘(`UTEN_UI_FIXTURES=1 flutter test ...`): 默认跑测试不写文件。
Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['UTEN_UI_FIXTURES'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('ai-settings-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('.codex-tmp/ai-settings-ui')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
