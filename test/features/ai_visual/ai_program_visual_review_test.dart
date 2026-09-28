// AI 程序全部新界面的截图审查(设置页 / 编辑面板与连接测试 / 进度弹窗 / 识别核对面板 /
// 编辑页导入后 / 报价核价 / 报价状态 / 客户货品对照 / 货品英文名称)。
//
// 只在显式要求时运行并落盘:
//   flutter test --no-pub --dart-define=UTEN_CAPTURE_UI=true \
//     test/features/ai_visual/ai_program_visual_review_test.dart
// 图片写到 build/ui-audit/ai-*.png。数据全部是假数据; 识别结果夹具来自一次真实识别,
// 已去掉客户身份信息(test/fixtures/sales_intake_result_sample.json)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/models/ai_provider_models.dart';
import 'package:uten_imp/features/admin/pages/admin_ai_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/ai_provider_repository.dart';
import 'package:uten_imp/features/admin/widgets/ai_connection_test_view.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_launcher.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/ai/ai_progress_dialog.dart';

import 'ai_visual_business_screens.dart';
import 'ai_visual_support.dart';

// ---------------------------------------------------------------- AI 服务设置

const _deepseekId = '5b0b3d1e-0000-4000-8000-000000000001';
const _localId = '5b0b3d1e-0000-4000-8000-000000000002';

Map<String, dynamic> _preset(
  String key,
  String label,
  String region,
  String baseUrl, {
  List<String> models = const [],
  bool requiresApiKey = true,
  bool selectable = true,
  String? reason,
  bool vision = false,
}) => {
  'key': key,
  'label': label,
  'region': region,
  'protocol': 'OPENAI_CHAT',
  'defaultBaseUrl': baseUrl,
  'suggestedModels': models,
  'jsonMode': 'JSON_OBJECT',
  'thinkingControl': key == 'DEEPSEEK' ? 'DEEPSEEK' : 'NONE',
  'sendTemperature': true,
  'supportsVision': vision,
  'requiresApiKey': requiresApiKey,
  'registeredDomains': const <String>[],
  'selectable': selectable,
  'unavailableReason': reason,
};

final _catalog = AiPresetCatalog.fromJson({
  'presets': [
    _preset(
      'DEEPSEEK',
      'DeepSeek',
      'MAINLAND',
      'https://api.deepseek.com',
      models: const ['deepseek-chat', 'deepseek-reasoner'],
    ),
    _preset(
      'QWEN',
      '通义千问',
      'MAINLAND',
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
      models: const ['qwen-plus', 'qwen-vl-max'],
      vision: true,
    ),
    _preset(
      'OPENAI',
      'OpenAI',
      'OVERSEAS',
      'https://api.openai.com/v1',
      selectable: false,
      reason: '服务器没有开启境外 AI 服务(客户资料会出境, 需要先完成数据出境评估, 再由运维开启)',
    ),
    _preset(
      'OLLAMA',
      '本地部署(Ollama)',
      'LOCAL',
      'http://127.0.0.1:11434/v1',
      requiresApiKey: false,
    ),
  ],
  'allowOverseas': false,
  'allowLanHttp': false,
  'outboundEnabled': true,
});

AiProviderConfig _provider({
  required String id,
  required String name,
  required String preset,
  required AiRegion region,
  required String baseUrl,
  required String model,
  bool keyConfigured = true,
  bool isDefault = false,
  bool? lastTestOk = true,
}) => AiProviderConfig(
  id: id,
  name: name,
  preset: preset,
  region: region,
  protocol: AiProtocol.openAiChat,
  baseUrl: baseUrl,
  model: model,
  apiKeyConfigured: keyConfigured,
  apiKeyMasked: keyConfigured ? '••••k7Qp' : null,
  apiKeyUnreadable: false,
  jsonMode: AiJsonMode.jsonObject,
  thinkingControl: preset == 'DEEPSEEK'
      ? AiThinkingControl.deepseek
      : AiThinkingControl.none,
  sendTemperature: true,
  supportsVision: false,
  maxOutputTokens: 8192,
  timeoutSeconds: 120,
  enabled: true,
  isDefault: isDefault,
  overseasAcknowledged: false,
  version: 3,
  lastTestAt: lastTestOk == null ? null : '2026-09-27T06:12:00Z',
  lastTestOk: lastTestOk,
  updatedAt: '2026-09-27T06:12:00Z',
  updatedByName: '系统管理员',
);

final _twoProviders = [
  _provider(
    id: _deepseekId,
    name: 'DeepSeek 正式',
    preset: 'DEEPSEEK',
    region: AiRegion.mainland,
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-chat',
    isDefault: true,
  ),
  _provider(
    id: _localId,
    name: '本机测试',
    preset: 'OLLAMA',
    region: AiRegion.local,
    baseUrl: 'http://127.0.0.1:11434/v1',
    model: 'qwen3:32b',
    keyConfigured: false,
    lastTestOk: null,
  ),
];

final _testPassed = AiConnectionTestResult.fromJson({
  'ok': true,
  'summary': '连接成功, 可以用来识别客户文件',
  'steps': [
    {
      'key': 'NETWORK',
      'status': 'OK',
      'message': '服务器能连上 AI 服务',
      'latencyMs': 86,
    },
    {'key': 'AUTH', 'status': 'OK', 'message': '密钥有效', 'latencyMs': 240},
    {
      'key': 'MODEL',
      'status': 'OK',
      'message': '模型「deepseek-chat」可以正常调用',
      'latencyMs': 910,
    },
    {
      'key': 'JSON',
      'status': 'OK',
      'message': '能按要求返回表格识别结果',
      'latencyMs': 1480,
    },
  ],
  'testedAt': '2026-09-28T09:30:00+08:00',
});

const _authAdvice = '密钥无效或没有权限。请到服务商后台重新复制密钥; 通义、Kimi 的密钥还要和账号所在区域一致';

final _testFailed = AiConnectionTestResult.fromJson({
  'ok': false,
  'summary': _authAdvice,
  'steps': [
    {
      'key': 'NETWORK',
      'status': 'OK',
      'message': '服务器能连上 AI 服务',
      'latencyMs': 92,
    },
    {
      'key': 'AUTH',
      'status': 'FAILED',
      'message': _authAdvice,
      'latencyMs': 118,
    },
  ],
  'testedAt': '2026-09-28T09:30:00+08:00',
});

class _AiRepo implements AiProviderRepository {
  _AiRepo({List<AiProviderConfig>? providers})
    : providers = providers ?? const [];

  final List<AiProviderConfig> providers;
  AiConnectionTestResult result = _testPassed;

  /// 非空时连接测试挂起, 用来截「测试中」。
  Completer<void>? holdTest;

  /// 非空时读取列表挂起, 用来截首次加载的骨架屏。
  Completer<void>? holdList;

  /// 非空时写操作(设为默认等)挂起, 用来截保存遮罩。
  Completer<void>? holdWrite;

  @override
  Future<List<AiProviderConfig>> list() async {
    await holdList?.future;
    return List.of(providers);
  }

  @override
  Future<AiPresetCatalog> presets() async => _catalog;

  @override
  Future<AiUsageSummary> usage({int days = 30}) async => AiUsageSummary(
    days: days,
    providers: providers.isEmpty
        ? const []
        : const [
            AiProviderUsage(
              providerId: _deepseekId,
              providerName: 'DeepSeek 正式',
              calls: 128,
              okCalls: 125,
              inputTokens: 1204500,
              outputTokens: 88210,
              avgLatencyMs: 3420,
            ),
            AiProviderUsage(
              providerId: _localId,
              providerName: '本机测试',
              calls: 6,
              okCalls: 4,
              inputTokens: 40210,
              outputTokens: 3120,
              avgLatencyMs: 11800,
            ),
          ],
  );

  @override
  Future<void> create(AiProviderForm form) async {}

  @override
  Future<void> update(
    String id,
    AiProviderForm form, {
    required int version,
  }) async {}

  @override
  Future<void> delete(String id, {int? version}) async {}

  @override
  Future<void> setDefault(String id, {int? version}) async => holdWrite?.future;

  @override
  Future<void> setEnabled(
    String id, {
    required bool enabled,
    int? version,
  }) async {}

  Future<AiConnectionTestResult> _result() async {
    await holdTest?.future;
    return result;
  }

  @override
  Future<AiConnectionTestResult> testForm(AiProviderForm form) => _result();

  @override
  Future<AiConnectionTestResult> testStored(
    String id, {
    AiProviderForm? current,
  }) => _result();

  @override
  Future<AiModelList> modelsForForm(AiProviderForm form) async =>
      const AiModelList(models: ['deepseek-chat', 'deepseek-reasoner']);

  @override
  Future<AiModelList> modelsStored(
    String id, {
    AiProviderForm? current,
  }) async => const AiModelList(models: ['deepseek-chat', 'deepseek-reasoner']);
}

Future<void> _pumpSettings(
  WidgetTester tester,
  _AiRepo repo, {
  Size size = kDesktop,
  bool dark = false,
}) async {
  await setCaptureView(tester, size);
  await tester.pumpWidget(
    captureApp(
      dark: dark,
      overrides: [
        ...await baseOverrides(),
        aiProviderRepositoryProvider.overrideWithValue(repo),
      ],
      home: const AdminAiSettingsPage(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------- 进度弹窗

class _HeldJob {
  AiJobProgressCallback? progress;
  final completer = Completer<AiJobSnapshot>();

  Future<AiJobSnapshot> call(
    AiJobProgressCallback onProgress,
    AiJobCancelToken cancelToken,
  ) {
    progress = onProgress;
    return completer.future;
  }
}

Future<void> _pumpProgress(
  WidgetTester tester, {
  Size size = kDesktop,
  bool dark = false,
}) async {
  await setCaptureView(tester, size);
  final job = _HeldJob();
  await tester.pumpWidget(
    captureApp(
      dark: dark,
      overrides: await baseOverrides(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () {
                final l10n = AppLocalizations.of(context);
                unawaited(
                  showAiProgressDialog(
                    context,
                    title: l10n.salesIntakeProgressTitle,
                    subtitle: 'ALPHA(2026-1-19+2026-2-24)260422.xlsx',
                    stages: salesIntakeProgressStages(l10n),
                    task: job.call,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump();
  // 已上传(有作业 id) → 服务端在「识别表头与列」: 第 3 步(共 6 步)进行中。
  job.progress!(
    const AiJobSnapshot(
      id: 'job-1',
      kind: 'SALES_DOCUMENT_INTAKE',
      status: AiJobStatus.running,
      stage: 'LAYOUT',
      progress: 35,
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pump(const Duration(milliseconds: 400));
  _pendingJobs.add(job);
}

final _pendingJobs = <_HeldJob>[];

Future<void> _finishProgress(WidgetTester tester) async {
  for (final job in _pendingJobs) {
    if (!job.completer.isCompleted) {
      job.completer.complete(
        const AiJobSnapshot(
          id: 'job-1',
          kind: 'SALES_DOCUMENT_INTAKE',
          status: AiJobStatus.succeeded,
        ),
      );
    }
  }
  _pendingJobs.clear();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('AI 服务设置', () {
    testWidgets('empty state', (tester) async {
      await _pumpSettings(tester, _AiRepo());
      await capture(tester, 'settings-empty-1440-light');
    }, skip: !kCaptureUi);

    for (final (size, dark, name) in [
      (kDesktop, false, 'settings-list-1440-light'),
      (kDesktop, true, 'settings-list-1440-dark'),
      (kMobile, false, 'settings-list-390-light'),
    ]) {
      testWidgets(name, (tester) async {
        await _pumpSettings(
          tester,
          _AiRepo(providers: _twoProviders),
          size: size,
          dark: dark,
        );
        await capture(tester, name);
        if (size == kMobile) {
          // 手机上往下滚一屏看服务卡片与用量。
          await tester.drag(
            find.byKey(const ValueKey('ai-settings-list')),
            const Offset(0, -700),
          );
          await tester.pumpAndSettle();
          await capture(tester, '$name-scrolled');
        }
      }, skip: !kCaptureUi);
    }

    testWidgets('first load skeleton', (tester) async {
      final repo = _AiRepo(providers: _twoProviders)..holdList = Completer();
      await setCaptureView(tester, kDesktop);
      await tester.pumpWidget(
        captureApp(
          overrides: [
            ...await baseOverrides(),
            aiProviderRepositoryProvider.overrideWithValue(repo),
          ],
          home: const AdminAiSettingsPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await capture(tester, 'settings-loading-1440-light');
      repo.holdList!.complete();
      await tester.pumpAndSettle();
    }, skip: !kCaptureUi);

    testWidgets('saving overlay (set default)', (tester) async {
      final repo = _AiRepo(providers: _twoProviders)..holdWrite = Completer();
      await _pumpSettings(tester, repo);
      await tester.tap(
        find.byKey(const ValueKey('ai-provider-default-$_localId')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await capture(tester, 'settings-saving-1440-light');
      repo.holdWrite!.complete();
      await tester.pumpAndSettle();
    }, skip: !kCaptureUi);

    testWidgets('card inline test result (failure)', (tester) async {
      final repo = _AiRepo(providers: _twoProviders)..result = _testFailed;
      await _pumpSettings(tester, repo);
      await _tapKey(tester, 'ai-provider-test-$_deepseekId');
      await capture(tester, 'settings-card-test-failed-1440-light');
    }, skip: !kCaptureUi);
  });

  group('新增/编辑面板与连接测试', () {
    testWidgets('add panel (new provider)', (tester) async {
      await _pumpSettings(tester, _AiRepo(providers: _twoProviders));
      await tester.tap(find.byKey(const ValueKey('ai-settings-add')));
      await tester.pumpAndSettle();
      await capture(tester, 'editor-add-1440-light');
    }, skip: !kCaptureUi);

    for (final (variant, result) in [
      ('ok', _testPassed),
      ('failed', _testFailed),
    ]) {
      testWidgets('edit panel test $variant', (tester) async {
        final repo = _AiRepo(providers: _twoProviders)..result = result;
        await _pumpSettings(tester, repo);
        await _tapKey(tester, 'ai-provider-edit-$_deepseekId');
        await _tapKey(tester, 'ai-editor-test');
        // 结果在面板底部: 滚到能看见。
        final view = find.byType(AiConnectionTestView);
        if (view.evaluate().isNotEmpty) {
          await tester.ensureVisible(view.first);
          await tester.pumpAndSettle();
        }
        await capture(tester, 'editor-test-$variant-1440-light');
      }, skip: !kCaptureUi);
    }

    testWidgets('edit panel test running', (tester) async {
      final repo = _AiRepo(providers: _twoProviders)..holdTest = Completer();
      await _pumpSettings(tester, repo);
      await _tapKey(tester, 'ai-provider-edit-$_deepseekId');
      final finder = find.byKey(const ValueKey('ai-editor-test'));
      await tester.tap(finder);
      // 等「滚到测试结果」的动画走完(转圈是无限动画, 不能 pumpAndSettle)。
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await capture(tester, 'editor-test-running-1440-light');
      repo.holdTest!.complete();
      await tester.pumpAndSettle();
    }, skip: !kCaptureUi);

    testWidgets('edit panel key mask + advanced settings', (tester) async {
      await _pumpSettings(tester, _AiRepo(providers: _twoProviders));
      await _tapKey(tester, 'ai-provider-edit-$_deepseekId');
      await capture(tester, 'editor-edit-1440-light');
      final advanced = find.text('高级设置');
      await tester.ensureVisible(advanced);
      await tester.pumpAndSettle();
      await capture(tester, 'editor-advanced-closed-1440-light');
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('ai-editor-thinking')),
      );
      await tester.pumpAndSettle();
      await capture(tester, 'editor-advanced-open-1440-light');
    }, skip: !kCaptureUi);

    testWidgets('edit panel mobile', (tester) async {
      final repo = _AiRepo(providers: _twoProviders)..result = _testFailed;
      await _pumpSettings(tester, repo, size: kMobile);
      await _tapKey(tester, 'ai-provider-edit-$_deepseekId');
      await capture(tester, 'editor-edit-390-light');
      await _tapKey(tester, 'ai-editor-test');
      await capture(tester, 'editor-test-failed-390-light');
    }, skip: !kCaptureUi);
  });

  businessScreenTests();

  group('AI 进度弹窗', () {
    for (final (size, dark, name) in [
      (kDesktop, false, 'progress-1440-light'),
      (kDesktop, true, 'progress-1440-dark'),
      (kMobile, false, 'progress-390-light'),
    ]) {
      testWidgets(name, (tester) async {
        await _pumpProgress(tester, size: size, dark: dark);
        await capture(tester, name);
        await _finishProgress(tester);
      }, skip: !kCaptureUi);
    }
  });
}
